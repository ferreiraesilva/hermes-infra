#!/usr/bin/env python3
"""
Patch bridge.js to buffer text sends and merge them as captions for images/videos/documents.
"""
import argparse
import sys

def patch(bridge_path):
    with open(bridge_path, 'r', encoding='utf-8') as f:
        src = f.read()

    if 'pendingCaptions' in src:
        print(f'[patch_bridge_caption] Already patched: {bridge_path}')
        return False

    # Anchor for /send POST handler
    anchor_send = "// Send a message\napp.post('/send', async (req, res) => {"
    if anchor_send not in src:
        print(f'[patch_bridge_caption] ERROR: "/send" endpoint handler not found')
        sys.exit(1)

    # Replacement for /send
    send_replacement = """const pendingCaptions = new Map();

async function sendTextMessageWithoutResponding(chatId, message, replyTo) {
  try {
    const chunks = splitLongMessage(formatOutgoingMessage(message));
    for (let i = 0; i < chunks.length; i += 1) {
      const sent = await sendWithTimeout(chatId, { text: chunks[i] });
      trackSentMessageId(sent);
      if (chunks.length > 1 && i < chunks.length - 1) {
        await sleep(CHUNK_DELAY_MS);
      }
    }
  } catch (err) {
    console.error('[bridge] Failed to send buffered text:', err.message);
  }
}

// Send a message
app.post('/send', async (req, res) => {
  if (!sock || connectionState !== 'connected') {
    return res.status(503).json({ error: 'Not connected to WhatsApp' });
  }

  const { chatId, message, replyTo } = req.body;
  if (!chatId || !message) {
    return res.status(400).json({ error: 'chatId and message are required' });
  }

  const blocks = message.split(/\\r?\\n\\r?\\n/).map(b => b.trim()).filter(Boolean);
  let captions = [];

  if (blocks.length > 0) {
    const firstBlock = blocks[0];
    const hasIntro = firstBlock.endsWith(':');
    if (hasIntro) {
      // Send the intro immediately as a separate message!
      sendTextMessageWithoutResponding(chatId, firstBlock, replyTo).catch(() => {});
      captions = blocks.slice(1);
    } else {
      captions = blocks;
    }
  }

  if (captions.length === 0) {
    res.json({
      success: true,
      messageId: 'intro_only_' + Date.now(),
      messageIds: ['intro_only_' + Date.now()]
    });
    return;
  }

  if (pendingCaptions.has(chatId)) {
    const pending = pendingCaptions.get(chatId);
    clearTimeout(pending.timer);
    pendingCaptions.delete(chatId);
    for (const remaining of pending.captions) {
      sendTextMessageWithoutResponding(chatId, remaining, pending.replyTo).catch(() => {});
    }
  }

  const timer = setTimeout(async () => {
    pendingCaptions.delete(chatId);
    for (const remaining of captions) {
      try {
        await sendTextMessageWithoutResponding(chatId, remaining, replyTo);
      } catch (err) {}
    }
  }, 1000);

  pendingCaptions.set(chatId, {
    originalMessage: message,
    captions: captions,
    replyTo,
    timer
  });

  res.json({
    success: true,
    messageId: 'buffered_' + Date.now(),
    messageIds: ['buffered_' + Date.now()]
  });
});"""

    # We need to find the entire old app.post('/send', ...) block and replace it
    # We can do this by finding the start anchor and matching braces, or doing a targeted string replace
    # Let's locate the full block
    start_idx = src.find(anchor_send)
    # Let's find the closing "});" of app.post('/send')
    end_pattern = "    res.status(500).json({ error: err.message });\n  }\n});"
    end_idx = src.find(end_pattern, start_idx)
    if end_idx == -1:
        print('[patch_bridge_caption] ERROR: end pattern of /send not found')
        sys.exit(1)
    
    full_send_block = src[start_idx:end_idx + len(end_pattern)]
    src = src.replace(full_send_block, send_replacement, 1)

    # Now let's handle the /send-media endpoint
    anchor_send_media = "// Send media (image, video, document) natively\napp.post('/send-media', async (req, res) => {"
    if anchor_send_media not in src:
        print('[patch_bridge_caption] ERROR: "/send-media" endpoint handler not found')
        sys.exit(1)

    media_old_start = """    const buffer = readFileSync(filePath);
    const ext = filePath.toLowerCase().split('.').pop();
    const type = mediaType || inferMediaType(ext);
    let msgPayload;"""

    media_new_start = """    const buffer = readFileSync(filePath);
    const ext = filePath.toLowerCase().split('.').pop();
    const type = mediaType || inferMediaType(ext);
    let msgPayload;

    let mergedCaption = caption;
    // Explicit adapter captions always win. Buffered text is only a legacy
    // fallback for callers that did not provide a native caption.
    if (!mergedCaption && pendingCaptions.has(chatId)) {
      const pending = pendingCaptions.get(chatId);
      clearTimeout(pending.timer);
      if (type !== 'audio') {
        if (pending.captions && pending.captions.length > 0) {
          mergedCaption = pending.captions.shift();
        }
      } else {
        for (const remaining of pending.captions) {
          sendTextMessageWithoutResponding(chatId, remaining, pending.replyTo).catch(() => {});
        }
        pending.captions = [];
      }

      if (pending.captions && pending.captions.length > 0) {
        pending.timer = setTimeout(async () => {
          pendingCaptions.delete(chatId);
          let hasClosing = false;
          for (const remaining of pending.captions) {
            try {
              if (remaining.toLowerCase().includes("ajudar") || remaining.toLowerCase().includes("mais")) {
                hasClosing = true;
              }
              await sendTextMessageWithoutResponding(chatId, remaining, pending.replyTo);
            } catch (err) {}
          }
          if (!hasClosing) {
            try {
              await sendTextMessageWithoutResponding(chatId, "Posso ajudar com algo mais?", pending.replyTo);
            } catch (err) {}
          }
        }, 3000);
      } else {
        pendingCaptions.delete(chatId);
        setTimeout(() => {
          sendTextMessageWithoutResponding(chatId, "Posso ajudar com algo mais?", pending.replyTo).catch(() => {});
        }, 1000);
      }
    }"""

    if media_old_start not in src:
        print('[patch_bridge_caption] ERROR: media_old_start not found in /send-media')
        sys.exit(1)

    src = src.replace(media_old_start, media_new_start, 1)

    # Now replace the occurrences of "caption: caption" with "caption: mergedCaption"
    image_old = "msgPayload = { image: buffer, caption: caption || undefined"
    image_new = "msgPayload = { image: buffer, caption: mergedCaption || undefined"
    if image_old not in src:
        print('[patch_bridge_caption] ERROR: image payload pattern not found')
        sys.exit(1)
    src = src.replace(image_old, image_new, 1)

    video_old = "msgPayload = { video: buffer, caption: caption || undefined"
    video_new = "msgPayload = { video: buffer, caption: mergedCaption || undefined"
    if video_old not in src:
        print('[patch_bridge_caption] ERROR: video payload pattern not found')
        sys.exit(1)
    src = src.replace(video_old, video_new, 1)

    doc_old = """          document: buffer,
          fileName: fileName || path.basename(filePath),
          caption: caption || undefined,"""
    doc_new = """          document: buffer,
          fileName: fileName || path.basename(filePath),
          caption: mergedCaption || undefined,"""
    if doc_old not in src:
        print('[patch_bridge_caption] ERROR: doc payload pattern not found')
        sys.exit(1)
    src = src.replace(doc_old, doc_new, 1)

    with open(bridge_path, 'w', encoding='utf-8') as f:
        f.write(src)

    print(f'[patch_bridge_caption] Successfully patched {bridge_path}')
    return True

if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--bridge', required=True, help='Path to bridge.js')
    args = parser.parse_args()

    patch(args.bridge)
