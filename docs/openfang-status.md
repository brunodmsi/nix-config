# OpenFang + WhatsApp Status

## What works
- OpenFang agent running on port 50051 with Claude Sonnet 4
- Agent responds to API calls (tool calling, conversations)
- Evolution API PostgreSQL database set up and migrated

## What doesn't work
- **WhatsApp sending via Baileys (OpenFang gateway)** — Baileys can receive but sock.sendMessage() times out
- **WhatsApp QR via Evolution API v2.2.3 Docker** — connects to WhatsApp servers but never generates QR
- **Evolution API v2.3.7 from source** — Prisma engine incompatible with NixOS, can't generate client

## Next session plan

### Option A: Build Evolution v2.3.7 as container (recommended)
1. Re-enable podman (minimal config, just for Evolution)
2. Build v2.3.7 from source using their Dockerfile: `podman build -t evolution-api:v2.3.7 https://github.com/EvolutionAPI/evolution-api.git#2.3.7`
3. Run with --network=host
4. This gets us v2.3.7 (newer Baileys) in a container (Prisma works fine in container)

### Option B: Use n8n/make.com as WhatsApp bridge
- External service that handles WhatsApp connection
- Webhooks to/from OpenFang

### Option C: Wait for Meta Business approval
- Appeal Meta suspension
- Use official WhatsApp Cloud API (no Baileys needed)

## Files to clean up
- Remove the from-source Evolution setup (it doesn't work on NixOS)
- evolution-bridge.nix needs to go back to container approach or be removed
- Remove /var/lib/evolution-api on server (failed source install)
