{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.openfang;
in
{
  imports = [ ./evolution-bridge.nix ./jellyseerr-bridge.nix ];

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
    useNativeWhatsapp = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Use OpenFang's built-in WhatsApp Web gateway instead of Evolution API";
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
  };

  config = lib.mkIf cfg.enable {
    # Node.js >= 18 required for native WhatsApp Web gateway
    environment.systemPackages = lib.mkIf cfg.useNativeWhatsapp [ pkgs.nodejs_22 ];

    # Ensure directories exist
    systemd.tmpfiles.rules = [
      "d ${cfg.configDir} 0750 root root - -"
      "d ${cfg.dataDir} 0750 root root - -"
    ];

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

    # Agent manifest template — used by bridge to create per-user agents
    environment.etc."openfang/agent-manifest.toml".text = ''
      [agent]
      name = "${cfg.agentName}"
      system_prompt = """
      ${cfg.systemPrompt}
      """

      [default_model]
      provider = "${cfg.llmProvider}"
      model = "${cfg.llmModel}"
      api_key_env = "${cfg.apiKeyEnvVar}"
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

      ${lib.concatMapStringsSep "\n" (fb: ''
      [[fallback_providers]]
      provider = "${fb.provider}"
      model = "${fb.model}"
      api_key_env = "${fb.apiKeyEnvVar}"
      ${lib.optionalString (fb.baseUrl != "") ''base_url = "${fb.baseUrl}"''}
      '') cfg.fallbackProviders}

      [memory]
      decay_rate = 0.05

      [network]
      listen_addr = "127.0.0.1:${toString cfg.listenPort}"

      [channels.whatsapp]
      enabled = true
      ${if cfg.useNativeWhatsapp then ''mode = "web"'' else ''gateway_url = "http://127.0.0.1:${toString cfg.whatsappGatewayPort}"''}
    '';

    # OpenFang main service
    systemd.services.openfang = {
      description = "OpenFang AI Agent";
      after = [ "network-online.target" "openfang-install.service" ];
      wants = [ "network-online.target" ];
      requires = [ "openfang-install.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        HOME = cfg.configDir;
        OPENFANG_CONFIG = "/etc/openfang/config.toml";
      } // lib.optionalAttrs cfg.useNativeWhatsapp {
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
          export HOME=${cfg.configDir}
          exec ${cfg.configDir}/.openfang/bin/openfang start --config ${cfg.configDir}/.openfang/config.toml
        '';
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = cfg.dataDir;
      };
    };

    # Sync system prompt to all per-user agents on rebuild
    systemd.services.openfang-sync-agents = {
      description = "Sync Fluzy persona to all OpenFang agents";
      after = [ "openfang.service" ];
      requires = [ "openfang.service" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "openfang-sync-agents" ''
          export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH

          OPENFANG_API="http://127.0.0.1:50051"
          SYSTEM_PROMPT=${lib.escapeShellArg cfg.systemPrompt}

          # Wait for API readiness
          for i in $(seq 1 30); do
            ${pkgs.curl}/bin/curl -sf "$OPENFANG_API/api/agents" >/dev/null 2>&1 && break
            sleep 2
          done

          # Update all agents with current system prompt
          AGENTS=$(${pkgs.curl}/bin/curl -s "$OPENFANG_API/api/agents" | ${pkgs.jq}/bin/jq -r '.[].id')

          for AGENT_ID in $AGENTS; do
            ${pkgs.curl}/bin/curl -s -X PUT "$OPENFANG_API/api/agents/$AGENT_ID/update" \
              -H "Content-Type: application/json" \
              -d "{\"system_prompt\": $(echo "$SYSTEM_PROMPT" | ${pkgs.jq}/bin/jq -Rs .), \"description\": $(echo ${lib.escapeShellArg cfg.agentName} | ${pkgs.jq}/bin/jq -Rs .)}"
            echo "[sync] Updated agent $AGENT_ID"
          done
        '';
      };
    };

    # OpenFang WhatsApp Web Gateway (native, no Evolution)
    systemd.services.openfang-whatsapp-gateway = lib.mkIf cfg.useNativeWhatsapp {
      description = "OpenFang WhatsApp Web Gateway";
      after = [ "network-online.target" "openfang-install.service" ];
      wants = [ "network-online.target" ];
      requires = [ "openfang-install.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        HOME = cfg.configDir;
        WHATSAPP_GATEWAY_PORT = toString cfg.whatsappGatewayPort;
        OPENFANG_URL = "http://127.0.0.1:${toString cfg.listenPort}";
      };
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "openfang-wa-gateway-install" ''
          export PATH=${pkgs.git}/bin:${pkgs.nodejs_22}/bin:${pkgs.coreutils}/bin:$PATH
          GATEWAY_DIR="${cfg.dataDir}/whatsapp-gateway"
          if [ ! -d "$GATEWAY_DIR" ]; then
            ${pkgs.git}/bin/git clone --depth 1 --sparse https://github.com/RightNow-AI/openfang.git "$GATEWAY_DIR"
            cd "$GATEWAY_DIR"
            ${pkgs.git}/bin/git sparse-checkout set packages/whatsapp-gateway
          else
            cd "$GATEWAY_DIR"
            ${pkgs.git}/bin/git pull --ff-only 2>/dev/null || true
          fi
          cd "$GATEWAY_DIR/packages/whatsapp-gateway"
          ${pkgs.nodejs_22}/bin/npm install --production 2>&1
        '';
        ExecStart = pkgs.writeShellScript "openfang-wa-gateway-run" ''
          export PATH=${pkgs.nodejs_22}/bin:$PATH
          cd ${cfg.dataDir}/whatsapp-gateway/packages/whatsapp-gateway
          exec ${pkgs.nodejs_22}/bin/node index.js
        '';
        Restart = "on-failure";
        RestartSec = 5;
      };
    };

    # WhatsApp via Evolution API (see evolution-bridge.nix)

    # Caddy reverse proxy
    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:50051
      '';
    };
  };
}
