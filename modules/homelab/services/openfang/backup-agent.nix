# Smart backup agent — analyzes backup freshness, sizes, unprotected paths
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.services.openfang;
  waNotify = "/persist/openfang/scripts/wa-notify.sh";

  backupAnalyzePy = pkgs.writeText "backup-analyze.py" ''
#!/usr/bin/env python3
"""Smart backup analyzer — checks freshness, sizes, and coverage."""
import json
import os
import subprocess
import sys
from datetime import datetime, timedelta

BACKUP_DIR = "/mnt/data1/Backups"
PERSIST_DIR = "/persist"
VARLIB_DIR = "/var/lib"

# Paths that SHOULD be backed up (from backup-to-hdd service)
EXPECTED_BACKUPS = {
    "persist": {"src": "/persist", "dst": f"{BACKUP_DIR}/persist"},
    "authelia": {"src": "/var/lib/authelia-main", "dst": f"{BACKUP_DIR}/var-lib/authelia-main"},
    "jellyfin": {"src": "/var/lib/jellyfin", "dst": f"{BACKUP_DIR}/var-lib/jellyfin"},
    "sonarr": {"src": "/var/lib/sonarr", "dst": f"{BACKUP_DIR}/var-lib/sonarr"},
    "radarr": {"src": "/var/lib/radarr", "dst": f"{BACKUP_DIR}/var-lib/radarr"},
    "bazarr": {"src": "/var/lib/bazarr", "dst": f"{BACKUP_DIR}/var-lib/bazarr"},
    "prowlarr": {"src": "/var/lib/prowlarr", "dst": f"{BACKUP_DIR}/var-lib/prowlarr"},
    "deluge": {"src": "/var/lib/deluge", "dst": f"{BACKUP_DIR}/var-lib/deluge"},
    "uptime-kuma": {"src": "/var/lib/uptime-kuma", "dst": f"{BACKUP_DIR}/var-lib/uptime-kuma"},
    "homepage": {"src": "/var/lib/homepage-dashboard", "dst": f"{BACKUP_DIR}/var-lib/homepage-dashboard"},
    "grafana": {"src": "/var/lib/grafana", "dst": f"{BACKUP_DIR}/var-lib/grafana"},
    "prometheus": {"src": "/var/lib/prometheus2", "dst": f"{BACKUP_DIR}/var-lib/prometheus2"},
    "nextcloud": {"src": "/var/lib/nextcloud", "dst": f"{BACKUP_DIR}/var-lib/nextcloud"},
    "postgresql": {"src": "/var/lib/postgresql", "dst": f"{BACKUP_DIR}/var-lib/postgresql"},
    "immich": {"src": "/var/lib/immich", "dst": f"{BACKUP_DIR}/var-lib/immich"},
    "paperless": {"src": "/var/lib/paperless", "dst": f"{BACKUP_DIR}/var-lib/paperless"},
    "openfang": {"src": "/var/lib/openfang", "dst": f"{BACKUP_DIR}/var-lib/openfang"},
    "openfang-config": {"src": "/persist/openfang", "dst": f"{BACKUP_DIR}/persist/openfang"},
}

# Paths protected by snapraid parity (not rsync backed up, but still protected)
SNAPRAID_PROTECTED = {
    "immich-photos": "/mnt/data1/Media/Photos",
    "nextcloud-data": "/mnt/data1/Nextcloud",
    "documents": "/mnt/data1/Documents",
}


def run_cmd(cmd, timeout=30):
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=timeout)
        return r.stdout.strip()
    except:
        return ""


def get_dir_size(path):
    """Get directory size in bytes."""
    result = run_cmd(f"du -sb {path} 2>/dev/null | cut -f1")
    try:
        return int(result)
    except:
        return 0


def format_size(bytes_val):
    if bytes_val >= 1024**3:
        return f"{bytes_val / 1024**3:.1f} GB"
    elif bytes_val >= 1024**2:
        return f"{bytes_val / 1024**2:.0f} MB"
    elif bytes_val >= 1024:
        return f"{bytes_val / 1024:.0f} KB"
    return f"{bytes_val} B"


def get_last_backup_time():
    """Get when backup-to-hdd last ran successfully."""
    result = run_cmd("systemctl show backup-to-hdd --property=ExecMainStartTimestamp --value")
    if not result or result == "n/a":
        return None
    try:
        # systemd format: "Tue 2026-03-25 00:20:15 CET" — strip timezone suffix
        parts = result.rsplit(" ", 1)  # split off timezone
        dt = datetime.strptime(parts[0], "%a %Y-%m-%d %H:%M:%S")
        return dt
    except:
        try:
            # Fallback: try without day name
            dt = datetime.strptime(result[:19], "%Y-%m-%d %H:%M:%S")
            return dt
        except:
            return None


def get_newest_file(path):
    """Find the newest file modification time in a directory."""
    result = run_cmd(f"find {path} -type f -printf '%T@\\n' 2>/dev/null | sort -rn | head -1")
    try:
        return datetime.fromtimestamp(float(result))
    except:
        return None


def analyze():
    last_backup = get_last_backup_time()
    now = datetime.now()
    issues = []
    stats = []

    # 1. Check backup freshness
    if last_backup:
        age = now - last_backup
        if age > timedelta(days=2):
            issues.append(f"⚠️ Last backup was {age.days} days ago!")
        stats.append(f"Last backup: {last_backup.strftime('%Y-%m-%d %H:%M')}")
    else:
        issues.append("❌ No backup timestamp found!")

    # 2. Check each expected backup path
    missing = []
    stale = []
    sizes = []

    for name, paths in EXPECTED_BACKUPS.items():
        src = paths["src"]
        dst = paths["dst"]

        if not os.path.exists(src):
            continue  # Source doesn't exist, skip

        if not os.path.exists(dst):
            missing.append(name)
            continue

        # Check if source has newer files than backup
        src_newest = get_newest_file(src)
        dst_newest = get_newest_file(dst)
        if src_newest and dst_newest and src_newest > dst_newest + timedelta(hours=26):
            stale.append(f"{name} (source updated {src_newest.strftime('%m-%d %H:%M')}, backup from {dst_newest.strftime('%m-%d %H:%M')})")

        # Get sizes
        src_size = get_dir_size(src)
        dst_size = get_dir_size(dst)
        if src_size > 0:
            sizes.append((name, src_size, dst_size))

    if missing:
        issues.append(f"❌ Missing backups: {', '.join(missing)}")
    if stale:
        issues.append("⚠️ Stale backups:\n    " + "\n    ".join(stale))

    # 3. Check for unprotected /var/lib directories
    unprotected = []
    if os.path.exists(VARLIB_DIR):
        known_backed_up = {p["src"].split("/")[-1] for p in EXPECTED_BACKUPS.values() if p["src"].startswith("/var/lib/")}
        for entry in os.listdir(VARLIB_DIR):
            full_path = os.path.join(VARLIB_DIR, entry)
            if os.path.isdir(full_path) and entry not in known_backed_up:
                size = get_dir_size(full_path)
                if size > 10 * 1024 * 1024:  # Only flag dirs > 10MB
                    unprotected.append(f"{entry} ({format_size(size)})")

    if unprotected:
        issues.append("📁 Unprotected /var/lib dirs (>10MB):\n    " + "\n    ".join(unprotected[:10]))

    # 4. Size summary
    total_src = sum(s for _, s, _ in sizes)
    total_dst = sum(d for _, _, d in sizes)
    top_5 = sorted(sizes, key=lambda x: x[1], reverse=True)[:5]

    # Build report
    report = "*Smart Backup Report*\n"
    report += "\n".join(stats) + "\n"

    if issues:
        report += "\n*Issues:*\n" + "\n".join(issues) + "\n"
    else:
        report += "\n✅ All backups healthy\n"

    report += f"\n*Rsync backup:* {format_size(total_src)} source → {format_size(total_dst)} backed up\n"
    report += "*Largest:*\n"
    for name, src_s, dst_s in top_5:
        report += f"  {name}: {format_size(src_s)}\n"

    # Snapraid-protected data
    snap_lines = []
    snap_total = 0
    for name, path in SNAPRAID_PROTECTED.items():
        if os.path.exists(path):
            size = get_dir_size(path)
            if size > 0:
                snap_lines.append(f"  {name}: {format_size(size)}")
                snap_total += size
    if snap_lines:
        report += f"\n*Snapraid parity protected:* {format_size(snap_total)}\n"
        report += "\n".join(snap_lines) + "\n"

    return report


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "analyze"
    if cmd == "analyze":
        print(analyze())
    elif cmd == "freshness":
        last = get_last_backup_time()
        if last:
            age = datetime.now() - last
            print(f"Last backup: {last.strftime('%Y-%m-%d %H:%M')} ({age.days}d {age.seconds//3600}h ago)")
        else:
            print("No backup timestamp found")
    else:
        print("Commands: analyze, freshness")


if __name__ == "__main__":
    main()
  '';

  backupAnalyzeScript = pkgs.writeShellScript "backup-analyze-daily" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.python3}/bin:${pkgs.findutils}/bin:${pkgs.systemd}/bin:$PATH

    RESULT=$(python3 ${backupAnalyzePy} analyze)

    # Always send — it's a daily health report
    ${waNotify} "" "$RESULT"
  '';

  backupToolScript = pkgs.writeShellScript "backup-tool" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.python3}/bin:${pkgs.findutils}/bin:${pkgs.systemd}/bin:$PATH
    CMD="''${1:-analyze}"
    python3 ${backupAnalyzePy} "$CMD"
  '';
in
{
  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "L+ /persist/openfang/scripts/backup-tool.sh - - - - ${backupToolScript}"
    ];

    # Daily backup analysis — 8:30am (after backup and update-watcher)
    systemd.services.backup-analyze = {
      description = "Smart backup health analysis";
      after = [ "network-online.target" "openfang-whatsapp-gateway.service" ];
      wants = [ "network-online.target" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = backupAnalyzeScript;
      };
    };
    systemd.timers.backup-analyze = {
      description = "Daily smart backup analysis";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 08:30:00";
        Persistent = true;
      };
    };
  };
}
