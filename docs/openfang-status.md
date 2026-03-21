# OpenFang Current Status

## What works
- OpenFang binary installed and running on port 50051
- Anthropic Claude Sonnet 4 configured and responding
- Agent processes messages via API (status 200, tool calling works)
- WhatsApp Web gateway connects and receives incoming messages

## What doesn't work
- **WhatsApp message SENDING is broken** — Baileys library connects and receives messages but `sock.sendMessage()` times out. The gateway logs "Timed Out" on every send attempt. This is a Baileys/WhatsApp protocol issue, not our config.

## Root cause analysis
Baileys is an unofficial reverse-engineered WhatsApp Web library. It's fragile and breaks when WhatsApp updates their protocol. The "connected" state doesn't guarantee send capability.

## Alternative approaches (pick one for next session)

### Option 1: WhatsApp Cloud API (recommended)
- Use Meta's official WhatsApp Business API instead of Baileys
- Requires: Meta Business account + WhatsApp Business number
- Pros: reliable, official, won't break
- Cons: need a separate phone number, Meta approval process
- OpenFang supports this natively via `WHATSAPP_ACCESS_TOKEN`

### Option 2: Switch to Telegram
- Much simpler: just create a bot via @BotFather, get token
- No QR codes, no Baileys, no session issues
- OpenFang has native Telegram support
- Cons: not WhatsApp

### Option 3: Use a different WhatsApp bridge
- whatsapp-web.js (alternative to Baileys, more maintained)
- Would require modifying/replacing the gateway
- Same unofficial approach, might have same issues

### Option 4: Use ntfy/Gotify for notifications only
- Skip the chatbot, just push notifications
- Works perfectly for alerts (service down, download complete, etc.)
- No two-way chat, but covers the monitoring use case

## Key details
- Agent UUID: 60d2d829-51e0-4ee4-ac90-304e7b50257c (changes on reinit)
- OpenFang API: http://localhost:50051
- WhatsApp gateway: http://localhost:3009
- Config: /persist/openfang/.openfang/config.toml
- Embedding errors: needs Ollama or disable embeddings
