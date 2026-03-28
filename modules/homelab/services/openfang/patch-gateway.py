import sys, pathlib

f = pathlib.Path(sys.argv[1])
src = f.read_text()
if "PATCHED_V12" in src:
    print("[patch] Already patched (V8)")
    sys.exit(0)

# Remove old patch markers
for old_v in ["PATCHED_V7", "PATCHED_V8", "PATCHED_V9", "PATCHED_V10", "PATCHED_V11"]:
    src = src.replace(old_v, "")

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
        lines[i] = '          const replyJid = remoteJid; // PATCHED_V12: reply to remoteJid directly'
        break
src = '\n'.join(lines)

# --- Patch 3: Use real phone number (senderPn) instead of LID ---
lines = src.split('\n')
for i, line in enumerate(lines):
    if "const phone = '+' + senderJid" in line:
        lines[i] = (
            "      // PATCHED_V12: use senderPn (real phone) when available\n"
            "      const senderPn = msg.key.senderPn ? msg.key.senderPn.replace(/@.*$/, '') : null;\n"
            "      const phone = '+' + (senderPn || senderJid.replace(/@.*$/, ''));"
        )
        break
src = '\n'.join(lines)

# --- Patch 4: Add remote_jid and message_id to metadata ---
if "remote_jid: remoteJid," not in src:
    src = src.replace(
        "sender_name: pushName,",
        "sender_name: pushName,\n        remote_jid: remoteJid,  // PATCHED_V12\n        message_id: msg.key.id,  // PATCHED_V12: for reply quoting"
    )

# --- Patch 5: Add media download + media fields in metadata ---
# Inject download code BEFORE the fetch/payload construction.
# Find the line right before the HTTP request is made (look for the fetch/request payload).
# The gateway builds a payload with { metadata: { sender, sender_name, ... }, content: ... }
# We inject media download after phone extraction and before the payload is built.

media_download_block = '''
      // PATCHED_V12: Download media if present
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

if "PATCHED_V12: Download media" not in src:
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
        "remote_jid: remoteJid,  // PATCHED_V12",
        "remote_jid: remoteJid,  // PATCHED_V12\n"
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
                lines[i] = f"{indent}{field_name}: (typeof captionText !== 'undefined' && captionText) || {value_part},  // PATCHED_V12: caption fallback"
                print(f"[patch] Added caption fallback to {field_name} field (line {i+1})")
                break
src = '\n'.join(lines)

# --- Patch 7: Add /api/send HTTP endpoint for async replies ---
# The router sends replies here instead of relying on the synchronous response.
# We add a small HTTP server alongside the Baileys socket.

# Import for HTTP send server (add to top with other imports)
import_line = "import { createServer as createHttpSendServer } from 'node:http'; // PATCHED_V12"
if "createHttpSendServer" not in src:
    lines = src.split('\n')
    last_import = 0
    for i, line in enumerate(lines):
        if line.strip().startswith('import ') and 'from ' in line:
            last_import = i
    if last_import > 0:
        lines.insert(last_import + 1, import_line)
        src = '\n'.join(lines)
        print(f"[patch] Added createHttpSendServer import after line {last_import + 1}")

# Send endpoint server (append to end of file — sock is already initialized)
send_endpoint_block = '''
// PATCHED_V12: HTTP send endpoint for async replies from router
const SEND_PORT = parseInt(process.env.WHATSAPP_SEND_PORT || '3010');
const sendServer = createHttpSendServer((req, res) => {
  if (req.method === 'POST' && req.url === '/api/send') {
    let body = '';
    req.on('data', chunk => body += chunk);
    req.on('end', async () => {
      try {
        const parsed = JSON.parse(body);
        const { jid } = parsed;
        if (!jid) {
          res.writeHead(400);
          res.end(JSON.stringify({ error: 'jid required' }));
          return;
        }
        // Typing indicator
        if (parsed.action === 'composing') {
          await sock.sendPresenceUpdate('composing', jid);
          res.writeHead(200);
          res.end(JSON.stringify({ ok: true }));
          return;
        }
        const { text, quotedId } = parsed;
        if (!text) {
          res.writeHead(400);
          res.end(JSON.stringify({ error: 'text required' }));
          return;
        }
        const msgOptions = { text };
        if (quotedId) {
          msgOptions.quoted = { key: { remoteJid: jid, id: quotedId, fromMe: false } };
        }
        await sock.sendMessage(jid, msgOptions);
        console.log('[gateway] Sent async reply to ' + jid.split('@')[0]);
        res.writeHead(200);
        res.end(JSON.stringify({ ok: true }));
      } catch (e) {
        console.error('[gateway] Send endpoint error:', e.message);
        res.writeHead(500);
        res.end(JSON.stringify({ error: e.message }));
      }
    });
  } else {
    res.writeHead(404);
    res.end('Not found');
  }
});
sendServer.listen(SEND_PORT, '127.0.0.1', () => {
  console.log('[gateway] Send endpoint listening on http://127.0.0.1:' + SEND_PORT + '/api/send');
});
'''

if "PATCHED_V12: HTTP send endpoint" not in src:
    src = src.rstrip() + '\n' + send_endpoint_block
    print("[patch] Appended send endpoint to end of file")

# --- Patch 8: Suppress reply when router returns {"status":"accepted"} ---
# The gateway normally sends the response text as a WhatsApp reply.
# With async routing, the response is {"status":"accepted"} — skip the reply.
if 'PATCHED_V12: skip accepted' not in src:
    # Find the sendMessage reply line and wrap it with a check
    lines = src.split('\n')
    for i, line in enumerate(lines):
        if 'sendMessage' in line and 'replyJid' in line and 'PATCHED' not in line:
            indent = line[:len(line) - len(line.lstrip())]
            # Wrap with check: skip if response is {"status":"accepted"}
            lines[i] = (
                f'{indent}// PATCHED_V12: skip accepted (async reply handled by router)\n'
                f'{indent}if (typeof responseText !== "undefined" && responseText && !responseText.includes(\'"status":"accepted"\')) {{\n'
                f'{line}\n'
                f'{indent}}}'
            )
            print(f"[patch] Wrapped sendMessage with accepted-check (line {i+1})")
            break
    src = '\n'.join(lines)

f.write_text(src)
print("[patch] Gateway patched (V9: media download + senderPn + remoteJid + caption + async send)")
