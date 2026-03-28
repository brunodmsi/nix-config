{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.openfang;
  patchScript = ./patch-gateway.py;
in
{
  imports = [ ./database.nix ./jellyseerr-bridge.nix ./message-router.nix ./wa-notify.nix ./skills.nix ./monitoring.nix ./update-watcher.nix ./backup-agent.nix ./fluminense.nix ];

  options.homelab.services.openfang = {
    enable = lib.mkEnableOption "OpenFang AI Agent";
    configDir = lib.mkOption {
      type = lib.types.str;
      default = "/persist/openfang";
    };
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/openfang";
    };
    llmProvider = lib.mkOption {
      type = lib.types.str;
      default = "anthropic";
    };
    llmModel = lib.mkOption {
      type = lib.types.str;
      default = "claude-sonnet-4-5-20250514";
    };
    apiKeyEnvVar = lib.mkOption {
      type = lib.types.str;
      default = "ANTHROPIC_API_KEY";
    };
    apiKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file containing the LLM API key";
    };
    baseUrl = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "Base URL for OpenAI-compatible providers (e.g. OpenRouter)";
    };
    allowedSendersFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to file with allowed WhatsApp numbers, one per line";
    };
    jellyseerr = {
      enable = lib.mkEnableOption "Jellyseerr WhatsApp integration";
      apiKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the Jellyseerr API key";
      };
      webhookPort = lib.mkOption {
        type = lib.types.int;
        default = 3011;
      };
    };
    jellyfin = {
      enable = lib.mkEnableOption "Jellyfin media skill";
      apiKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the Jellyfin API key";
      };
      userId = lib.mkOption {
        type = lib.types.str;
        description = "Jellyfin user ID for API queries";
      };
      port = lib.mkOption {
        type = lib.types.int;
        default = 8096;
      };
    };
    paperless = {
      enable = lib.mkEnableOption "Paperless-ngx document skill";
      apiKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the Paperless-ngx API token";
      };
      port = lib.mkOption {
        type = lib.types.int;
        default = 28981;
      };
    };
    nextcloud = {
      enable = lib.mkEnableOption "Nextcloud skill (notes, calendar, tasks)";
      apiKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to file containing the Nextcloud app password";
      };
      user = lib.mkOption {
        type = lib.types.str;
        default = "bmasi";
      };
      port = lib.mkOption {
        type = lib.types.int;
        default = 8009;
      };
    };
    fallbackProviders = lib.mkOption {
      type = lib.types.listOf (lib.types.submodule {
        options = {
          provider = lib.mkOption { type = lib.types.str; };
          model = lib.mkOption { type = lib.types.str; };
          apiKeyEnvVar = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
          apiKeyFile = lib.mkOption {
            type = lib.types.path;
            default = "/dev/null";
            description = "Path to file containing the fallback provider API key";
          };
          baseUrl = lib.mkOption {
            type = lib.types.str;
            default = "";
          };
        };
      });
      default = [ ];
      description = "Fallback providers tried when the primary provider fails";
    };
    agentName = lib.mkOption {
      type = lib.types.str;
      default = "Fluzy";
    };
    systemPrompt = lib.mkOption {
      type = lib.types.str;
      default = "";
      description = "System prompt to define the agent's persona and behavior";
    };
    whatsappGatewayPort = lib.mkOption {
      type = lib.types.int;
      default = 3009;
    };
    listenPort = lib.mkOption {
      type = lib.types.int;
      default = 4200;
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "agent.${homelab.baseDomain}";
    };
    skills = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [];
      description = "OpenFang skills to enable for the agent";
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "OpenFang";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "AI Agent assistant";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "mdi-robot-happy-outline";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Services";
    };
    playwright.enable = lib.mkEnableOption "Shared Playwright Python venv for browser automation";
    tavilyApiKeyFile = lib.mkOption {
      type = lib.types.nullOr lib.types.path;
      default = null;
      description = "Path to file containing the Tavily API key for web_search";
    };
  };

  config = lib.mkIf cfg.enable {
    # Node.js >= 18 required for WhatsApp Web gateway
    environment.systemPackages = [
      pkgs.nodejs_22
      (pkgs.writeShellScriptBin "openfang" ''
        export HOME=${cfg.configDir}
        exec ${cfg.configDir}/.openfang/bin/openfang "$@"
      '')
    ];

    # Ensure directories exist
    systemd.tmpfiles.rules = [
      "d ${cfg.configDir} 0755 root root - -"
      "d ${cfg.dataDir} 0750 root root - -"
    ] ++ lib.optionals cfg.playwright.enable [
      "d ${cfg.configDir}/playwright-venv 0750 root root - -"
      # Shared wrapper: any script can use /persist/openfang/scripts/playwright-run.sh myscript.py args
      "L+ /persist/openfang/scripts/playwright-run.sh - - - - ${pkgs.writeShellScript "playwright-run" ''
        export PATH=${pkgs.coreutils}/bin:$PATH
        export LD_LIBRARY_PATH=${pkgs.stdenv.cc.cc.lib}/lib
        export PLAYWRIGHT_CHROMIUM_EXECUTABLE_PATH=${pkgs.chromium}/bin/chromium
        exec ${cfg.configDir}/playwright-venv/bin/python3 "$@"
      ''}"
    ];

    # Shared Playwright Python venv — used by any hand/skill that needs browser automation
    systemd.services.openfang-playwright-venv = lib.mkIf cfg.playwright.enable {
      description = "Install shared Playwright Python venv";
      after = [ "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ python3 coreutils bash ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "setup-playwright-venv" ''
          export PATH=${pkgs.python3}/bin:${pkgs.coreutils}/bin:${pkgs.bash}/bin:$PATH
          VENV=${cfg.configDir}/playwright-venv

          if [ ! -f $VENV/bin/python3 ]; then
            echo "[playwright] Creating shared Python venv..."
            ${pkgs.python3}/bin/python3 -m venv $VENV
          fi

          $VENV/bin/pip install --quiet --upgrade playwright playwright-stealth 2>&1
          echo "[playwright] Shared venv ready (using NixOS system chromium)"
        '';
      };
    };

    # Install OpenFang binary
    systemd.services.openfang-install = {
      description = "Install/update OpenFang binary";
      wantedBy = [ "multi-user.target" ];
      before = [ "openfang.service" ];
      environment.HOME = cfg.configDir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "openfang-install" ''
          export PATH=${pkgs.coreutils}/bin:${pkgs.bash}/bin:${pkgs.curl}/bin:${pkgs.gzip}/bin:${pkgs.gnutar}/bin:${pkgs.findutils}/bin:$PATH
          export HOME=${cfg.configDir}
          if [ ! -f ${cfg.configDir}/.openfang/bin/openfang ]; then
            ${pkgs.curl}/bin/curl -fsSL https://openfang.sh/install | ${pkgs.bash}/bin/bash
          fi
        '';
      };
    };

    # Fluzy agent template — placed in OpenFang's custom templates dir
    environment.etc."openfang/agent-manifest.toml".text =
      let
        escapedPrompt = lib.replaceStrings [ "\n" "\"" "\\" ] [ "\\n" "\\\"" "\\\\" ] cfg.systemPrompt;
        lowerName = lib.toLower cfg.agentName;
      in
      ''
        name = "${lowerName}"
        version = "0.1.0"
        description = "${cfg.agentName} WhatsApp assistant"
        author = "bmasi"
        module = "builtin:chat"
        ${lib.optionalString (cfg.skills != []) ''skills = [${lib.concatMapStringsSep ", " (s: ''"${s}"'') cfg.skills}]''}

        [model]
        provider = "${cfg.llmProvider}"
        model = "${cfg.llmModel}"
        api_key_env = "${cfg.apiKeyEnvVar}"
        max_tokens = 4096
        temperature = 0.3
        system_prompt = "${escapedPrompt}"

        [capabilities]
        tools = ["shell_exec", "web_fetch", "web_search", "memory_store", "memory_recall"]
        shell = ["/persist/openfang/scripts/*"]

        [exec_policy]
        mode = "full"
      '';

    # Generate config.toml
    environment.etc."openfang/config.toml".text = ''
      [agent]
      name = "${cfg.agentName}"
      system_prompt = """
      ${cfg.systemPrompt}
      """

      [default_model]
      provider = "${cfg.llmProvider}"
      model = "${cfg.llmModel}"
      api_key_env = "${cfg.apiKeyEnvVar}"
      ${lib.optionalString (cfg.baseUrl != "") ''base_url = "${cfg.baseUrl}"''}

      ${lib.concatMapStringsSep "\n" (fb: ''
      [[fallback_providers]]
      provider = "${fb.provider}"
      model = "${fb.model}"
      api_key_env = "${fb.apiKeyEnvVar}"
      ${lib.optionalString (fb.baseUrl != "") ''base_url = "${fb.baseUrl}"''}
      '') cfg.fallbackProviders}

      [heartbeat]
      check_interval_secs = 30
      default_timeout_secs = 300

      [memory]
      decay_rate = 0.05

      [network]
      listen_addr = "127.0.0.1:${toString cfg.listenPort}"

      [channels.whatsapp]
      enabled = true
      mode = "web"
    '';

    # OpenFang main service
    systemd.services.openfang = {
      description = "OpenFang AI Agent";
      after = [ "network-online.target" "openfang-install.service" ];
      wants = [ "network-online.target" ];
      requires = [ "openfang-install.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ bash coreutils gnugrep gnused findutils curl jq postgresql python3 ];
      environment = {
        HOME = cfg.configDir;
        OPENFANG_CONFIG = "/etc/openfang/config.toml";
        WHATSAPP_WEB_GATEWAY_URL = "http://127.0.0.1:${toString cfg.whatsappGatewayPort}";
      };
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "openfang-init" ''
          export ${cfg.apiKeyEnvVar}=$(cat ${cfg.apiKeyFile})
          export HOME=${cfg.configDir}
          if [ ! -f ${cfg.configDir}/.openfang/config.toml ]; then
            ${cfg.configDir}/.openfang/bin/openfang init --quick || true
          fi
          cp /etc/openfang/config.toml ${cfg.configDir}/.openfang/config.toml
        '';
        ExecStart = pkgs.writeShellScript "openfang-run" ''
          export ${cfg.apiKeyEnvVar}=$(cat ${cfg.apiKeyFile})
          ${lib.concatMapStringsSep "\n" (fb: lib.optionalString (fb.apiKeyEnvVar != "" && fb.apiKeyFile != "/dev/null") ''
          export ${fb.apiKeyEnvVar}=$(cat ${fb.apiKeyFile})
          '') cfg.fallbackProviders}
          ${lib.optionalString (cfg.tavilyApiKeyFile != null) ''
          export TAVILY_API_KEY=$(cat ${cfg.tavilyApiKeyFile})
          ''}
          export HOME=${cfg.configDir}
          exec ${cfg.configDir}/.openfang/bin/openfang start --yolo --config ${cfg.configDir}/.openfang/config.toml
        '';
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = cfg.dataDir;
        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "full";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    # On rebuild: kill all agents + clear mappings (router re-creates on next message)
    systemd.services.openfang-sync-agents = {
      description = "Sync ${cfg.agentName} agents on config change";
      after = [ "openfang.service" "postgresql.service" "openfang-db-init.service" ];
      requires = [ "openfang.service" "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      environment.HOME = cfg.configDir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "openfang-sync-agents" ''
          export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:${pkgs.postgresql}/bin:$PATH
          export HOME=${cfg.configDir}

          OPENFANG_API="http://127.0.0.1:50051"
          OPENFANG_BIN="${cfg.configDir}/.openfang/bin/openfang"
          OPENFANG_CONFIG="${cfg.configDir}/.openfang/config.toml"
          DB="postgresql://openfang@127.0.0.1:5432/openfang"

          # Wait for API
          for i in $(seq 1 30); do
            ${pkgs.curl}/bin/curl -sf "$OPENFANG_API/api/agents" >/dev/null 2>&1 && break
            sleep 2
          done

          # Kill all existing agents
          AGENTS=$(${pkgs.curl}/bin/curl -s "$OPENFANG_API/api/agents" | ${pkgs.jq}/bin/jq -r '.[].id')
          for AGENT_ID in $AGENTS; do
            $OPENFANG_BIN agent kill --config "$OPENFANG_CONFIG" "$AGENT_ID" 2>/dev/null || true
            echo "[sync] Killed agent $AGENT_ID"
          done

          # Clear agent mappings — router will re-create on next message
          psql -c "UPDATE channel_users SET agent_id = NULL;" "$DB" 2>/dev/null
          echo "[sync] Cleared agent mappings. Router will re-create agents with new manifest."
        '';
      };
    };

    # WhatsApp Web Gateway
    systemd.services.openfang-whatsapp-gateway = {
      description = "OpenFang WhatsApp Web Gateway";
      after = [ "network-online.target" "openfang-install.service" "openfang-message-router.service" ];
      wants = [ "network-online.target" ];
      requires = [ "openfang-install.service" "openfang-message-router.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ bash coreutils git nodejs_22 ];
      environment = {
        HOME = cfg.configDir;
        WHATSAPP_GATEWAY_PORT = toString cfg.whatsappGatewayPort;
        WHATSAPP_SEND_PORT = "3010";
        OPENFANG_URL = "http://127.0.0.1:50052";
      };
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "openfang-wa-gateway-install" ''
          export PATH=${pkgs.git}/bin:${pkgs.nodejs_22}/bin:${pkgs.coreutils}/bin:$PATH
          export npm_config_cache="${cfg.dataDir}/.npm-cache"
          GATEWAY_DIR="${cfg.dataDir}/whatsapp-gateway"

          # Re-fetch gateway if missing or patch version changed
          NEED_INSTALL=0
          if [ ! -f "$GATEWAY_DIR/index.js" ]; then
            NEED_INSTALL=1
          elif ! grep -q "PATCHED_V12" "$GATEWAY_DIR/index.js" 2>/dev/null; then
            echo "[gateway] Patch version changed, re-fetching clean source..."
            rm -rf "$GATEWAY_DIR"
            NEED_INSTALL=1
          fi

          if [ "$NEED_INSTALL" = "1" ]; then
            mkdir -p "$GATEWAY_DIR"
            cd "$GATEWAY_DIR"
            ${pkgs.git}/bin/git clone --depth 1 https://github.com/RightNow-AI/openfang.git /tmp/openfang-repo
            cp /tmp/openfang-repo/packages/whatsapp-gateway/* "$GATEWAY_DIR/" 2>/dev/null || true
            cp -r /tmp/openfang-repo/packages/whatsapp-gateway/.* "$GATEWAY_DIR/" 2>/dev/null || true
            rm -rf /tmp/openfang-repo
          fi

          cd "$GATEWAY_DIR"
          ${pkgs.nodejs_22}/bin/npm install --omit=dev 2>&1

          # Patch gateway: media download + LID reply fix + remote_jid + senderPn
          ${pkgs.python3}/bin/python3 ${patchScript} "$GATEWAY_DIR/index.js"
        '';
        ExecStart = pkgs.writeShellScript "openfang-wa-gateway-run" ''
          export PATH=${pkgs.nodejs_22}/bin:$PATH
          export OPENFANG_DEFAULT_AGENT=router-managed
          exec ${pkgs.nodejs_22}/bin/node ${cfg.dataDir}/whatsapp-gateway/index.js
        '';
        Restart = "on-failure";
        RestartSec = 5;
        # Hardening
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "full";
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictSUIDSGID = true;
      };
    };

    # Caddy reverse proxy
    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:50051
      '';
    };
  };
}
