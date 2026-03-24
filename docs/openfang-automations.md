# OpenFang Homelab Automations Plan

## Context

OpenFang (Fluzy) is running on sweet with WhatsApp gateway and Jellyseerr integration. We want to expand with homelab automations using OpenFang's native skill and hand systems instead of ad-hoc shell scripts.

All WhatsApp messages go through the gateway: `POST http://127.0.0.1:3009/message/send` with `{"to": "JID", "text": "msg"}`.

### Current State
- OpenFang v0.5.1 at `/persist/openfang/.openfang/`
- Both `openfang skill` and `openfang hand` CLIs confirmed working
- No skills installed yet
- Agent manifest at `/etc/openfang/agent-manifest.toml` (generated from Nix)
- All services run as root
- PATH includes: bash, coreutils, grep, sed, findutils, curl, jq, postgresql
- Python3 available via `pkgs.python3` (used by patch-gateway.py)
- Existing tool: `jellyseerr-tool.sh` in `/persist/openfang/scripts/` (shell_exec based)

### Existing scheduled services (DO NOT duplicate)
- `snapraid-sync` + `snapraid-scrub` — NixOS `services.snapraid` manages scheduling
- `services.zfs.autoScrub.enable = true` — NixOS manages ZFS scrub scheduling
- `backup-to-hdd` — daily timer, rsync to `/mnt/data1/Backups/`

These already run on schedule. We only need to **add WhatsApp notifications** when they complete or fail.

### Target Architecture
- **Custom Skills** (Python, `skill.toml` + `src/main.py`) for on-demand tools
- **Hands** (`HAND.toml` + system prompt) for proactive scheduled tasks that need LLM reasoning
- **Notification hooks** on existing systemd services for success/failure alerts
- **New timers** only for things NixOS doesn't already schedule (storage snapshots, backup verify, daily reports)
- **Bundled prompt_only skills** (sysadmin, prometheus, etc.) for domain knowledge
- Agent manifest `skills = [...]` field to activate per-agent

---

## Phase 0: Foundation & Verification

**Goal:** Set up skill infrastructure, validate with a test skill.

### Step 0.1: Add python3 to OpenFang service PATH

**File:** `modules/homelab/services/openfang/default.nix` line 215

```nix
# Change:
path = with pkgs; [ bash coreutils gnugrep gnused findutils curl jq postgresql ];
# To:
path = with pkgs; [ bash coreutils gnugrep gnused findutils curl jq postgresql python3 ];
```

### Step 0.2: Create wa-notify template service

A reusable systemd template unit that sends WhatsApp notifications via the gateway. Used by `onSuccess`/`onFailure` hooks on existing services.

**New file:** `modules/homelab/services/openfang/wa-notify.nix`

```nix
{ config, pkgs, ... }:
let
  cfg = config.homelab.services.openfang;
  gatewayUrl = "http://127.0.0.1:${toString cfg.whatsappGatewayPort}";
  dbUrl = "postgresql://openfang@127.0.0.1:5432/openfang";

  waNotifyScript = pkgs.writeShellScript "wa-notify" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:${pkgs.systemd}/bin:$PATH

    SERVICE_NAME="$1"
    CUSTOM_MSG="$2"

    # Get Bruno's remote_jid from DB (falls back to phone number)
    REMOTE_JID=$(psql -t -A -c "SELECT remote_jid FROM channel_users WHERE channel_user_id = '+559184519877' LIMIT 1;" "${dbUrl}" 2>/dev/null)
    TO="''${REMOTE_JID:-+559184519877}"

    if [ -n "$CUSTOM_MSG" ]; then
      MSG="$CUSTOM_MSG"
    else
      # Check service result
      STATUS=$(systemctl show "$SERVICE_NAME" --property=Result --value 2>/dev/null || echo "unknown")
      if [ "$STATUS" = "success" ]; then
        MSG="✅ *$SERVICE_NAME* completed successfully"
      else
        MSG="❌ *$SERVICE_NAME* failed ($STATUS)"
      fi
    fi

    curl -s -X POST "${gatewayUrl}/message/send" \
      -H "Content-Type: application/json" \
      -d "{\"to\": \"$TO\", \"text\": $(echo "$MSG" | jq -Rs .)}"
  '';
in {
  config = lib.mkIf cfg.enable {
    # Template unit: wa-notify@<service-name>.service
    systemd.services."wa-notify@" = {
      description = "WhatsApp notification for %i";
      after = [ "openfang-whatsapp-gateway.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${waNotifyScript} %i";
      };
    };

    # Make script available for custom messages too
    systemd.tmpfiles.rules = [
      "L+ /persist/openfang/scripts/wa-notify.sh - - - - ${waNotifyScript}"
    ];
  };
}
```

**Usage in other services:**
```nix
systemd.services.snapraid-sync.onSuccess = [ "wa-notify@snapraid-sync.service" ];
systemd.services.snapraid-sync.onFailure = [ "wa-notify@snapraid-sync.service" ];
```

**For custom messages** (from scripts):
```bash
/persist/openfang/scripts/wa-notify.sh "" "⚠️ *Storage Alert*: disk will be full in 30 days"
```

### Step 0.3: Test ping skill

Create a trivial skill to validate the full pipeline (Nix → deploy → install → agent uses it).

```toml
[skill]
name = "ping-test"
version = "0.1.0"
description = "Test skill — returns pong"

[runtime]
type = "python"
entry = "src/main.py"

[[tools.provided]]
name = "ping"
description = "Returns pong — used to test skill system"
input_schema = { type = "object", properties = {} }
```

```python
import json, sys
req = json.loads(sys.stdin.readline())
print(json.dumps({"result": "pong"}))
```

**Server test:**
```bash
cd /etc/nixos && sudo git pull && sudo nixos-rebuild switch --flake /etc/nixos#sweet

# Verify skill is installed
sudo /persist/openfang/.openfang/bin/openfang skill list

# Test Python directly
echo '{"tool":"ping","input":{}}' | python3 /persist/openfang/.openfang/skills/ping-test/src/main.py

# Test wa-notify
sudo /persist/openfang/scripts/wa-notify.sh "" "Test notification from wa-notify"

# Test via WhatsApp — send "test the ping tool" to Fluzy
```

**If ping skill works:** proceed to Phase 1.
**If it fails:** check OpenFang logs (`journalctl -u openfang`), debug protocol.

---

## Phase 1: homelab-server Skill

**Goal:** Give Fluzy server monitoring/management via WhatsApp — logs, services, storage, zpool, snapraid, auth, tunnel, backup.

### Files to create/modify

| Action | File |
|--------|------|
| Create | `modules/homelab/services/openfang/skills.nix` |
| Create | `modules/homelab/services/openfang/wa-notify.nix` (from Phase 0) |
| Modify | `modules/homelab/services/openfang/default.nix` (imports, python3 in PATH) |
| Modify | `modules/machines/nixos/sweet/homelab/default.nix` (system prompt) |

### skill.toml

```toml
[skill]
name = "homelab-server"
version = "0.1.0"
description = "NixOS homelab server monitoring — logs, storage, zpool, snapraid, services, auth, backup, tunnel"
author = "bmasi"
tags = ["homelab", "monitoring", "nixos"]

[runtime]
type = "python"
entry = "src/main.py"

[[tools.provided]]
name = "server_errors"
description = "Recent error/warning journal entries. Use when user asks about errors, issues, or problems."
input_schema = { type = "object", properties = { timeframe = { type = "string", description = "1h, 6h, or 24h (default: 1h)" } } }

[[tools.provided]]
name = "server_service_logs"
description = "Last N lines of a specific systemd service log. Use when user asks about a specific service."
input_schema = { type = "object", properties = { service = { type = "string", description = "Service name, e.g. jellyfin, sonarr, deluge" }, lines = { type = "integer", description = "Number of lines (default: 30)" } }, required = ["service"] }

[[tools.provided]]
name = "server_failed_units"
description = "List failed systemd units. Use when user asks what's broken or failing."
input_schema = { type = "object", properties = {} }

[[tools.provided]]
name = "server_storage"
description = "Disk usage per mount point with growth forecast. Use when user asks about disk space."
input_schema = { type = "object", properties = {} }

[[tools.provided]]
name = "server_zpool_status"
description = "ZFS pool health for bpool and rpool. Use when user asks about ZFS or pool health."
input_schema = { type = "object", properties = {} }

[[tools.provided]]
name = "server_snapraid_status"
description = "Snapraid parity health and last sync time. Use when user asks about snapraid or data protection."
input_schema = { type = "object", properties = {} }

[[tools.provided]]
name = "server_snapraid_diff"
description = "Files changed since last snapraid sync. Shows what would be synced."
input_schema = { type = "object", properties = {} }

[[tools.provided]]
name = "server_auth_events"
description = "Authelia authentication events — logins, failures, suspicious activity."
input_schema = { type = "object", properties = { timeframe = { type = "string", description = "1h, 6h, or 24h (default: 1h)" } } }

[[tools.provided]]
name = "server_backup_status"
description = "Last backup run time and result. Daily rsync to HDD."
input_schema = { type = "object", properties = {} }

[[tools.provided]]
name = "server_tunnel_status"
description = "Cloudflare tunnel health and status."
input_schema = { type = "object", properties = {} }

[requirements]
capabilities = ["ShellExec(*)"]
```

**Note:** No `server_snapraid_sync` tool. Sync is managed by NixOS (`services.snapraid`). The skill only reads status — it never triggers sync/scrub. If the user asks to run a sync, the agent should say "snapraid sync runs automatically on schedule, here's when the last one ran."

### src/main.py

```python
#!/usr/bin/env python3
"""homelab-server skill — server monitoring tools for OpenFang."""
import json
import os
import re
import sys
import subprocess

os.environ["PATH"] = "/run/current-system/sw/bin:" + os.environ.get("PATH", "")

STORAGE_HISTORY = "/persist/openfang/storage-history.csv"


def run_cmd(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        out = r.stdout.strip()
        err = r.stderr.strip()
        return out if out else err if err else "No output"
    except subprocess.TimeoutExpired:
        return "Command timed out"
    except Exception as e:
        return f"Error: {e}"


def server_errors(inp):
    tf = inp.get("timeframe", "1h")
    since = {"1h": "1 hour ago", "6h": "6 hours ago", "24h": "24 hours ago"}.get(tf, "1 hour ago")
    return run_cmd(f'journalctl -p err --since "{since}" --no-pager -n 50')


def server_service_logs(inp):
    svc = inp.get("service", "")
    if not svc:
        return "Error: service name required"
    if not re.match(r'^[a-zA-Z0-9._@-]+$', svc):
        return "Error: invalid service name"
    lines = min(int(inp.get("lines", 30)), 100)
    return run_cmd(f'journalctl -u {svc} -n {lines} --no-pager')


def server_failed_units(inp):
    return run_cmd('systemctl --failed --no-pager')


def server_storage(inp):
    df_out = run_cmd('df -h /mnt/data1 /mnt/parity1 / /boot 2>/dev/null')
    try:
        with open(STORAGE_HISTORY) as f:
            lines = f.readlines()[-7:]
        forecast = "\nLast 7 days:\n" + "".join(lines)
    except FileNotFoundError:
        forecast = "\nNo storage history yet."
    return df_out + forecast


def server_zpool_status(inp):
    return run_cmd('zpool status')


def server_snapraid_status(inp):
    status = run_cmd('snapraid status', timeout=60)
    # Also show when last sync ran
    last_sync = run_cmd('systemctl show snapraid-sync --property=ExecMainStartTimestamp --value')
    last_result = run_cmd('systemctl show snapraid-sync --property=Result --value')
    return f"Last sync: {last_sync} (result: {last_result})\n\n{status}"


def server_snapraid_diff(inp):
    return run_cmd('snapraid diff', timeout=120)


def server_auth_events(inp):
    tf = inp.get("timeframe", "1h")
    since = {"1h": "1 hour ago", "6h": "6 hours ago", "24h": "24 hours ago"}.get(tf, "1 hour ago")
    return run_cmd(f'journalctl -u authelia-main --since "{since}" --no-pager -n 50')


def server_backup_status(inp):
    status = run_cmd('systemctl status backup-to-hdd --no-pager -l')
    last_run = run_cmd('systemctl show backup-to-hdd --property=ExecMainStartTimestamp --value')
    last_result = run_cmd('systemctl show backup-to-hdd --property=Result --value')
    return f"Last run: {last_run} (result: {last_result})\n\n{status}"


def server_tunnel_status(inp):
    return run_cmd('systemctl status cloudflared-tunnel --no-pager -l')


TOOLS = {
    "server_errors": server_errors,
    "server_service_logs": server_service_logs,
    "server_failed_units": server_failed_units,
    "server_storage": server_storage,
    "server_zpool_status": server_zpool_status,
    "server_snapraid_status": server_snapraid_status,
    "server_snapraid_diff": server_snapraid_diff,
    "server_auth_events": server_auth_events,
    "server_backup_status": server_backup_status,
    "server_tunnel_status": server_tunnel_status,
}


def main():
    req = json.loads(sys.stdin.readline())
    tool = req.get("tool", "")
    inp = req.get("input", {})

    handler = TOOLS.get(tool)
    if not handler:
        print(json.dumps({"error": f"Unknown tool: {tool}"}))
        return

    try:
        result = handler(inp)
        print(json.dumps({"result": result}))
    except Exception as e:
        print(json.dumps({"error": str(e)}))


if __name__ == "__main__":
    main()
```

### System prompt update

In `sweet/homelab/default.nix`, add to the system prompt:

```
## Server Monitoring (homelab-server skill)
You have server management tools. Use them when asked about:
- Errors, logs, service issues → server_errors, server_service_logs, server_failed_units
- Disk space, storage → server_storage
- ZFS health → server_zpool_status
- Snapraid / data protection → server_snapraid_status, server_snapraid_diff
- Login activity → server_auth_events
- Backup status → server_backup_status
- Tunnel / external access → server_tunnel_status

NOTE: snapraid sync and zpool scrub run automatically on schedule. Do NOT trigger them manually.
If the user asks to run a sync, tell them it runs on schedule and show the last run status instead.
```

### Testing

```bash
# Unit test Python
echo '{"tool":"server_failed_units","input":{}}' | python3 /persist/openfang/.openfang/skills/homelab-server/src/main.py
echo '{"tool":"server_snapraid_status","input":{}}' | python3 /persist/openfang/.openfang/skills/homelab-server/src/main.py

# Via WhatsApp:
# "any errors in the last hour?"
# "what services are failing?"
# "how's disk space?"
# "check zpool health"
# "show me sonarr logs"
# "when was the last snapraid sync?"
```

### Risks & mitigations

| Risk | Mitigation |
|------|-----------|
| Skill tool protocol mismatch | Phase 0 ping test validates first |
| Python not found by OpenFang | Added to PATH + script prepends /run/current-system/sw/bin |
| Command injection via service name | Regex whitelist: `^[a-zA-Z0-9._@-]+$` |
| Large journalctl output overwhelms Haiku | Capped at 50-100 lines |
| snapraid status/diff takes long | Timeout set to 60s/120s, returns partial output on timeout |

---

## Phase 2: Proactive Notifications

**Goal:** Get WhatsApp alerts when existing services succeed/fail, plus new daily reports.

### Part A: Hook into existing services (wa-notify)

Add `onSuccess`/`onFailure` to existing NixOS services. These use the `wa-notify@` template from Phase 0.

**File:** `modules/machines/nixos/_common/filesystems/snapraid.nix`

```nix
# Replace tg-notify with wa-notify:
systemd.services.snapraid-sync.onSuccess = [ "wa-notify@snapraid-sync.service" ];
systemd.services.snapraid-sync.onFailure = [ "wa-notify@snapraid-sync.service" ];
systemd.services.snapraid-scrub.onSuccess = [ "wa-notify@snapraid-scrub.service" ];
systemd.services.snapraid-scrub.onFailure = [ "wa-notify@snapraid-scrub.service" ];
```

**File:** `modules/machines/nixos/sweet/homelab/default.nix`

```nix
# Add to backup-to-hdd service:
systemd.services.backup-to-hdd.onSuccess = [ "wa-notify@backup-to-hdd.service" ];
systemd.services.backup-to-hdd.onFailure = [ "wa-notify@backup-to-hdd.service" ];
```

**Result:** You get a WhatsApp message every time snapraid sync, scrub, or backup completes (or fails). Zero new scheduling — hooks into what already runs.

### Part B: New timers (only for things that don't exist yet)

**File:** `modules/homelab/services/openfang/monitoring.nix`

#### Timer 1: snapraid-daily-report

Daily status check (READ-ONLY — does NOT run sync). Reports what changed since last sync.

**Schedule:** Daily 7am

```bash
#!/usr/bin/env bash
DIFF=$(snapraid diff 2>&1 | tail -20)
ADDED=$(echo "$DIFF" | grep -oP '\d+ added' || echo "0 added")
REMOVED=$(echo "$DIFF" | grep -oP '\d+ removed' || echo "0 removed")
UPDATED=$(echo "$DIFF" | grep -oP '\d+ updated' || echo "0 updated")

LAST_SYNC=$(systemctl show snapraid-sync --property=ExecMainStartTimestamp --value)

MSG="*Snapraid Daily Report*
$ADDED, $REMOVED, $UPDATED since last sync
Last sync: $LAST_SYNC"

/persist/openfang/scripts/wa-notify.sh "" "$MSG"
```

#### Timer 2: storage-snapshot

Records disk usage to CSV. Only alerts if growth rate means drives fill within 90 days.

**Schedule:** Daily midnight

```bash
#!/usr/bin/env bash
DATE=$(date +%Y-%m-%d)
DATA1_USED=$(df --output=used /mnt/data1 | tail -1 | tr -d ' ')
DATA1_AVAIL=$(df --output=avail /mnt/data1 | tail -1 | tr -d ' ')
PARITY1_USED=$(df --output=used /mnt/parity1 | tail -1 | tr -d ' ')

echo "$DATE,$DATA1_USED,$DATA1_AVAIL,$PARITY1_USED" >> /persist/openfang/storage-history.csv

# Forecast if enough data
LINES=$(wc -l < /persist/openfang/storage-history.csv)
if [ "$LINES" -gt 30 ]; then
  FIRST_USED=$(head -n -29 /persist/openfang/storage-history.csv | tail -1 | cut -d, -f2)
  GROWTH=$((DATA1_USED - FIRST_USED))
  if [ "$GROWTH" -gt 0 ]; then
    DAYS_LEFT=$(( DATA1_AVAIL * 30 / GROWTH ))
    if [ "$DAYS_LEFT" -lt 90 ]; then
      /persist/openfang/scripts/wa-notify.sh "" "⚠️ *Storage Alert*: /mnt/data1 will be full in ~${DAYS_LEFT} days at current growth rate"
    fi
  fi
fi
```

#### Timer 3: backup-verify-weekly

Picks a random file from backup, compares checksum to original.

**Schedule:** Weekly Wednesday 4am

```bash
#!/usr/bin/env bash
BACKUP_DIR="/mnt/data1/Backups"

RANDOM_FILE=$(find "$BACKUP_DIR/persist" -type f 2>/dev/null | shuf -n 1)
[ -z "$RANDOM_FILE" ] && exit 0

ORIGINAL=$(echo "$RANDOM_FILE" | sed "s|$BACKUP_DIR/||")
ORIGINAL="/$ORIGINAL"

if [ ! -f "$ORIGINAL" ]; then
  /persist/openfang/scripts/wa-notify.sh "" "⚠️ *Backup Verify*: Original missing for $ORIGINAL"
else
  BACKUP_MD5=$(md5sum "$RANDOM_FILE" | cut -d' ' -f1)
  ORIG_MD5=$(md5sum "$ORIGINAL" | cut -d' ' -f1)
  if [ "$BACKUP_MD5" = "$ORIG_MD5" ]; then
    /persist/openfang/scripts/wa-notify.sh "" "✅ *Backup Verify*: OK — $(basename "$ORIGINAL") matches backup"
  else
    /persist/openfang/scripts/wa-notify.sh "" "❌ *Backup Verify*: MISMATCH — $ORIGINAL differs from backup!"
  fi
fi
```

### What we're NOT creating timers for

| Service | Why no timer needed |
|---------|-------------------|
| snapraid sync | NixOS `services.snapraid` handles it → `wa-notify@` hook |
| snapraid scrub | NixOS `services.snapraid` handles it → `wa-notify@` hook |
| zpool scrub | NixOS `services.zfs.autoScrub` handles it → `wa-notify@` hook |
| backup-to-hdd | Already a daily timer → `wa-notify@` hook |

### Testing

```bash
# Test wa-notify template
sudo systemctl start wa-notify@backup-to-hdd

# Test new timers
sudo systemctl start snapraid-daily-report
sudo systemctl start storage-snapshot
sudo systemctl start backup-verify-weekly

# Check all timers
systemctl list-timers --all | grep -E "snapraid|storage|backup"
```

---

## Phase 3: homelab-media Skill

**Goal:** Jellyfin integration — watch suggestions, cleanup, streaming stats.

### Prerequisites
- Add `jellyfinApiKey` to agenix (already have key from Jellyfin UI)

### Secrets setup (server commands)
```bash
cd /tmp/nix-secrets && git pull
# Add to secrets.nix:  "jellyfinApiKey.age".publicKeys = all;
sudo EDITOR=nano nix run github:ryantm/agenix -- -e jellyfinApiKey.age -i /persist/ssh/ssh_host_ed25519_key
git add -A && git commit -m "Add jellyfinApiKey" && git push
```

```nix
# In sweet/configuration.nix:
age.secrets.jellyfinApiKey.file = "${inputs.secrets}/jellyfinApiKey.age";
```

### skill.toml tools

| Tool | Input | Description |
|------|-------|-------------|
| `media_unwatched` | `{type: "movies"\|"shows", limit: 10}` | List unwatched content |
| `media_suggest` | `{genre: "action", mood: "light"}` | Random suggestion, optional filters |
| `media_finished` | `{}` | Fully watched shows + size on disk |
| `media_cleanup` | `{item_id: "..."}` | Delete a media item (requires user confirmation) |
| `media_sessions` | `{}` | Active streaming sessions |
| `media_stats` | `{}` | Library counts |
| `media_transcode_activity` | `{}` | Active transcodes, codec, bitrate |

### Python implementation notes

- **API base:** `http://127.0.0.1:8096`
- **Auth:** `Authorization: MediaBrowser Token="API_KEY"`
- **API key:** Read from agenix-managed file path (env var set in NixOS module)
- **Key endpoints:**
  - `GET /Items?IncludeItemTypes=Movie&IsPlayed=false&Recursive=true` — unwatched
  - `GET /Items?IncludeItemTypes=Series&Filters=IsPlayed&Recursive=true` — finished
  - `GET /Sessions` — active streams
  - `DELETE /Items/{id}` — delete (system prompt: "ALWAYS confirm before deleting")
- **Cleanup safety:** System prompt says "ALWAYS confirm with the user before using media_cleanup"

### Testing
```bash
API_KEY=$(sudo cat /run/agenix/jellyfinApiKey)
curl -s "http://127.0.0.1:8096/Items?IncludeItemTypes=Movie&IsPlayed=false&Recursive=true&Limit=3" \
  -H "Authorization: MediaBrowser Token=\"$API_KEY\"" | jq '.Items[] | {Name, Id}'

# Via WhatsApp:
# "what should I watch tonight?"
# "any shows I've finished that I could delete?"
# "who's streaming right now?"
```

---

## Phase 4: homelab-paperless Skill

**Goal:** Search and browse Paperless-ngx documents via WhatsApp.

### Prerequisites
- Generate API key in Paperless UI first
- Add `paperlessApiKey` to agenix

### Skill tools

| Tool | Input | Description |
|------|-------|-------------|
| `paperless_search` | `{query: "electricity bill january"}` | Full-text search |
| `paperless_recent` | `{limit: 5}` | Last N documents |
| `paperless_tags` | `{}` | All tags with doc counts |
| `paperless_info` | `{id: 42}` | Document details |

### Python implementation notes

- **API base:** `http://127.0.0.1:8000/api/`
- **Auth:** `Authorization: Token API_KEY`
- **Straightforward REST JSON** — simplest skill to implement

### Testing
```bash
# Via WhatsApp:
# "find my electricity bill from january"
# "what documents did I scan recently?"
```

---

## Phase 5: homelab-nextcloud Skill

**Goal:** Calendar, tasks, notes via WhatsApp.

### Prerequisites
- Generate app password in Nextcloud UI: Settings > Security > App passwords
- Add `nextcloudAppPassword` to agenix

### Skill tools (phased)

**Phase 5a — Notes only (pure JSON, no extra deps):**

| Tool | Input | Description |
|------|-------|-------------|
| `nextcloud_notes` | `{search: "optional query"}` | List/search notes |
| `nextcloud_note_add` | `{title: "...", content: "..."}` | Create a note |
| `nextcloud_note_save` | `{text: "url or text"}` | Save as note (bookmark capture) |

**Phase 5b — Calendar + Tasks (needs python-caldav):**

| Tool | Input | Description |
|------|-------|-------------|
| `nextcloud_calendar` | `{range: "today\|tomorrow\|week"}` | Upcoming events |
| `nextcloud_tasks` | `{}` | List todos |
| `nextcloud_task_add` | `{text: "buy groceries"}` | Create a task |

### Complexity warning

CalDAV is XML/iCal, not JSON. Phase 5b needs `pkgs.python3Packages.caldav` or `icalendar` in the NixOS python environment. Start with 5a (Notes API is pure JSON REST).

### APIs
- Notes: `http://127.0.0.1:8009/index.php/apps/notes/api/v1/notes` (JSON)
- CalDAV: `http://127.0.0.1:8009/remote.php/dav/calendars/bmasi/personal/` (iCal)
- Auth: Basic `bmasi:APP_PASSWORD`

### Testing
```bash
APP_PW=$(sudo cat /run/agenix/nextcloudAppPassword)
curl -s -u "bmasi:$APP_PW" "http://127.0.0.1:8009/index.php/apps/notes/api/v1/notes" \
  -H "Accept: application/json" | jq '.[].title'

# Via WhatsApp:
# "save this link: https://example.com/cool-article"
# "what notes do I have?"
```

---

## Phase 6: Enable Bundled Skills + System Prompt Polish

**Goal:** Activate OpenFang's built-in prompt_only skills for domain expertise.

### Agent manifest update

```toml
skills = [
  "homelab-server", "homelab-media", "homelab-paperless", "homelab-nextcloud",
  "sysadmin", "linux-networking", "prometheus", "postgres-expert", "shell-scripting"
]
```

Bundled skills inject expert knowledge into the system prompt automatically — no code.

### System prompt simplification

With skills providing tool definitions, trim the system prompt to:
- Persona (Fluzy, WhatsApp formatting, Hungary flag)
- Metadata instructions (sender, sender_name)
- Jellyseerr shell_exec commands (until migrated to a skill)
- Brief skill category overview
- Safety rules (confirm before deleting, don't trigger syncs manually)

---

## Phase 7: Per-User Access Control & Hardening

**Goal:** Map WhatsApp numbers to specific service accounts. Different users get different capabilities and access scoped to their own data.

### Paperless access control
- Each user gets their own Paperless API key (or shared key with user filtering)
- Wrapper script reads sender phone from metadata, maps to Paperless user
- User A can only search/view their own documents, not User B's

### Nextcloud access control
- Each user gets their own Nextcloud app password
- Wrapper maps sender phone → Nextcloud user → correct credentials
- Notes, calendar, tasks are scoped to the correct Nextcloud account

### Implementation
- Extend `channel_users` table with `role` and `service_credentials` columns (or a separate `user_services` table)
- Message router already has per-sender routing — extend to pass user context to tools
- Wrapper scripts read sender from `$SENDER` env var (set by message router or passed as arg)
- DB lookup: `SELECT nextcloud_user, paperless_token FROM user_services WHERE phone = '$SENDER'`
- Admin role gets all tools; family role gets media + notes only; guest gets media only

### Agent manifest per role
- Admin manifest: all tools (server, media, paperless, nextcloud, jellyseerr)
- Family manifest: media-tool.sh + nextcloud-tool.sh (notes only)
- Guest manifest: media-tool.sh (unwatched, suggest, stats — no cleanup)

**When:** When adding more users beyond Bruno.

---

## Future / Deferred

### Expense tracking via receipts
**Blocked on:** OpenFang's `/api/agents/{id}/message` endpoint doesn't pass images to the LLM. Gateway can download images but can't forward them for vision. Would need to use the OpenAI-compatible `/v1/chat/completions` endpoint or a separate vision API call.
**Depends on:** homelab-paperless skill.

### Daily standup
"What did I do yesterday" — git commits, Paperless docs, calendar events.
**Depends on:** Paperless + Nextcloud skills.

### Migrate Jellyseerr to a skill
Convert `jellyseerr-tool.sh` from shell_exec to a proper Python skill with wrapper.
**When:** After skill system is proven.

---

## Secrets Summary

| Secret | Phase | Status | Action |
|--------|-------|--------|--------|
| `jellyfinApiKey` | 3 | Have key | Add to nix-secrets, declare in config |
| `paperlessApiKey` | 4 | Missing | Generate in Paperless UI first |
| `nextcloudAppPassword` | 5 | Missing | Generate in Nextcloud UI first |

---

## Implementation Order Summary

| Phase | What | Status | Effort |
|-------|------|--------|--------|
| 0 | Foundation: python3, wa-notify, ping test | Done | Small |
| 1 | homelab-server skill (10 tools) | Done | Medium |
| 2 | Notifications: hooks on existing services + 3 new timers | Done | Medium |
| 3 | homelab-media skill (5 tools) | Done | Medium |
| 4 | homelab-paperless skill (4 tools) | Done | Small |
| 5 | homelab-nextcloud skill (5 tools: notes, calendar, tasks) | Done | Medium-Large |
| 6 | Bundled skills + prompt polish | Pending | Small |
| 7 | Per-user access control: phone→account mapping for Paperless/Nextcloud | Pending | Medium |
