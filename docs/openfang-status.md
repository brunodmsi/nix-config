# OpenFang Current Status

## What works
- OpenFang binary installed and running on port 50051
- WhatsApp Web gateway connected (QR scanned, receiving messages)
- Anthropic Claude Sonnet 4 configured as LLM
- API responds to direct curl requests (status 200)
- Agent has 60 tools available

## What doesn't work yet
- **WhatsApp replies not sent back** — agent processes message but doesn't reply to WhatsApp
- **Embedding errors** — OpenFang tries Ollama (localhost:11434) for embeddings, not running
- **Agent crashes/recovers loop** — heartbeat marks agent as unresponsive every ~3 minutes

## Next steps
1. Install Ollama for embeddings (or disable embeddings in config)
2. Debug why WhatsApp gateway doesn't forward agent responses back
3. Add system prompt for conversational behavior
4. Set up agent skills for homelab monitoring (Phase 2 of openfang-plan.md)

## Key details
- Agent UUID: 60d2d829-51e0-4ee4-ac90-304e7b50257c (changes on reinit)
- OpenFang API: http://localhost:50051
- WhatsApp gateway: http://localhost:3009
- Config: /persist/openfang/.openfang/config.toml
- Data: /var/lib/openfang/
