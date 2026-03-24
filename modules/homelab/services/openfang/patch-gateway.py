import sys, pathlib, re

f = pathlib.Path(sys.argv[1])
src = f.read_text()

# Check which patches are already applied
if "PATCHED_V8" in src:
    print("[patch] Already at V8")
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

# 4. Add imports: fs and downloadMediaMessage
if "import fs from" not in src:
    src = src.replace(
        "import makeWASocket",
        "import fs from 'fs'; // PATCHED_V8\nimport makeWASocket"
    )

# downloadMediaMessage — add alongside existing baileys import
if "downloadMediaMessage" not in src:
    src = src.replace(
        "} from '@whiskeysockets/baileys';",
        ", downloadMediaMessage } from '@whiskeysockets/baileys'; // PATCHED_V8"
    )

# 5. Create media dir constant
if "MEDIA_DIR" not in src:
    src = src.replace(
        "let qrDataUrl = '';",
        "let qrDataUrl = '';\n"
        "const MEDIA_DIR = '/tmp/openfang-media'; // PATCHED_V8\n"
        "try { fs.mkdirSync(MEDIA_DIR, { recursive: true }); } catch {}"
    )

# 6. Replace image placeholder with actual download
# Match the [Image received] handler and replace with download logic
if "[Image received]" in src:
    src = src.replace(
        "if (m?.imageMessage) text = '[Image received]' + (m.imageMessage.caption ? ': ' + m.imageMessage.caption : '');",
        """if (m?.imageMessage) { // PATCHED_V8: download image
          const caption = m.imageMessage.caption || '';
          try {
            const buffer = await downloadMediaMessage(msg, 'buffer', {});
            const fname = Date.now() + '.jpg';
            fs.writeFileSync(MEDIA_DIR + '/' + fname, buffer);
            metadata.__image_b64 = 'data:' + (m.imageMessage.mimetype || 'image/jpeg') + ';base64,' + buffer.toString('base64');
            text = caption || '[User sent an image]';
            console.log('[gateway] Downloaded image: ' + fname + ' (' + buffer.length + ' bytes)');
          } catch (e) {
            console.error('[gateway] Image download failed:', e.message);
            text = '[Image received but download failed]' + (caption ? ': ' + caption : '');
          }
        }"""
    )

# 7. In forwardToOpenFang, include image in payload for multimodal support
# Find the payload construction and add images field
if "payloadObj" not in src:
    src = src.replace(
        "const payload = JSON.stringify({\n      message: text,",
        "// PATCHED_V8: multimodal payload\n"
        "    const imgB64 = (metadata || {}).__image_b64;\n"
        "    if (imgB64) delete metadata.__image_b64; // don't send huge base64 in metadata\n"
        "    const payloadObj = {\n      message: text,"
    )
    # Replace the closing of JSON.stringify
    # Find: metadata closing -> });  and replace with adding images
    src = src.replace(
        "const payload = JSON.stringify(payloadObj);",
        "SHOULD_NOT_MATCH"  # safety — don't double-patch
    )
    # Use regex to find the end of the payload object and stringify
    src = re.sub(
        r'(},\s*?\n\s*?\});',
        r"""},\n    };\n"""
        """    if (imgB64) payloadObj.images = [imgB64]; // PATCHED_V8\n"""
        """    const payload = JSON.stringify(payloadObj);""",
        src,
        count=1
    )

f.write_text(src)
print("[patch] Gateway patched (V8: image download + multimodal forwarding)")
