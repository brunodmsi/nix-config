import sys, pathlib

f = pathlib.Path(sys.argv[1])
src = f.read_text()
if "PATCHED_V9" in src:
    print("[patch] Already patched (V8)")
    sys.exit(0)

# Remove old patch markers
src = src.replace("PATCHED_V7", "")

# --- Patch 1: Add downloadMediaMessage to Baileys import ---
# ESM style: import { makeWASocket, ... } from '@whiskeysockets/baileys'
lines = src.split('\n')
for i, line in enumerate(lines):
    if 'baileys' in line.lower() and 'import' in line and 'downloadMediaMessage' not in line:
        lines[i] = line.replace('}', ', downloadMediaMessage }')
        print(f"[patch] Added downloadMediaMessage to import (line {i+1})")
        break
src = '\n'.join(lines)

# --- Patch 2: Fix DM replies — use remoteJid directly ---
lines = src.split('\n')
for i, line in enumerate(lines):
    if 'const replyJid' in line and 's.whatsapp.net' in line:
        lines[i] = '          const replyJid = remoteJid; // PATCHED_V9: reply to remoteJid directly'
        break
src = '\n'.join(lines)

# --- Patch 3: Use real phone number (senderPn) instead of LID ---
lines = src.split('\n')
for i, line in enumerate(lines):
    if "const phone = '+' + senderJid" in line:
        lines[i] = (
            "      // PATCHED_V9: use senderPn (real phone) when available\n"
            "      const senderPn = msg.key.senderPn ? msg.key.senderPn.replace(/@.*$/, '') : null;\n"
            "      const phone = '+' + (senderPn || senderJid.replace(/@.*$/, ''));"
        )
        break
src = '\n'.join(lines)

# --- Patch 4: Add remote_jid to metadata ---
if "remote_jid: remoteJid," not in src:
    src = src.replace(
        "sender_name: pushName,",
        "sender_name: pushName,\n        remote_jid: remoteJid,  // PATCHED_V9"
    )

# --- Patch 5: Add media download + media fields in metadata ---
# Inject download code BEFORE the fetch/payload construction.
# Find the line right before the HTTP request is made (look for the fetch/request payload).
# The gateway builds a payload with { metadata: { sender, sender_name, ... }, content: ... }
# We inject media download after phone extraction and before the payload is built.

media_download_block = '''
      // PATCHED_V9: Download media if present
      let media_type = null;
      let media_base64 = null;
      let media_mimetype = null;
      let media_filename = null;
      let captionText = null;

      const msgContent = msg.message || {};
      const mediaTypes = {
        imageMessage: 'image',
        documentMessage: 'document',
        audioMessage: 'audio',
        videoMessage: 'video',
        stickerMessage: 'sticker',
      };

      for (const [key, type] of Object.entries(mediaTypes)) {
        if (msgContent[key]) {
          try {
            const stream = await downloadMediaMessage(msg, 'buffer', {});
            media_base64 = stream.toString('base64');
            media_type = type;
            media_mimetype = msgContent[key].mimetype || 'application/octet-stream';
            media_filename = msgContent[key].fileName || null;
            captionText = msgContent[key].caption || null;
            console.log('[gateway] Downloaded ' + type + ' (' + media_mimetype + ', ' + Math.round(media_base64.length * 3 / 4 / 1024) + ' KB)');
          } catch (e) {
            console.error('[gateway] Failed to download ' + type + ':', e.message);
          }
          break;
        }
      }
'''

if "PATCHED_V9: Download media" not in src:
    # Find the phone extraction line and inject after it
    lines = src.split('\n')
    inject_after = None
    for i, line in enumerate(lines):
        if "const phone = '+' + (senderPn ||" in line:
            inject_after = i
            break

    if inject_after is not None:
        lines.insert(inject_after + 1, media_download_block)
        src = '\n'.join(lines)
        print(f"[patch] Injected media download code after line {inject_after + 1}")

# Add media fields to the metadata payload
if "media_type: media_type," not in src:
    src = src.replace(
        "remote_jid: remoteJid,  // PATCHED_V9",
        "remote_jid: remoteJid,  // PATCHED_V9\n"
        "        media_type: media_type,\n"
        "        media_base64: media_base64,\n"
        "        media_mimetype: media_mimetype,\n"
        "        media_filename: media_filename,"
    )

# Use caption as content for media messages (images/videos can have captions)
# Find where 'content' or 'message' field is set in the payload and add caption fallback
# The gateway typically sends: content: messageText or message: messageText
# We want: content: captionText || messageText
lines = src.split('\n')
for i, line in enumerate(lines):
    # Look for the content/message field in the payload (near the metadata block)
    # Common patterns: content: text, message: text, content: messageText
    if ('content:' in line or 'message:' in line) and 'metadata' not in line and 'PATCHED' not in line:
        # Only patch lines that look like payload field assignments near the fetch call
        stripped = line.strip()
        if stripped.startswith('content:') or stripped.startswith('message:'):
            # Extract the value part
            if 'captionText' not in line:
                # Replace "content: X" with "content: captionText || X"
                colon_idx = line.index(':')
                field_name = line[:colon_idx].strip()
                value_part = line[colon_idx+1:].strip().rstrip(',')
                indent = line[:len(line) - len(line.lstrip())]
                lines[i] = f"{indent}{field_name}: (typeof captionText !== 'undefined' && captionText) || {value_part},  // PATCHED_V9: caption fallback"
                print(f"[patch] Added caption fallback to {field_name} field (line {i+1})")
                break
src = '\n'.join(lines)

f.write_text(src)
print("[patch] Gateway patched (V8: media download + senderPn + remoteJid + caption)")
