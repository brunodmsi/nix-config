# Evolution API (container) + bridge to OpenFang
{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.openfang;
  evolutionPort = 8080;
  evolutionApiKey = "openfang-evolution-bridge";
  instanceName = "sweet-zap";

  bridgeScript = pkgs.writeShellScript "evolution-openfang-bridge" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH

    EVOLUTION_URL="http://127.0.0.1:${toString evolutionPort}"
    API_KEY="${evolutionApiKey}"
    INSTANCE="${instanceName}"
    AGENT_ID="$1"
    SENDER="$2"
    MESSAGE="$3"
    SENDER_NAME="$4"

    RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST "http://127.0.0.1:50051/api/agents/$AGENT_ID/message" \
      -H "Content-Type: application/json" \
      -d "{\"message\": $(echo "$MESSAGE" | ${pkgs.jq}/bin/jq -Rs .), \"metadata\": {\"channel\": \"whatsapp\", \"sender\": \"$SENDER\", \"sender_name\": \"$SENDER_NAME\"}}" \
      --max-time 120)

    REPLY=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.response // .message // .text // empty')

    if [ -n "$REPLY" ] && [ "$REPLY" != "null" ]; then
      ${pkgs.curl}/bin/curl -s -X POST "$EVOLUTION_URL/message/sendText/$INSTANCE" \
        -H "Content-Type: application/json" \
        -H "apikey: $API_KEY" \
        -d "{\"number\": \"$SENDER\", \"text\": $(echo "$REPLY" | ${pkgs.jq}/bin/jq -Rs .)}"
    fi
  '';

  webhookHandler = pkgs.writeShellScript "evolution-webhook-handler" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH

    read -r REQUEST_LINE
    CONTENT_LENGTH=0
    while IFS= read -r header; do
      header=$(echo "$header" | tr -d '\r')
      [ -z "$header" ] && break
      case "$header" in
        Content-Length:*|content-length:*) CONTENT_LENGTH=$(echo "$header" | cut -d: -f2 | tr -d ' ') ;;
      esac
    done

    BODY=""
    if [ "$CONTENT_LENGTH" -gt 0 ] 2>/dev/null; then
      BODY=$(head -c "$CONTENT_LENGTH")
    fi

    echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\n{\"ok\":true}"

    if [ -n "$BODY" ]; then
      EVENT=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.event // empty')

      if [ "$EVENT" = "messages.upsert" ] || [ "$EVENT" = "MESSAGES_UPSERT" ]; then
        FROM_ME=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.key.fromMe // false')
        MSG_ID=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.key.id // empty')
        if [ "$FROM_ME" != "false" ] || [ -z "$MSG_ID" ]; then
          exit 0
        fi

        # Atomic dedup using mkdir (atomic on all filesystems)
        DEDUP_DIR="/var/lib/openfang/dedup"
        if ! mkdir "$DEDUP_DIR/$MSG_ID" 2>/dev/null; then
          exit 0
        fi
        # Clean old dedup dirs in background
        find "$DEDUP_DIR" -maxdepth 1 -type d -mmin +2 -exec rmdir {} \; 2>/dev/null &

        SENDER=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.key.remoteJid // empty' | sed 's/@.*//')
        SENDER_NAME=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.pushName // "Unknown"')
        MESSAGE=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.message.conversation // .data.message.extendedTextMessage.text // empty')

        # Check allowed senders
        ALLOWED_FILE="${cfg.allowedSendersFile}"
        if [ -f "$ALLOWED_FILE" ] && ! grep -q "$SENDER" "$ALLOWED_FILE"; then
          echo "[bridge] Rejected from unauthorized sender: $SENDER" >&2
          exit 0
        fi

        if [ -n "$MESSAGE" ] && [ -n "$SENDER" ]; then
          echo "[bridge] Message from $SENDER_NAME ($SENDER): $MESSAGE" >&2
          AGENT_ID=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:50051/api/agents | ${pkgs.jq}/bin/jq -r '.[0].id')
          ${bridgeScript} "$AGENT_ID" "$SENDER" "$MESSAGE" "$SENDER_NAME" &
        fi
      fi
    fi
  '';

  webhookReceiver = pkgs.writeShellScript "evolution-webhook-receiver" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.socat}/bin:$PATH
    echo "[bridge] Evolution-OpenFang bridge listening on port 3010"
    while true; do
      ${pkgs.socat}/bin/socat TCP-LISTEN:3010,reuseaddr,fork EXEC:"${webhookHandler}"
    done
  '';
in
{
  config = lib.mkIf cfg.enable {
    # Build Evolution API v2.3.7 container on first run
    systemd.services.evolution-api-build = {
      description = "Build Evolution API container image";
      wantedBy = [ "multi-user.target" ];
      before = [ "evolution-api.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "evolution-build" ''
          export PATH=${pkgs.git}/bin:${pkgs.coreutils}/bin:$PATH
          if ! ${pkgs.podman}/bin/podman image exists localhost/evolution-api:v2.3.7 2>/dev/null; then
            echo "[evolution] Building v2.3.7 from source..."
            ${pkgs.podman}/bin/podman build -t evolution-api:v2.3.7 https://github.com/EvolutionAPI/evolution-api.git#2.3.7
          else
            echo "[evolution] Image already exists"
          fi
        '';
        TimeoutStartSec = "600";
      };
    };

    # Evolution API container with host networking
    systemd.services.evolution-api = {
      description = "Evolution API WhatsApp Gateway";
      after = [ "network-online.target" "postgresql.service" "evolution-api-build.service" ];
      wants = [ "network-online.target" ];
      requires = [ "postgresql.service" "evolution-api-build.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStartPre = "${pkgs.podman}/bin/podman rm -f evolution-api 2>/dev/null || true";
        ExecStart = ''
          ${pkgs.podman}/bin/podman run --rm --name evolution-api \
            --network=host \
            -e AUTHENTICATION_API_KEY=${evolutionApiKey} \
            -e AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES=true \
            -e DEL_INSTANCE=false \
            -e DATABASE_PROVIDER=postgresql \
            -e "DATABASE_CONNECTION_URI=postgresql://evolution@127.0.0.1:5432/evolution" \
            -e CACHE_REDIS_ENABLED=false \
            -e LOG_LEVEL=INFO \
            -v evolution_instances:/evolution/instances \
            localhost/evolution-api:v2.3.7
        '';
        ExecStop = "${pkgs.podman}/bin/podman stop evolution-api";
        Restart = "on-failure";
        RestartSec = 10;
      };
    };

    # PostgreSQL database for Evolution
    services.postgresql = {
      enableTCPIP = true;
      ensureDatabases = [ "evolution" ];
      ensureUsers = [
        {
          name = "evolution";
          ensureDBOwnership = true;
        }
      ];
      authentication = lib.mkAfter ''
        host evolution evolution 10.88.0.0/16 trust
        host evolution evolution 127.0.0.1/32 trust
      '';
    };

    # Evolution API manager via Caddy
    services.caddy.virtualHosts."http://wa-setup.${homelab.baseDomain}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:${toString evolutionPort}
      '';
    };

    # Webhook bridge service
    systemd.services.evolution-openfang-bridge = {
      description = "Evolution API to OpenFang bridge";
      after = [ "network-online.target" "openfang.service" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        ExecStart = webhookReceiver;
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
