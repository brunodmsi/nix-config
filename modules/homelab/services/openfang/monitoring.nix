# Proactive monitoring timers — snapraid daily report, storage snapshots, backup verification
{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab.services.openfang;
  waNotify = "/persist/openfang/scripts/wa-notify.sh";

  # Daily snapraid diff report (READ-ONLY — does NOT run sync)
  snapraidDailyScript = pkgs.writeShellScript "snapraid-daily-report" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.gnugrep}/bin:${pkgs.snapraid}/bin:${pkgs.systemd}/bin:$PATH

    DIFF=$(snapraid diff 2>&1 | tail -20)
    ADDED=$(echo "$DIFF" | grep -oP '\d+ added' || echo "0 added")
    REMOVED=$(echo "$DIFF" | grep -oP '\d+ removed' || echo "0 removed")
    UPDATED=$(echo "$DIFF" | grep -oP '\d+ updated' || echo "0 updated")

    LAST_SYNC=$(systemctl show snapraid-sync --property=ExecMainStartTimestamp --value 2>/dev/null || echo "unknown")

    MSG="*Snapraid Daily Report*
    $ADDED, $REMOVED, $UPDATED since last sync
    Last sync: $LAST_SYNC"

    ${waNotify} "" "$MSG"
  '';

  # Record disk usage to CSV for forecasting, alert if <90 days to full
  storageSnapshotScript = pkgs.writeShellScript "storage-snapshot" ''
    export PATH=${pkgs.coreutils}/bin:$PATH

    HISTORY="/persist/openfang/storage-history.csv"
    DATE=$(date +%Y-%m-%d)
    DATA1_USED=$(df --output=used /mnt/data1 | tail -1 | tr -d ' ')
    DATA1_AVAIL=$(df --output=avail /mnt/data1 | tail -1 | tr -d ' ')
    PARITY1_USED=$(df --output=used /mnt/parity1 | tail -1 | tr -d ' ')

    echo "$DATE,$DATA1_USED,$DATA1_AVAIL,$PARITY1_USED" >> "$HISTORY"

    # Forecast if enough data (>30 days)
    LINES=$(wc -l < "$HISTORY")
    if [ "$LINES" -gt 30 ]; then
      FIRST_USED=$(head -n -29 "$HISTORY" | tail -1 | cut -d, -f2)
      GROWTH=$((DATA1_USED - FIRST_USED))
      if [ "$GROWTH" -gt 0 ]; then
        DAYS_LEFT=$(( DATA1_AVAIL * 30 / GROWTH ))
        if [ "$DAYS_LEFT" -lt 90 ]; then
          ${waNotify} "" "⚠️ *Storage Alert*: /mnt/data1 will be full in ~''${DAYS_LEFT} days at current growth rate"
        fi
      fi
    fi
  '';

  # Pick a random file from backup, compare checksum to original
  backupVerifyScript = pkgs.writeShellScript "backup-verify-weekly" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.findutils}/bin:${pkgs.gnused}/bin:$PATH

    BACKUP_DIR="/mnt/data1/Backups"

    # Pick random file from persist backup
    RANDOM_FILE=$(find "$BACKUP_DIR/persist" -type f 2>/dev/null | shuf -n 1)
    [ -z "$RANDOM_FILE" ] && exit 0

    # Derive original path
    ORIGINAL=$(echo "$RANDOM_FILE" | sed "s|$BACKUP_DIR/||")
    ORIGINAL="/$ORIGINAL"

    if [ ! -f "$ORIGINAL" ]; then
      ${waNotify} "" "⚠️ *Backup Verify*: Original missing for $ORIGINAL"
    else
      BACKUP_MD5=$(md5sum "$RANDOM_FILE" | cut -d' ' -f1)
      ORIG_MD5=$(md5sum "$ORIGINAL" | cut -d' ' -f1)
      if [ "$BACKUP_MD5" = "$ORIG_MD5" ]; then
        ${waNotify} "" "✅ *Backup Verify*: OK — $(basename "$ORIGINAL") matches backup"
      else
        ${waNotify} "" "❌ *Backup Verify*: MISMATCH — $ORIGINAL differs from backup!"
      fi
    fi
  '';
in
{
  config = lib.mkIf cfg.enable {
    # Snapraid daily report — 7am
    systemd.services.snapraid-daily-report = {
      description = "Daily snapraid status report to WhatsApp";
      after = [ "openfang-whatsapp-gateway.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = snapraidDailyScript;
      };
    };
    systemd.timers.snapraid-daily-report = {
      description = "Daily snapraid status report";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 07:00:00";
        Persistent = true;
      };
    };

    # Storage snapshot — midnight
    systemd.services.storage-snapshot = {
      description = "Record disk usage for forecasting";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = storageSnapshotScript;
      };
    };
    systemd.timers.storage-snapshot = {
      description = "Daily disk usage snapshot";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "*-*-* 00:00:00";
        Persistent = true;
      };
    };

    # Backup verify — Wednesday 4am
    systemd.services.backup-verify-weekly = {
      description = "Verify backup integrity by comparing random file";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = backupVerifyScript;
      };
    };
    systemd.timers.backup-verify-weekly = {
      description = "Weekly backup integrity verification";
      wantedBy = [ "timers.target" ];
      timerConfig = {
        OnCalendar = "Wed *-*-* 04:00:00";
        Persistent = true;
      };
    };
  };
}
