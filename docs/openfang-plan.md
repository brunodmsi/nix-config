# OpenFang AI Agent Setup Plan

## Phase 1: Core Setup ✅ COMPLETE

- OpenFang running on port 50051 with Claude Haiku 4.5
- WhatsApp connected via Evolution API v2.3.7 (container)
- Bridge with PostgreSQL dedup + allowed senders
- Web panel: agent.demasi.dev (behind Authelia)
- Instance name: sweet-zap

## Phase 2: Push Notifications (automated alerts)

### 2.1 Uptime Monitoring — HIGH PRIORITY
**Goal:** Get a WhatsApp message when any service goes down or recovers.

**How:**
- Uptime Kuma has native webhook support
- Configure webhook URL in Uptime Kuma pointing to the bridge
- Bridge receives the event and sends WhatsApp message directly (no LLM needed)
- Simple template: "🔴 {service} is DOWN" / "🟢 {service} is back UP"

**Implementation:**
1. Add a new webhook endpoint in the bridge (e.g. port 3011) for direct alerts (no LLM)
2. Or: use Uptime Kuma's built-in notification → custom webhook → Evolution API directly
3. Configure each monitor in Uptime Kuma with the webhook URL

**Simplest approach:** Skip OpenFang entirely for this. Uptime Kuma → curl to Evolution API sendText endpoint. One systemd service with a socat listener that receives Uptime Kuma webhooks and sends WhatsApp messages via Evolution.

### 2.2 Media Ready Notifications — HIGH PRIORITY
**Goal:** When a requested movie/show finishes downloading and is available in Jellyfin, notify the requester on WhatsApp.

**How:**
- Jellyseerr has native webhook support
- Configure webhook: Jellyseerr → bridge endpoint
- Events: request approved, media available
- Template: "🎬 {title} is now available on Jellyfin!"

**Implementation:**
1. Jellyseerr → Settings → Notifications → Webhook
2. URL: http://localhost:3011/jellyseerr (or direct to Evolution API)
3. Parse the webhook payload for title and requester

### 2.3 Download Complete — MEDIUM PRIORITY
**Goal:** Get notified when a torrent finishes downloading.

**How:**
- Deluge has an Execute plugin that runs a script on torrent completion
- Script sends message via Evolution API

**Implementation:**
1. Enable Execute plugin in Deluge
2. Create script at /persist/openfang/scripts/download-complete.sh:
   ```bash
   curl -X POST http://localhost:8080/message/sendText/sweet-zap \
     -H "apikey: openfang-evolution-bridge" \
     -H "Content-Type: application/json" \
     -d "{\"number\": \"559184519877\", \"text\": \"✅ Download complete: $1\"}"
   ```
3. Configure Deluge to run script on "Torrent Complete" event

### 2.4 VPN Status — MEDIUM PRIORITY
**Goal:** Get alerted if VPN drops (download traffic would be exposed).

**How:**
- systemd timer checks VPN status every 5 minutes
- If wg0 interface is down or IP changed, send WhatsApp alert

**Implementation:**
1. NixOS systemd timer + service
2. Script checks: `ip netns exec wg_client curl -s ifconfig.me`
3. Compare to known Mullvad IP range
4. If not Mullvad → alert + optionally stop Deluge
5. Store last known state in /var/lib/openfang/vpn-state

### 2.5 HDD Health — HIGH PRIORITY
**Goal:** Early warning before a drive fails.

**How:**
- Daily systemd timer runs smartctl on all drives
- Parse SMART attributes for warning signs
- Alert on: reallocated sectors, pending sectors, uncorrectable errors, temperature > 50°C

**Drives:**
- `/dev/disk/by-id/ata-WDC_WD120EFGX-68CPHN0_WD-B00XRDHD` (Data1)
- `/dev/disk/by-id/ata-WDC_WD120EFGX-68CPHN0_WD-B00XSP6D` (Parity1)
- `/dev/disk/by-id/nvme-KINGSTON_SNV3S500G_50026B76878184EA` (Boot NVMe)

**Implementation:**
1. NixOS systemd timer (daily at 3am)
2. Script runs smartctl, parses JSON output with jq
3. Sends WhatsApp alert via Evolution API if any attribute is concerning
4. Template: "⚠️ Drive {name}: {attribute} changed from {old} to {new}"

### 2.6 Server Metrics Alerts — MEDIUM PRIORITY
**Goal:** Get alerted when CPU/RAM/disk cross thresholds.

**How:**
- systemd timer every 5 minutes queries Prometheus API
- Check thresholds: CPU > 90% for 5min, RAM > 90%, disk > 85%
- Also check for failed systemd services

**Implementation:**
1. NixOS systemd timer
2. Script queries `http://localhost:9090/api/v1/query`
3. Prometheus queries:
   - CPU: `100 - (avg(rate(node_cpu_seconds_total{mode="idle"}[5m])) * 100)`
   - RAM: `(1 - node_memory_AvailableBytes / node_memory_MemTotalBytes) * 100`
   - Disk: `(1 - node_filesystem_avail_bytes / node_filesystem_size_bytes) * 100`
   - Failed services: `node_systemd_unit_state{state="failed"}`
4. Alert via Evolution API if threshold exceeded

## Phase 3: Pull Commands (on-demand via WhatsApp)

Commands the bot responds to when you message it:

| Command | What it does | Backend |
|---|---|---|
| `status` | Server overview (CPU, RAM, disk, temps) | Prometheus API |
| `services` | List all services and status | Uptime Kuma API |
| `downloads` | Active downloads + progress | Deluge JSON-RPC |
| `vpn` | VPN status + current IP | wg show in namespace |
| `storage` | Disk usage per mount | Prometheus / df -h |
| `request <movie>` | Search and request a movie | Jellyseerr API |
| `health` | HDD SMART summary | smartctl |
| `backup` | Last backup status | systemd timer status |

**Note:** These are handled by OpenFang's AI agent — it uses shell_exec and web_fetch tools to query the services and format a response. May need a system prompt to teach it these commands.

## Implementation Priority

1. **Uptime Kuma alerts** → immediate value, simple webhook
2. **HDD health check** → prevents data loss
3. **Media ready notifications** → great UX for movie requests
4. **VPN status monitor** → security
5. **Download complete** → nice to have
6. **Server metrics alerts** → nice to have (already visible in Grafana)
7. **Pull commands** → requires teaching the agent, lower priority

## Architecture (current)
```
WhatsApp ←→ Evolution API (port 8080) ←→ Bridge (port 3010) ←→ OpenFang (port 50051) ←→ Claude Haiku 4.5
                                          ↑
                                     Alert endpoints (port 3011)
                                          ↑
                              ┌────────────┼────────────┐
                              │            │            │
                        Uptime Kuma   Jellyseerr   systemd timers
                                                   (VPN, HDD, metrics)
```

## Secrets needed
- ✅ openfangApiKey — Anthropic API key
- ✅ whatsappAllowedSenders — approved phone numbers
- May need: webhook secrets for Uptime Kuma / Jellyseerr authentication
