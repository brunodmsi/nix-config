import sys, pathlib

f = pathlib.Path(sys.argv[1])
src = f.read_text()

# Check which patches are already applied
if "PATCHED_V9" in src:
    print("[patch] Already at V9")
    sys.exit(0)

# If V7 not applied yet, apply V7 patches first
if "PATCHED_V7" not in src:
    # 1. Fix DM replies: use remoteJid directly
    lines = src.split('\n')
    for i, line in enumerate(lines):
        if 'const replyJid' in line and 's.whatsapp.net' in line:
            lines[i] = '          const replyJid = remoteJid; // PATCHED_V7: reply to remoteJid directly'
            break
    src = '\n'.join(lines)

    # 2. Use real phone number (senderPn) instead of LID
    lines = src.split('\n')
    for i, line in enumerate(lines):
        if "const phone = '+' + senderJid" in line:
            lines[i] = (
                "      // PATCHED_V7: use senderPn (real phone) when available\n"
                "      const senderPn = msg.key.senderPn ? msg.key.senderPn.replace(/@.*$/, '') : null;\n"
                "      const phone = '+' + (senderPn || senderJid.replace(/@.*$/, ''));"
            )
            break
    src = '\n'.join(lines)

    # 3. Add remote_jid to metadata
    src = src.replace(
        "sender_name: pushName,",
        "sender_name: pushName,\n        remote_jid: remoteJid,"
    )

# --- V8: Image download + multimodal forwarding ---

# 4. Add fs import at the top
if "import fs from" not in src:
    src = src.replace(
        "import makeWASocket",
        "import fs from 'fs'; // PATCHED_V8\nimport makeWASocket"
    )

# 5. Add downloadMediaMessage to baileys import
if "downloadMediaMessage" not in src:
    src = src.replace(
        "} from '@whiskeysockets/baileys';",
        ", downloadMediaMessage } from '@whiskeysockets/baileys'; // PATCHED_V8"
    )

# 6. Create media dir constant
if "MEDIA_DIR" not in src:
    src = src.replace(
        "let qrDataUrl = '';",
        "let qrDataUrl = '';\n"
        "const MEDIA_DIR = '/tmp/openfang-media'; // PATCHED_V8\n"
        "try { fs.mkdirSync(MEDIA_DIR, { recursive: true }); } catch {}"
    )

# 7. Remove imageMessage.caption from initial text extraction so image handler runs
if "imageMessage?.caption" in src and "PATCHED_V8_CAPTION" not in src:
    src = src.replace(
        "|| msg.message?.imageMessage?.caption",
        "// PATCHED_V8_CAPTION: removed — image handler below deals with caption"
    )

# 8. Replace image placeholder with download logic
# Also handle the case where text was already set from caption (move image check before if(!text))
if "[Image received]" in src:
    # Replace the old image handler inside if(!text)
    src = src.replace(
        "if (m?.imageMessage) text = '[Image received]' + (m.imageMessage.caption ? ': ' + m.imageMessage.caption : '');",
        "if (m?.imageMessage) { text = '[Image received]'; } // placeholder, handled below"
    )

# Add image download AFTER the if(!text) block, before the sender extraction
# This runs for ALL image messages regardless of caption
if "PATCHED_V9" not in src:
    # Store image base64 in a variable BEFORE metadata is created
    src = src.replace(
        "      // For groups: real sender is in participant",
        """      // PATCHED_V9: download image if present (before metadata is created)
      let __imageB64 = null;
      if (msg.message?.imageMessage) {
        const imgMsg = msg.message.imageMessage;
        const caption = imgMsg.caption || '';
        try {
          const buffer = await downloadMediaMessage(msg, 'buffer', {});
          const fname = Date.now() + '.jpg';
          fs.writeFileSync(MEDIA_DIR + '/' + fname, buffer);
          __imageB64 = 'data:' + (imgMsg.mimetype || 'image/jpeg') + ';base64,' + buffer.toString('base64');
          if (!text || text === '[Image received]') text = caption || '[User sent an image]';
          console.log('[gateway] Downloaded image: ' + fname + ' (' + buffer.length + ' bytes)');
        } catch (e) {
          console.error('[gateway] Image download failed:', e.message);
          if (!text || text === '[Image received]') text = '[Image received but download failed]' + (caption ? ': ' + caption : '');
        }
      }

      // For groups: real sender is in participant"""
    )

    # Attach image to metadata AFTER metadata is created
    src = src.replace(
        "      if (isGroup) {",
        "      // PATCHED_V9: attach image to metadata\n"
        "      if (__imageB64) metadata.__image_b64 = __imageB64;\n\n"
        "      if (isGroup) {"
    )

# 9. Replace forwardToOpenFang payload to support images
# Find the exact original payload pattern and replace the whole block
OLD_FORWARD = """    const payload = JSON.stringify({
      message: text,
      metadata: metadata || {
        channel: 'whatsapp',
        sender: phone,
        sender_name: pushName,
        remote_jid: remoteJid,
      },
    });"""

NEW_FORWARD = """    // PATCHED_V8: multimodal payload with image support
    const imgB64 = (metadata || {}).__image_b64;
    if (imgB64) delete metadata.__image_b64;
    const payloadObj = {
      message: text,
      metadata: metadata || {
        channel: 'whatsapp',
        sender: phone,
        sender_name: pushName,
        remote_jid: remoteJid,
      },
    };
    if (imgB64) payloadObj.images = [imgB64];
    const payload = JSON.stringify(payloadObj);"""

if "payloadObj" not in src:
    # Try exact match first
    if OLD_FORWARD in src:
        src = src.replace(OLD_FORWARD, NEW_FORWARD)
    else:
        # Fallback: find the payload line and do a line-by-line replacement
        lines = src.split('\n')
        for i, line in enumerate(lines):
            if 'const payload = JSON.stringify({' in line and i + 8 < len(lines):
                # Find the closing });
                end = i + 1
                while end < len(lines) and '});' not in lines[end]:
                    end += 1
                # Replace from i to end (inclusive)
                indent = '    '
                new_lines = [
                    indent + '// PATCHED_V8: multimodal payload with image support',
                    indent + 'const imgB64 = (metadata || {}).__image_b64;',
                    indent + 'if (imgB64) delete metadata.__image_b64;',
                    indent + 'const payloadObj = {',
                    indent + '  message: text,',
                    indent + '  metadata: metadata || {',
                    indent + "    channel: 'whatsapp',",
                    indent + '    sender: phone,',
                    indent + '    sender_name: pushName,',
                    indent + '    remote_jid: remoteJid,',
                    indent + '  },',
                    indent + '};',
                    indent + 'if (imgB64) payloadObj.images = [imgB64];',
                    indent + 'const payload = JSON.stringify(payloadObj);',
                ]
                lines[i:end + 1] = new_lines
                src = '\n'.join(lines)
                break

f.write_text(src)
print("[patch] Gateway patched (V9: image download fix for captioned images)")
