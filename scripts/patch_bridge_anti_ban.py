#!/usr/bin/env python3
"""
Patch bridge.js to add anti-ban mitigations:
1. Simulates human typing ('composing' presence update + variable delay) before sending texts.
2. Simulates human recording ('recording' presence update + variable delay) before sending voice notes (ptt).
3. Simulates uploading/composing time before sending other media (image, video, document).
4. Cleans up old socket connections and event listeners on disconnect to prevent memory leaks and duplicate sockets.
5. Implements exponential backoff with random jitter for reconnections to prevent server hammering.

This is applied at deploy time in deploy-instance.sh.
"""
import argparse
import os
import subprocess
import sys

def patch(bridge_path):
    with open(bridge_path, 'r', encoding='utf-8') as f:
        src = f.read()

    # 1. Check if already patched
    if 'reconnectAttempts' in src:
        print(f'[patch_bridge_anti_ban] Already patched: {bridge_path}')
        return False

    # 2. Add reconnectAttempts variable definition
    anchor_state = "let connectionState = 'disconnected';"
    if anchor_state not in src:
        print('[patch_bridge_anti_ban] ERROR: connectionState anchor not found')
        sys.exit(1)
    src = src.replace(anchor_state, f"{anchor_state}\nlet reconnectAttempts = 0;", 1)

    # 3. Replace sendWithTimeout function
    anchor_send = "function sendWithTimeout(chatId, payload, timeoutMs = SEND_TIMEOUT_MS) {"
    if anchor_send not in src:
        print('[patch_bridge_anti_ban] ERROR: sendWithTimeout function anchor not found')
        sys.exit(1)

    end_pattern = "  return Promise.race([sock.sendMessage(chatId, payload), timeoutPromise])\n    .finally(() => clearTimeout(timer));\n}"
    end_idx = src.find(end_pattern, src.find(anchor_send))
    if end_idx == -1:
        end_pattern_crlf = "  return Promise.race([sock.sendMessage(chatId, payload), timeoutPromise])\r\n    .finally(() => clearTimeout(timer));\r\n}"
        end_idx = src.find(end_pattern_crlf, src.find(anchor_send))
        if end_idx == -1:
            print('[patch_bridge_anti_ban] ERROR: sendWithTimeout end pattern not found')
            sys.exit(1)
        end_pattern = end_pattern_crlf

    old_send_func = src[src.find(anchor_send):end_idx + len(end_pattern)]
    
    new_send_func = """function getTypingDelay(text) {
  return Math.max(1500, Math.min(8000, (text || '').length * 50));
}

function getRecordingDelay(buffer) {
  if (!buffer || !buffer.length) return 3000;
  const estimatedSeconds = buffer.length / 3000;
  return Math.max(2000, Math.min(8000, Math.round(estimatedSeconds * 1000)));
}

async function sendWithTimeout(chatId, payload, timeoutMs = SEND_TIMEOUT_MS) {
  let timer;
  const timeoutPromise = new Promise((_, reject) => {
    timer = setTimeout(
      () => reject(new Error(`sendMessage timed out after ${timeoutMs / 1000}s`)),
      timeoutMs,
    );
  });

  try {
    if (payload && sock && connectionState === 'connected') {
      if (payload.text && !payload.edit) {
        await sock.sendPresenceUpdate('composing', chatId);
        const delay = getTypingDelay(payload.text);
        await sleep(delay);
      } else if (payload.audio) {
        if (payload.ptt) {
          await sock.sendPresenceUpdate('recording', chatId);
          const delay = getRecordingDelay(payload.audio);
          await sleep(delay);
        } else {
          await sock.sendPresenceUpdate('composing', chatId);
          await sleep(2000);
        }
      } else if (payload.image || payload.video || payload.document) {
        await sock.sendPresenceUpdate('composing', chatId);
        const delay = Math.floor(Math.random() * 1500) + 1500;
        await sleep(delay);
      }
    }
  } catch (presenceErr) {
    console.warn('[bridge] Failed to update presence:', presenceErr.message);
  }

  const sendPromise = sock.sendMessage(chatId, payload)
    .then(async (result) => {
      try {
        if (sock && connectionState === 'connected') {
          await sock.sendPresenceUpdate('paused', chatId);
        }
      } catch {}
      return result;
    });

  return Promise.race([sendPromise, timeoutPromise])
    .finally(() => clearTimeout(timer));
}"""

    src = src.replace(old_send_func, new_send_func, 1)

    # 4. Replace connection.update close / open block
    anchor_connection = "    if (connection === 'close') {"
    end_connection = "      }\n    }\n  });"
    
    conn_start_idx = src.find(anchor_connection)
    if conn_start_idx == -1:
        print('[patch_bridge_anti_ban] ERROR: connection block anchor not found')
        sys.exit(1)
        
    conn_end_idx = src.find(end_connection, conn_start_idx)
    if conn_end_idx == -1:
        end_connection_crlf = "      }\r\n    }\r\n  });"
        conn_end_idx = src.find(end_connection_crlf, conn_start_idx)
        if conn_end_idx == -1:
            print('[patch_bridge_anti_ban] ERROR: connection block end pattern not found')
            sys.exit(1)
        end_connection = end_connection_crlf
        
    old_conn_block = src[conn_start_idx:conn_end_idx + len(end_connection)]
    
    new_conn_block = """    if (connection === 'close') {
      const reason = new Boom(lastDisconnect?.error)?.output?.statusCode;
      connectionState = 'disconnected';

      if (reason === DisconnectReason.loggedOut) {
        console.log('❌ Logged out. Delete session and restart to re-authenticate.');
        process.exit(1);
      } else {
        try {
          if (sock) {
            sock.ev.removeAllListeners('connection.update');
            sock.ev.removeAllListeners('creds.update');
            sock.ev.removeAllListeners('messages.upsert');
            if (sock.ws) sock.ws.close();
          }
        } catch (cleanupErr) {
          console.warn('[bridge] Error during socket cleanup:', cleanupErr.message);
        }

        const isRestart = reason === 515;
        const baseDelay = isRestart ? 1000 : 3000;
        const delay = isRestart
          ? baseDelay
          : Math.min(60000, Math.pow(2, reconnectAttempts) * baseDelay + Math.floor(Math.random() * 1000));
        
        if (!isRestart) reconnectAttempts++;

        console.log(`⚠️  Connection closed (reason: ${reason}). Reconnecting in ${(delay / 1000).toFixed(1)}s...`);
        setTimeout(startSocket, delay);
      }
    } else if (connection === 'open') {
      connectionState = 'connected';
      reconnectAttempts = 0;
      console.log('✅ WhatsApp connected!');
      if (PAIR_ONLY) {
        console.log('✅ Pairing complete. Credentials saved.');
        setTimeout(() => process.exit(0), 2000);
      }
    }
  });"""

    src = src.replace(old_conn_block, new_conn_block, 1)

    with open(bridge_path, 'w', encoding='utf-8') as f:
        f.write(src)

    print(f'[patch_bridge_anti_ban] Successfully patched {bridge_path}')
    return True

def verify_syntax(bridge_path):
    node = None
    for candidate in (os.path.expanduser('~/.hermes/node/bin/node'), 'node'):
        if candidate == 'node' or os.path.exists(candidate):
            node = candidate
            break
    try:
        result = subprocess.run([node, '--check', bridge_path],
                                capture_output=True, text=True)
    except FileNotFoundError:
        print('[patch_bridge_anti_ban] node not found, skipping syntax check.')
        return
    if result.returncode != 0:
        print('[patch_bridge_anti_ban] SYNTAX ERROR after patch:')
        print(result.stderr)
        sys.exit(1)
    print('[patch_bridge_anti_ban] Syntax OK')

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge', required=True, help='Path to bridge.js')
    args = parser.parse_args()

    patched = patch(args.bridge)
    if patched:
        verify_syntax(args.bridge)
