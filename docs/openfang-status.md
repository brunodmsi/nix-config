# OpenFang + WhatsApp — WORKING

## Architecture
```
WhatsApp ←→ Evolution API v2.3.7 (container) ←→ Bridge (socat) ←→ OpenFang ←→ Claude Haiku 4.5
                    port 8080                      port 3010         port 50051
```

## Components
- **OpenFang**: AI agent, port 50051, binary at /persist/openfang/.openfang/bin/openfang
- **Evolution API**: WhatsApp gateway, v2.3.7 built from source as podman container, port 8080
- **Bridge**: socat webhook receiver on port 3010, forwards messages between Evolution and OpenFang
- **LLM**: Claude Haiku 4.5 (Anthropic API)

## Features
- Dedup: atomic mkdir prevents duplicate message processing
- Allowed senders: agenix secret with approved phone numbers
- Manager UI: https://wa-setup.demasi.dev/manager/ (behind Authelia)
- Instance name: sweet-zap

## Key files
- `/Users/brunodemasi/pers/nix-config/modules/homelab/services/openfang/default.nix` — OpenFang service
- `/Users/brunodemasi/pers/nix-config/modules/homelab/services/openfang/evolution-bridge.nix` — Evolution + bridge
- `/persist/openfang/` — OpenFang config (survives immutable root)
- `/var/lib/openfang/dedup/` — message dedup state

## Phone number format
Evolution strips a digit: real number 5591984519877 becomes 559184519877 in webhooks.
Allowed senders file must use the Evolution format (559184519877).
