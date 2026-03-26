# Daily update watcher — checks flake inputs and service versions for updates
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.services.openfang;
  waNotify = "/persist/openfang/scripts/wa-notify.sh";
  stateDir = "/persist/openfang/update-watcher";
  flakeLockPath = "/etc/nixos/flake.lock";

  updateWatcherPy = pkgs.writeText "update-watcher.py" ''
#!/usr/bin/env python3
"""Update watcher — checks flake inputs for new commits via GitHub API."""
import json
import os
import sys
import urllib.request
import urllib.error
from datetime import datetime, timezone

STATE_DIR = "${stateDir}"
FLAKE_LOCK = "${flakeLockPath}"
LAST_CHECK_FILE = os.path.join(STATE_DIR, "last-check.json")


def github_api(path):
    url = f"https://api.github.com{path}"
    req = urllib.request.Request(url)
    req.add_header("Accept", "application/vnd.github.v3+json")
    req.add_header("User-Agent", "openfang-update-watcher")
    try:
        with urllib.request.urlopen(req, timeout=15) as resp:
            return json.loads(resp.read())
    except Exception as e:
        return {"error": str(e)}


def parse_github_url(url_str):
    """Extract owner/repo and branch from a flake input URL."""
    # github:owner/repo/branch or github:owner/repo
    if url_str.startswith("github:"):
        parts = url_str[7:].split("/")
        if len(parts) >= 2:
            owner = parts[0]
            repo = parts[1]
            branch = parts[2] if len(parts) > 2 else None
            return owner, repo, branch
    return None, None, None


def load_flake_lock():
    try:
        with open(FLAKE_LOCK) as f:
            return json.loads(f.read())
    except Exception as e:
        return {"error": str(e)}


def load_last_check():
    try:
        with open(LAST_CHECK_FILE) as f:
            return json.loads(f.read())
    except FileNotFoundError:
        return {}


def save_last_check(data):
    os.makedirs(STATE_DIR, exist_ok=True)
    with open(LAST_CHECK_FILE, "w") as f:
        json.dump(data, f, indent=2)


def check_input(name, node, last_check):
    """Check a single flake input for updates."""
    locked = node.get("locked", {})
    input_type = locked.get("type", "")
    current_rev = locked.get("rev", "")
    last_modified = locked.get("lastModified", 0)

    if input_type != "github":
        return None  # Skip non-GitHub inputs

    owner = locked.get("owner", "")
    repo = locked.get("repo", "")
    original = node.get("original", {})
    ref = locked.get("ref", original.get("ref", locked.get("branch", "main")))

    if not owner or not repo:
        return None

    # Check for new commits since our locked rev
    api_path = f"/repos/{owner}/{repo}/commits?sha={ref}&per_page=5"
    data = github_api(api_path)

    if isinstance(data, dict) and "error" in data:
        return f"  {name}: failed to check ({data['error']})"

    if not isinstance(data, list) or not data:
        return None

    latest_sha = data[0].get("sha", "")[:12]
    current_sha = current_rev[:12]

    if latest_sha == current_sha:
        return None  # Up to date

    # Count new commits
    new_commits = 0
    for commit in data:
        if commit.get("sha", "").startswith(current_rev[:12]):
            break
        new_commits += 1

    # Get latest commit message
    latest_msg = data[0].get("commit", {}).get("message", "").split("\n")[0][:80]
    latest_date = data[0].get("commit", {}).get("committer", {}).get("date", "")[:10]

    return f"  *{name}* ({owner}/{repo}): {new_commits}+ new commits\n    Latest: {latest_msg} ({latest_date})"


def check_all():
    lock = load_flake_lock()
    if "error" in lock:
        return f"Failed to read flake.lock: {lock['error']}"

    last_check = load_last_check()
    nodes = lock.get("nodes", {})
    root_node = nodes.get("root", {})
    inputs = root_node.get("inputs", {})

    updates = []
    checked = {}

    for input_name, node_name in inputs.items():
        if isinstance(node_name, list):
            continue  # follows reference
        node = nodes.get(node_name, {})
        result = check_input(input_name, node, last_check)
        if result:
            updates.append(result)
        locked = node.get("locked", {})
        checked[input_name] = {
            "rev": locked.get("rev", ""),
            "checked_at": datetime.now(timezone.utc).isoformat(),
        }

    save_last_check(checked)

    if not updates:
        return None  # No updates, stay silent

    header = f"*Nix Config Update Report* ({len(updates)} inputs have updates)\n"
    return header + "\n".join(updates)


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "check"
    if cmd == "check":
        result = check_all()
        if result:
            print(result)
        else:
            print("All flake inputs are up to date.")
    elif cmd == "status":
        last = load_last_check()
        if not last:
            print("No previous check recorded.")
        else:
            lines = ["Last check:"]
            for name, info in sorted(last.items()):
                rev = info.get("rev", "?")[:12]
                checked = info.get("checked_at", "?")[:10]
                lines.append(f"  {name}: {rev} (checked {checked})")
            print("\n".join(lines))
    else:
        print("Commands: check, status")


if __name__ == "__main__":
    main()
  '';

  updateWatcherScript = pkgs.writeShellScript "update-watcher-daily" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.python3}/bin:$PATH

    RESULT=$(python3 ${updateWatcherPy} check)

    # Only send WhatsApp if there are updates (not "All flake inputs are up to date")
    if echo "$RESULT" | grep -q "inputs have updates"; then
      ${waNotify} "" "$RESULT"
    fi
  '';

  updateToolScript = pkgs.writeShellScript "update-tool" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.python3}/bin:$PATH
    CMD="''${1:-check}"
    python3 ${updateWatcherPy} "$CMD"
  '';
in
{
  config = lib.mkIf cfg.enable {
    # State directory for tracking last check
    systemd.tmpfiles.rules = [
      "d ${stateDir} 0755 root root - -"
      "L+ /persist/openfang/scripts/update-tool.sh - - - - ${updateToolScript}"
    ];

    # Daily update check — 8am
    systemd.services.update-watcher = {
      description = "Check flake inputs for updates";
      after = [ "network-online.target" "openfang-whatsapp-gateway.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = updateWatcherScript;
      };
    };
    systemd.timers.update-watcher = {
      description = "Daily flake input update check";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 08:00:00";
        Persistent = true;
      };
    };
  };
}
