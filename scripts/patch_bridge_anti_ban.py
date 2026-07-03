#!/usr/bin/env python3
"""Add outbound safety controls to the Hermes Baileys bridge.

The deploy-time overlay adds:
- human-like presence and bounded delays;
- one global serialized outbound queue with a minimum inter-send gap;
- a bounded queue;
- send-failure and reconnect-failure circuit breakers;
- socket/listener cleanup and exponential reconnect backoff;
- queue and circuit state in the health endpoint.
"""
import argparse
import os
import subprocess
import sys


MARKER = "HERMES_OUTBOUND_CONTROL_V2"


def patch(bridge_path):
    with open(bridge_path, "r", encoding="utf-8") as f:
        src = f.read()

    if MARKER in src:
        print(f"[patch_bridge_anti_ban] Already patched: {bridge_path}")
        return False

    anchor_state = "let connectionState = 'disconnected';"
    if anchor_state not in src:
        print("[patch_bridge_anti_ban] ERROR: connectionState anchor not found")
        sys.exit(1)

    state_block = f"""{anchor_state}
// {MARKER}
const OUTBOUND_MIN_GAP_MS = parseInt(process.env.WHATSAPP_OUTBOUND_MIN_GAP_MS || '2000', 10);
const OUTBOUND_MAX_QUEUE = parseInt(process.env.WHATSAPP_OUTBOUND_MAX_QUEUE || '3', 10);
const SEND_FAILURE_LIMIT = parseInt(process.env.WHATSAPP_SEND_FAILURE_LIMIT || '3', 10);
const RECONNECT_FAILURE_LIMIT = parseInt(process.env.WHATSAPP_RECONNECT_FAILURE_LIMIT || '5', 10);
const CIRCUIT_COOLDOWN_MS = parseInt(process.env.WHATSAPP_CIRCUIT_COOLDOWN_MS || '900000', 10);
let reconnectAttempts = 0;
let reconnectTimer = null;
let outboundQueueTail = Promise.resolve();
let outboundQueueDepth = 0;
let lastOutboundCompletedAt = 0;
let consecutiveSendFailures = 0;
let circuitOpenUntil = 0;
let circuitReason = null;"""
    src = src.replace(anchor_state, state_block, 1)

    anchor_send = "function sendWithTimeout(chatId, payload, timeoutMs = SEND_TIMEOUT_MS) {"
    if anchor_send not in src:
        print("[patch_bridge_anti_ban] ERROR: sendWithTimeout anchor not found")
        sys.exit(1)

    end_patterns = (
        "  return Promise.race([sock.sendMessage(chatId, payload), timeoutPromise])\n"
        "    .finally(() => clearTimeout(timer));\n}",
        "  return Promise.race([sock.sendMessage(chatId, payload), timeoutPromise])\r\n"
        "    .finally(() => clearTimeout(timer));\r\n}",
    )
    send_start = src.find(anchor_send)
    matched_end = next((p for p in end_patterns if src.find(p, send_start) != -1), None)
    if not matched_end:
        print("[patch_bridge_anti_ban] ERROR: sendWithTimeout end not found")
        sys.exit(1)
    send_end = src.find(matched_end, send_start) + len(matched_end)
    old_send_func = src[send_start:send_end]

    new_send_func = r"""function getTypingDelay(text) {
  return Math.max(1500, Math.min(8000, (text || '').length * 50));
}

function getRecordingDelay(buffer) {
  if (!buffer || !buffer.length) return 3000;
  const estimatedSeconds = buffer.length / 3000;
  return Math.max(2000, Math.min(8000, Math.round(estimatedSeconds * 1000)));
}

function circuitRemainingMs() {
  return Math.max(0, circuitOpenUntil - Date.now());
}

function openOutboundCircuit(reason) {
  circuitReason = reason;
  circuitOpenUntil = Math.max(circuitOpenUntil, Date.now() + CIRCUIT_COOLDOWN_MS);
  console.error(`[bridge] Outbound circuit opened (${reason}) for ${Math.ceil(CIRCUIT_COOLDOWN_MS / 1000)}s`);
}

function enqueueOutbound(operation) {
  if (outboundQueueDepth >= OUTBOUND_MAX_QUEUE) {
    return Promise.reject(new Error(`Outbound queue full (${OUTBOUND_MAX_QUEUE})`));
  }
  outboundQueueDepth += 1;

  const run = outboundQueueTail.then(async () => {
    const circuitWait = circuitRemainingMs();
    if (circuitWait > 0) {
      throw new Error(`Outbound circuit open (${circuitReason || 'unknown'}), retry in ${Math.ceil(circuitWait / 1000)}s`);
    }

    const gapWait = Math.max(0, lastOutboundCompletedAt + OUTBOUND_MIN_GAP_MS - Date.now());
    if (gapWait > 0) await sleep(gapWait);

    try {
      const result = await operation();
      consecutiveSendFailures = 0;
      lastOutboundCompletedAt = Date.now();
      return result;
    } catch (err) {
      consecutiveSendFailures += 1;
      lastOutboundCompletedAt = Date.now();
      if (consecutiveSendFailures >= SEND_FAILURE_LIMIT) {
        openOutboundCircuit(`send_failures:${consecutiveSendFailures}`);
      }
      throw err;
    }
  }).finally(() => {
    outboundQueueDepth -= 1;
  });

  outboundQueueTail = run.catch(() => undefined);
  return run;
}

async function sendWithTimeout(chatId, payload, timeoutMs = SEND_TIMEOUT_MS) {
  return enqueueOutbound(async () => {
    if (!sock || connectionState !== 'connected') {
      throw new Error('Not connected to WhatsApp');
    }

    try {
      if (payload.text && !payload.edit) {
        await sock.sendPresenceUpdate('composing', chatId);
        await sleep(getTypingDelay(payload.text));
      } else if (payload.audio) {
        if (payload.ptt) {
          await sock.sendPresenceUpdate('recording', chatId);
          await sleep(getRecordingDelay(payload.audio));
        } else {
          await sock.sendPresenceUpdate('composing', chatId);
          await sleep(2000);
        }
      } else if (payload.image || payload.video || payload.document) {
        await sock.sendPresenceUpdate('composing', chatId);
        await sleep(Math.floor(Math.random() * 1500) + 1500);
      }
    } catch (presenceErr) {
      console.warn('[bridge] Failed to update presence:', presenceErr.message);
    }

    let timer;
    const timeoutPromise = new Promise((_, reject) => {
      timer = setTimeout(
        () => reject(new Error(`sendMessage timed out after ${timeoutMs / 1000}s`)),
        timeoutMs,
      );
    });

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
  });
}"""
    src = src.replace(old_send_func, new_send_func, 1)

    anchor_connection = "    if (connection === 'close') {"
    connection_end_patterns = (
        "      }\n    }\n  });",
        "      }\r\n    }\r\n  });",
    )
    conn_start = src.find(anchor_connection)
    if conn_start == -1:
        print("[patch_bridge_anti_ban] ERROR: connection block anchor not found")
        sys.exit(1)
    conn_end_pattern = next(
        (p for p in connection_end_patterns if src.find(p, conn_start) != -1),
        None,
    )
    if not conn_end_pattern:
        print("[patch_bridge_anti_ban] ERROR: connection block end not found")
        sys.exit(1)
    conn_end = src.find(conn_end_pattern, conn_start) + len(conn_end_pattern)
    old_conn_block = src[conn_start:conn_end]

    new_conn_block = r"""    if (connection === 'close') {
      const reason = new Boom(lastDisconnect?.error)?.output?.statusCode;
      connectionState = 'disconnected';

      if (reason === DisconnectReason.loggedOut) {
        console.log('[bridge] Logged out. Delete session and re-authenticate.');
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
        if (!isRestart) reconnectAttempts += 1;
        if (!isRestart && reconnectAttempts >= RECONNECT_FAILURE_LIMIT) {
          openOutboundCircuit(`reconnect_failures:${reconnectAttempts}`);
        }
        const backoffDelay = isRestart
          ? baseDelay
          : Math.min(60000, Math.pow(2, Math.max(0, reconnectAttempts - 1)) * baseDelay + Math.floor(Math.random() * 1000));
        const delay = Math.max(backoffDelay, circuitRemainingMs());

        console.log(`[bridge] Connection closed (reason: ${reason}). Reconnecting in ${(delay / 1000).toFixed(1)}s...`);
        if (reconnectTimer) clearTimeout(reconnectTimer);
        reconnectTimer = setTimeout(() => {
          reconnectTimer = null;
          startSocket();
        }, delay);
      }
    } else if (connection === 'open') {
      connectionState = 'connected';
      reconnectAttempts = 0;
      consecutiveSendFailures = 0;
      circuitOpenUntil = 0;
      circuitReason = null;
      if (reconnectTimer) clearTimeout(reconnectTimer);
      reconnectTimer = null;
      console.log('[bridge] WhatsApp connected.');
      if (PAIR_ONLY) {
        console.log('[bridge] Pairing complete. Credentials saved.');
        setTimeout(() => process.exit(0), 2000);
      }
    }
  });"""
    src = src.replace(old_conn_block, new_conn_block, 1)

    health_anchor = "    queueLength: messageQueue.length,"
    if health_anchor not in src:
        print("[patch_bridge_anti_ban] ERROR: health queueLength anchor not found")
        sys.exit(1)
    health_fields = """    queueLength: messageQueue.length,
    outboundQueueDepth,
    outboundQueueLimit: OUTBOUND_MAX_QUEUE,
    outboundMinGapMs: OUTBOUND_MIN_GAP_MS,
    consecutiveSendFailures,
    reconnectAttempts,
    circuitOpen: circuitRemainingMs() > 0,
    circuitReason,
    circuitRetryAfterMs: circuitRemainingMs(),"""
    src = src.replace(health_anchor, health_fields, 1)

    with open(bridge_path, "w", encoding="utf-8") as f:
        f.write(src)

    print(f"[patch_bridge_anti_ban] Successfully patched {bridge_path}")
    return True


def verify_syntax(bridge_path):
    node = next(
        (
            candidate
            for candidate in (os.path.expanduser("~/.hermes/node/bin/node"), "node")
            if candidate == "node" or os.path.exists(candidate)
        ),
        "node",
    )
    try:
        result = subprocess.run(
            [node, "--check", bridge_path], capture_output=True, text=True
        )
    except FileNotFoundError:
        print("[patch_bridge_anti_ban] node not found, skipping syntax check.")
        return
    if result.returncode != 0:
        print("[patch_bridge_anti_ban] SYNTAX ERROR after patch:")
        print(result.stderr)
        sys.exit(1)
    print("[patch_bridge_anti_ban] Syntax OK")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--bridge", required=True, help="Path to bridge.js")
    args = parser.parse_args()

    patched = patch(args.bridge)
    if patched:
        verify_syntax(args.bridge)
