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

  # fluzy-notify: send context to Fluzy's agent — agent processes and delivers to WhatsApp
  # OpenFang agent API is async: returns {"status":"accepted"} and delivers response internally
  # Falls back to wa-notify only if no agent exists yet
  fluzyNotifyScript = pkgs.writeShellScript "fluzy-notify" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:${pkgs.gnugrep}/bin:$PATH

    CONTEXT_MSG="$1"

    # Clean fallback message: strip [SYSTEM] prefix and LLM instructions
    CLEAN_MSG=$(echo "$CONTEXT_MSG" | sed 's/^\[SYSTEM\] //' | sed 's/ Inform the user.*//;s/ Let the user know.*//;s/ Suggest the user.*//')

    # Look up Bruno's agent_id and remote_jid
    AGENT_ID=$(psql -t -A -c "SELECT agent_id FROM channel_users WHERE channel_user_id LIKE '%559184519877%' AND agent_id IS NOT NULL LIMIT 1;" "${dbUrl}" 2>/dev/null)
    REMOTE_JID=$(psql -t -A -c "SELECT remote_jid FROM channel_users WHERE channel_user_id LIKE '%559184519877%' LIMIT 1;" "${dbUrl}" 2>/dev/null)
    TO="''${REMOTE_JID:-+559184519877}"

    # Fallback to clean direct send if no agent spawned yet
    if [ -z "$AGENT_ID" ] || ! echo "$AGENT_ID" | grep -qE '^[a-f0-9-]{36}$'; then
      echo "[fluzy-notify] No agent found, sending clean fallback"
      curl -s -X POST "${gatewayUrl}/message/send" \
        -H "Content-Type: application/json" \
        -d "{\"to\": \"$TO\", \"text\": $(echo "$CLEAN_MSG" | jq -Rs .)}"
      exit 0
    fi

    # Send context to Fluzy's agent — agent handles WhatsApp delivery async
    RESULT=$(curl -s --max-time 10 -X POST "${routerUrl}/api/agents/$AGENT_ID/message" \
      -H "Content-Type: application/json" \
      -d "{\"message\": $(echo "$CONTEXT_MSG" | jq -Rs .), \"content\": $(echo "$CONTEXT_MSG" | jq -Rs .), \"metadata\": {\"sender\": \"+559184519877\", \"sender_name\": \"System\", \"remote_jid\": \"$REMOTE_JID\"}}")

    if echo "$RESULT" | jq -e '.status' >/dev/null 2>&1; then
      echo "[fluzy-notify] Sent to agent $AGENT_ID — Fluzy will deliver"
    else
      echo "[fluzy-notify] Agent didn't accept, sending clean fallback"
      curl -s -X POST "${gatewayUrl}/message/send" \
        -H "Content-Type: application/json" \
        -d "{\"to\": \"$TO\", \"text\": $(echo "$CLEAN_MSG" | jq -Rs .)}"
    fi
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
