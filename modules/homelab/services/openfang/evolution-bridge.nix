# Evolution API built from source + bridge to OpenFang
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
  instanceName = "sweet-whatsapp";
  evolutionVersion = "2.3.7";

  evolutionSrc = pkgs.fetchFromGitHub {
    owner = "EvolutionAPI";
    repo = "evolution-api";
    rev = "${evolutionVersion}";
    hash = "sha256-0000000000000000000000000000000000000000000000000000";
  };

  # Bridge script
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

    RESPONSE=$(${pkgs.curl}/bin/curl -s -X POST "$OPENFANG_URL/api/agents/$AGENT_ID/message" \
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

      if [ "$EVENT" = "messages.upsert" ]; then
        FROM_ME=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.key.fromMe // false')
        if [ "$FROM_ME" = "false" ]; then
          SENDER=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.key.remoteJid // empty' | sed 's/@.*//')
          SENDER_NAME=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.pushName // "Unknown"')
          MESSAGE=$(echo "$BODY" | ${pkgs.jq}/bin/jq -r '.data.message.conversation // .data.message.extendedTextMessage.text // empty')

          if [ -n "$MESSAGE" ] && [ -n "$SENDER" ]; then
            echo "[bridge] Message from $SENDER_NAME ($SENDER): $MESSAGE" >&2
            AGENT_ID=$(${pkgs.curl}/bin/curl -s http://127.0.0.1:50051/api/agents | ${pkgs.jq}/bin/jq -r '.[0].id')
            ${bridgeScript} "$AGENT_ID" "$SENDER" "$MESSAGE" "$SENDER_NAME" &
          fi
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
    # Evolution API from source
    systemd.services.evolution-api = {
      description = "Evolution API WhatsApp Gateway";
      after = [ "network-online.target" "postgresql.service" ];
      wants = [ "network-online.target" ];
      requires = [ "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        AUTHENTICATION_API_KEY = evolutionApiKey;
        AUTHENTICATION_EXPOSE_IN_FETCH_INSTANCES = "true";
        DEL_INSTANCE = "false";
        DATABASE_PROVIDER = "postgresql";
        DATABASE_CONNECTION_URI = "postgresql://evolution@127.0.0.1:5432/evolution";
        CACHE_REDIS_ENABLED = "false";
        LOG_LEVEL = "INFO";
        DATABASE_SAVE_DATA_INSTANCE = "true";
        DATABASE_SAVE_DATA_NEW_MESSAGE = "true";
        DATABASE_SAVE_MESSAGE_UPDATE = "true";
        DATABASE_SAVE_DATA_CONTACTS = "true";
        DATABASE_SAVE_DATA_CHATS = "true";
        DATABASE_SAVE_DATA_LABELS = "true";
        DATABASE_SAVE_DATA_HISTORIC = "true";
        NODE_ENV = "production";
        HOME = "/var/lib/evolution-api";
        PRISMA_QUERY_ENGINE_LIBRARY = "${pkgs.prisma-engines}/lib/libquery_engine.node";
        PRISMA_SCHEMA_ENGINE_BINARY = "${pkgs.prisma-engines}/bin/schema-engine";
        PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING = "1";
      };
      path = [ pkgs.nodejs pkgs.bash pkgs.coreutils pkgs.git ];
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "evolution-setup" ''
          export PATH=${pkgs.nodejs}/bin:${pkgs.bash}/bin:${pkgs.coreutils}/bin:${pkgs.git}/bin:${pkgs.gnumake}/bin:${pkgs.python3}/bin:${pkgs.openssl}/bin:$PATH
          export HOME=/var/lib/evolution-api
          export PRISMA_QUERY_ENGINE_LIBRARY=${pkgs.prisma-engines}/lib/libquery_engine.node
          export PRISMA_SCHEMA_ENGINE_BINARY=${pkgs.prisma-engines}/bin/schema-engine
          export PRISMA_ENGINES_CHECKSUM_IGNORE_MISSING=1

          if [ ! -f /var/lib/evolution-api/src/main.ts ]; then
            echo "[evolution] Cloning v${evolutionVersion}..."
            ${pkgs.git}/bin/git clone --depth 1 --branch ${evolutionVersion} https://github.com/EvolutionAPI/evolution-api.git /tmp/evolution-src

            echo "[evolution] Installing dependencies..."
            cd /tmp/evolution-src
            ${pkgs.nodejs}/bin/npm install

            echo "[evolution] Copying to /var/lib/evolution-api..."
            cp -r /tmp/evolution-src/* /var/lib/evolution-api/
            cp /tmp/evolution-src/.env.example /var/lib/evolution-api/.env 2>/dev/null || true
            rm -rf /tmp/evolution-src

            echo "[evolution] Running migrations..."
            cd /var/lib/evolution-api
            DATABASE_PROVIDER=postgresql DATABASE_CONNECTION_URI="postgresql://evolution@127.0.0.1:5432/evolution" ${pkgs.nodejs}/bin/npm run db:deploy

            echo "[evolution] Generating Prisma client..."
            DATABASE_PROVIDER=postgresql DATABASE_CONNECTION_URI="postgresql://evolution@127.0.0.1:5432/evolution" ${pkgs.nodejs}/bin/npm run db:generate
          fi
        '';
        ExecStart = pkgs.writeShellScript "evolution-run" ''
          export PATH=${pkgs.nodejs}/bin:${pkgs.bash}/bin:${pkgs.coreutils}/bin:$PATH
          export HOME=/var/lib/evolution-api
          cd /var/lib/evolution-api
          exec ${pkgs.nodejs}/bin/npx tsx ./src/main.ts
        '';
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = "/var/lib/evolution-api";
      };
    };

    systemd.tmpfiles.rules = [
      "d /var/lib/evolution-api 0750 root root - -"
    ];

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
