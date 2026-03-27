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

  routerUrl = "http://127.0.0.1:50052";

  # fluzy-notify: send context to Fluzy's agent, let him interpret and relay to WhatsApp
  # Falls back to wa-notify if no agent exists yet
  fluzyNotifyScript = pkgs.writeShellScript "fluzy-notify" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:${pkgs.gnugrep}/bin:$PATH

    CONTEXT_MSG="$1"

    # Look up Bruno's agent_id and remote_jid
    AGENT_DATA=$(psql -t -A -c "SELECT agent_id || '|' || COALESCE(remote_jid, '''') FROM channel_users WHERE channel_user_id LIKE '%559184519877%' LIMIT 1;" "${dbUrl}" 2>/dev/null)
    AGENT_ID=$(echo "$AGENT_DATA" | cut -d'|' -f1)
    REMOTE_JID=$(echo "$AGENT_DATA" | cut -d'|' -f2)
    TO="''${REMOTE_JID:-+559184519877}"

    # Fallback to direct send if no agent spawned yet
    if [ -z "$AGENT_ID" ] || ! echo "$AGENT_ID" | grep -qE '^[a-f0-9-]{36}$'; then
      echo "[fluzy-notify] No agent found, falling back to direct send"
      curl -s -X POST "${gatewayUrl}/message/send" \
        -H "Content-Type: application/json" \
        -d "{\"to\": \"$TO\", \"text\": $(echo "$CONTEXT_MSG" | jq -Rs .)}"
      exit 0
    fi

    # Send context to Fluzy's agent via router (queued + logged)
    RESPONSE=$(curl -s --max-time 120 -X POST "${routerUrl}/api/agents/$AGENT_ID/message" \
      -H "Content-Type: application/json" \
      -d "{\"content\": $(echo "$CONTEXT_MSG" | jq -Rs .), \"metadata\": {\"sender\": \"+559184519877\", \"sender_name\": \"System\", \"remote_jid\": \"$REMOTE_JID\"}}")

    # Extract Fluzy's interpreted response
    MSG=$(echo "$RESPONSE" | jq -r '.response // .content // .message // .' 2>/dev/null)

    # Fallback if agent didn't respond properly
    if [ -z "$MSG" ] || [ "$MSG" = "null" ] || [ "$MSG" = "" ]; then
      echo "[fluzy-notify] No response from agent, falling back to direct send"
      curl -s -X POST "${gatewayUrl}/message/send" \
        -H "Content-Type: application/json" \
        -d "{\"to\": \"$TO\", \"text\": $(echo "$CONTEXT_MSG" | jq -Rs .)}"
      exit 0
    fi

    # Send Fluzy's interpreted message to WhatsApp
    curl -s -X POST "${gatewayUrl}/message/send" \
      -H "Content-Type: application/json" \
      -d "{\"to\": \"$TO\", \"text\": $(echo "$MSG" | jq -Rs .)}"
  '';

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
    # Scripts dir is 0755 so other services (coding-agents as bmasi) can call wa-notify
    systemd.tmpfiles.rules = [
      "d /persist/openfang/scripts 0755 root root - -"
      "L+ /persist/openfang/scripts/wa-notify.sh - - - - ${waNotifyScript}"
      "L+ /persist/openfang/scripts/fluzy-notify.sh - - - - ${fluzyNotifyScript}"
    ];
  };
}
