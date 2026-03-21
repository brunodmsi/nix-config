# WhatsApp Allowed Senders Plan

## Goal
Only process messages from approved phone numbers. All others silently dropped.

## Implementation

### 1. Secret file (nix-secrets repo)
Add `whatsappAllowedSenders.age` containing one number per line:
```
5591984519877
5511999998888
```

### 2. secrets.nix entry
```nix
"whatsappAllowedSenders.age".publicKeys = all;
```

### 3. Agenix declaration (configuration.nix)
```nix
whatsappAllowedSenders.file = "${inputs.secrets}/whatsappAllowedSenders.age";
```

### 4. OpenFang module option
Add to openfang options:
```nix
allowedSendersFile = lib.mkOption {
  type = lib.types.path;
  description = "File with allowed WhatsApp numbers, one per line";
};
```

### 5. Bridge script change
Before forwarding to OpenFang, check:
```bash
if ! grep -q "$SENDER" /run/agenix/whatsappAllowedSenders; then
  echo "[bridge] Rejected message from unauthorized sender: $SENDER" >&2
  exit 0
fi
```

### 6. Homelab config
```nix
openfang.allowedSendersFile = config.age.secrets.whatsappAllowedSenders.path;
```

## Steps to implement
1. Add secret entry to nix-secrets/secrets.nix
2. Encrypt file with allowed numbers on server
3. Push nix-secrets
4. Add agenix declaration in configuration.nix
5. Add option to openfang module
6. Add grep check in bridge webhook handler
7. Push nix-config, rebuild

## Notes
- Numbers in file should match Evolution's format (country code + number, no +, no @s.whatsapp.net)
- Check actual format from bridge logs first (is it 559184519877 or 5591984519877?)
- Adding/removing numbers requires re-encrypting the secret and rebuilding
