# Reusable WhatsApp notification service — used by onSuccess/onFailure hooks
# and directly from scripts: /persist/openfang/scripts/wa-notify.sh "" "custom message"
{
  config,
  lib,
  pkgs,
  ...
}:
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
in
{
  config = lib.mkIf cfg.enable {
    # Template unit: systemd.services.<name>.onSuccess = [ "wa-notify@<name>.service" ];
    systemd.services."wa-notify@" = {
      description = "WhatsApp notification for %i";
      after = [ "openfang-whatsapp-gateway.service" "postgresql.service" ];
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${waNotifyScript} %i";
      };
    };

    # Also available as a script for custom messages from timers/scripts
    systemd.tmpfiles.rules = [
      "L+ /persist/openfang/scripts/wa-notify.sh - - - - ${waNotifyScript}"
    ];
  };
}
