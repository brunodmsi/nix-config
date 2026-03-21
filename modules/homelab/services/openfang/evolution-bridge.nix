# Bridge between Evolution API (WhatsApp) and OpenFang (AI Agent)
# Receives webhooks from Evolution API, forwards to OpenFang, sends replies back
{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.openfang;
  evolutionPort = 8084;
  evolutionApiKey = "openfang-evolution-bridge";
  instanceName = "sweet-whatsapp";

  # Bridge script: receives Evolution webhook, forwards to OpenFang, replies via Evolution
  bridgeScript = pkgs.writeShellScript "evolution-openfang-bridge" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH

    EVOLUTION_URL="http://127.0.0.1:${toString evolutionPort}"
    OPENFANG_URL="http://127.0.0.1:50051"
    API_KEY="${evolutionApiKey}"
    INSTANCE="${instanceName}"
    AGENT_ID="$1"
    SENDER="$2"
    MESSAGE="$3"
    SENDER_NAME="$4"

    # Forward to OpenFang
    RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST "$OPENFANG_URL/api/agents/$AGENT_ID/message" \
      -H "Content-Type: application/json" \
      -d "{\"message\": $(echo "$MESSAGE" | ${pkgs.jq}/bin/jq -Rs .), \"metadata\": {\"channel\": \"whatsapp\", \"sender\": \"$SENDER\", \"sender_name\": \"$SENDER_NAME\"}}" \
      --max-time 120)

    # Extract response text
    REPLY=$(echo "$RESPONSE" | ${pkgs.jq}/bin/jq -r '.response // .message // .text // empty')

    if [ -n "$REPLY" ] && [ "$REPLY" != "null" ]; then
      # Send reply via Evolution API
      ${pkgs.curl}/bin/curl -s -X POST "$EVOLUTION_URL/message/sendText/$INSTANCE" \
        -H "Content-Type: application/json" \
        -H "apikey: $API_KEY" \
        -d "{\"number\": \"$SENDER\", \"text\": $(echo "$REPLY" | ${pkgs.jq}/bin/jq -Rs .)}"
    fi
  '';

  # Webhook receiver: lightweight HTTP server that receives Evolution webhooks
  webhookReceiver = pkgs.writeShellScript "evolution-webhook-receiver" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.socat}/bin:$PATH

    echo "[bridge] Evolution-OpenFang bridge listening on port 3010"

    while true; do
      ${pkgs.socat}/bin/socat TCP-LISTEN:3010,reuseaddr,fork EXEC:"${webhookHandler}"
    done
  '';

  webhookHandler = pkgs.writeShellScript "evolution-webhook-handler" ''
    export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH

    # Read HTTP request
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

    # Respond immediately
    echo -e "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: 4\r\n\r\n{\"ok\":true}"

    # Process in background
    if [ -n "$BODY" ]; then
      EVENT=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.event // empty')

      if [ "$EVENT" = "messages.upsert" ]; then
        # Extract message details
        FROM_ME=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.key.fromMe // false')
        if [ "$FROM_ME" = "false" ]; then
          SENDER=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.key.remoteJid // empty' | sed 's/@.*//')
          SENDER_NAME=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.pushName // "Unknown"')
          MESSAGE=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.message.conversation // .data.message.extendedTextMessage.text // empty')

          if [ -n "$MESSAGE" ] && [ -n "$SENDER" ]; then
            echo "[bridge] Message from $SENDER_NAME ($SENDER): $MESSAGE" >&2
            # Get agent ID
            AGENT_ID=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:50051/api/agents | ${pkgs.jq}/bin/jq -r '.[0].id')
            ${bridgeScript} "$AGENT_ID" "$SENDER" "$MESSAGE" "$SENDER_NAME" &
          fi
        fi
      fi
    fi
  '';
in
{
  config = lib.mkIf cfg.enable {
    # Evolution API container
    virtualisation.oci-containers.containers.evolution-api = {
      image = "atendai/evolution-api:v2.2.3";
      ports = [ "${toString evolutionPort}:8080" ];
      environment = {
        AUTHENTICATION_API_KEY = evolutionApiKey;
        AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES = "true";
        DEL_INSTANCE = "false";
        DATABASE_PROVIDER = "postgresql";
        DATABASE_CONNECTION_URI = "postgresql://evolution:evolution@10.88.0.1:5432/evolution";
        CACHE_REDIS_ENABLED = "false";
        LOG_LEVEL = "WARN";
      };
      volumes = [
        "evolution_instances:/evolution/instances"
      ];
      extraOptions = [ "--add-host=host.containers.internal:host-gateway" ];
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
