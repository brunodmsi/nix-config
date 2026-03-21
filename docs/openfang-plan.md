# OpenFang AI Agent Setup Plan

## Overview

Personal AI assistant + chatbot running on sweet, accessible via WhatsApp/Telegram.
Integrates with homelab services for monitoring, notifications, and control.

## Phase 1: Core Setup

### Install OpenFang
- Add as NixOS systemd service
- Store config at `/persist/openfang/config.toml`
- Store data at `/var/lib/openfang/`
- Expose via Cloudflare tunnel at `agent.demasi.dev` (if web UI needed)
- LLM API key via agenix secret

### Messaging Integration
- WhatsApp (primary) or Telegram
- Configure channel adapter in OpenFang
- Test basic message send/receive

## Phase 2: Push Notifications (automated alerts)

### Uptime Monitoring (via Uptime Kuma webhooks)
- **Type:** Push (webhook)
- **How:** Uptime Kuma → webhook to OpenFang endpoint → message to WhatsApp/Telegram
- **Triggers:** Service goes down, service recovers
- **Priority:** HIGH — immediately useful, all services already monitored

### Media Requests (via Jellyseerr webhooks)
- **Type:** Push (webhook)
- **How:** Jellyseerr → webhook to OpenFang → message to requester
- **Triggers:** Request approved, movie/show available in Jellyfin
- **Use case:** Fiancée requests movie → gets notified when ready
- **Priority:** HIGH

### Download Complete (via Deluge Execute plugin)
- **Type:** Push (script trigger)
- **How:** Deluge Execute plugin → script hits OpenFang API → message
- **Triggers:** Torrent download completed
- **Priority:** MEDIUM

### VPN Status (via cron polling)
- **Type:** Push (cron poll)
- **How:** Cron job every 1 min → `mullvad status` (or check wg interface) → compare to last state → alert on change
- **Script location:** `/persist/openfang/scripts/vpn-check.sh`
- **Note:** Must handle gracefully if VPN drops (retry before alerting)
- **Since we use WireGuard namespace, check:** `sudo ip netns exec wg_client curl -s ifconfig.me` or `wg show`
- **Priority:** MEDIUM

### HDD Health (via daily cron)
- **Type:** Push (daily cron)
- **How:** Daily `smartctl -a` on each drive → parse SMART attributes → alert if concerning
- **Watch for:**
  - Reallocated sectors (ID 5)
  - Pending sectors (ID 197)
  - Uncorrectable errors (ID 198)
  - Temperature above threshold (e.g. 50°C)
  - Overall health PASSED → FAILED
- **Drives:**
  - `/dev/disk/by-id/ata-WDC_WD120EFGX-68CPHN0_WD-B00XRDHD` (Data1)
  - `/dev/disk/by-id/ata-WDC_WD120EFGX-68CPHN0_WD-B00XSP6D` (Parity1)
  - `/dev/disk/by-id/nvme-KINGSTON_SNV3S500G_50026B76878184EA` (Boot NVMe)
- **Priority:** HIGH — early warning prevents data loss

### Server Metrics (via Prometheus API)
- **Type:** Push (threshold alerts) + Pull (on demand)
- **How:** Query Prometheus HTTP API (`http://localhost:9090/api/v1/query`)
- **Auto alerts:**
  - CPU > 90% for 5+ minutes
  - RAM > 90%
  - Disk usage > 85% on any mount
  - Any systemd service in failed state
- **On demand:** Ask "server status" → returns CPU, RAM, disk, load, temps
- **Priority:** MEDIUM

## Phase 3: Pull Commands (on-demand queries)

### Commands the bot should respond to:
| Command | What it does | Backend API |
|---|---|---|
| `status` | Server overview (CPU, RAM, disk, temps) | Prometheus API |
| `services` | List all services and their status | `systemctl` or Uptime Kuma API |
| `downloads` | Active downloads + progress | Deluge JSON-RPC + Sonarr/Radarr API |
| `vpn` | VPN status + current IP | `wg show` in namespace |
| `storage` | Disk usage per mount | Prometheus or `df -h` |
| `request <movie>` | Search and request a movie | Jellyseerr API |
| `search <query>` | Search across all media | Jellyfin API |
| `health` | HDD SMART status summary | `smartctl` |
| `backup` | Last backup status + time | Check backup timer |
| `logs <service>` | Recent logs for a service | `journalctl` |

## Implementation Notes

### Secrets needed (agenix):
- LLM API key (OpenAI/Anthropic/etc.)
- WhatsApp/Telegram bot token
- Any webhook secrets

### NixOS integration:
- systemd service for OpenFang
- systemd timers for cron jobs (VPN check, HDD health, metric alerts)
- Scripts in `/persist/openfang/scripts/`
- Backup OpenFang data in daily rsync

### Webhook endpoint:
- OpenFang exposes HTTP endpoint for incoming webhooks
- Route through Caddy on port 80 (behind Authelia? or open for service webhooks)
- Uptime Kuma and Jellyseerr point webhooks at this endpoint

### Architecture:
```
WhatsApp/Telegram ←→ OpenFang (localhost:PORT) ←→ Homelab APIs
                                                    ├── Prometheus (localhost:9090)
                                                    ├── Uptime Kuma (localhost:3001)
                                                    ├── Jellyseerr (localhost:5055)
                                                    ├── Deluge JSON-RPC (localhost:58846)
                                                    ├── Sonarr (localhost:8989)
                                                    ├── Radarr (localhost:7878)
                                                    ├── Jellyfin (localhost:8096)
                                                    └── System commands (smartctl, wg, systemctl)
```
