import sys, pathlib

f = pathlib.Path(sys.argv[1])
src = f.read_text()
if "PATCHED_V7" in src:
    print("[patch] Already patched")
    sys.exit(0)

# 1. Fix DM replies: use remoteJid directly (LID JIDs are valid for sending)
lines = src.split('\n')
for i, line in enumerate(lines):
    if 'const replyJid' in line and 's.whatsapp.net' in line:
        lines[i] = '          const replyJid = remoteJid; // PATCHED_V7: reply to remoteJid directly'
        break
src = '\n'.join(lines)

# 2. Use real phone number (senderPn) instead of LID for sender identity
for i, line in enumerate(lines):
    if "const phone = '+' + senderJid" in line:
        lines[i] = (
            "      // PATCHED_V7: use senderPn (real phone) when available\n"
            "      const senderPn = msg.key.senderPn ? msg.key.senderPn.replace(/@.*$/, '') : null;\n"
            "      const phone = '+' + (senderPn || senderJid.replace(/@.*$/, ''));"
        )
        break
src = '\n'.join(lines)

# 3. Add remote_jid to metadata sent to OpenFang
src = src.replace(
    "sender_name: pushName,",
    "sender_name: pushName,\n        remote_jid: remoteJid,"
)

f.write_text(src)
print("[patch] Gateway patched (V7: senderPn phone + remoteJid reply + remote_jid metadata)")
