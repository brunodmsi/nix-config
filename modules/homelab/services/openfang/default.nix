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
      default = "robot.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Services";
    };
  };

  config = lib.mkIf cfg.enable {
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

    # Generate config.toml
    environment.etc."openfang/config.toml".text = ''
      [default_model]
      provider = "${cfg.llmProvider}"
      model = "${cfg.llmModel}"
      api_key_env = "${cfg.apiKeyEnvVar}"

      [memory]
      decay_rate = 0.05

      [network]
      listen_addr = "127.0.0.1:${toString cfg.listenPort}"

      [channels.whatsapp]
      enabled = true
      gateway_url = "http://127.0.0.1:${toString cfg.whatsappGatewayPort}"
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
      };
      serviceConfig = {
        ExecStart = pkgs.writeShellScript "openfang-run" ''
          export ${cfg.apiKeyEnvVar}=$(cat ${cfg.apiKeyFile})
          exec ${cfg.configDir}/.openfang/bin/openfang serve
        '';
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = cfg.dataDir;
      };
    };

    # WhatsApp Web Gateway (Node.js)
    systemd.services.openfang-whatsapp-gateway = {
      description = "OpenFang WhatsApp Web Gateway";
      after = [ "network-online.target" "openfang-install.service" ];
      wants = [ "network-online.target" ];
      requires = [ "openfang-install.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        PORT = toString cfg.whatsappGatewayPort;
        HOME = cfg.configDir;
      };
      serviceConfig = {
        ExecStartPre = pkgs.writeShellScript "whatsapp-gateway-setup" ''
          export PATH=${pkgs.coreutils}/bin:${pkgs.bash}/bin:${pkgs.git}/bin:${pkgs.nodejs}/bin:${pkgs.gnumake}/bin:${pkgs.python3}/bin:${pkgs.gcc}/bin:$PATH
          if [ ! -d ${cfg.dataDir}/whatsapp-gateway/node_modules ]; then
            mkdir -p ${cfg.dataDir}/whatsapp-gateway
            ${pkgs.git}/bin/git clone --depth 1 https://github.com/RightNow-AI/openfang.git /tmp/openfang-src || true
            if [ -d /tmp/openfang-src/packages/whatsapp-gateway ]; then
              cp -r /tmp/openfang-src/packages/whatsapp-gateway/* ${cfg.dataDir}/whatsapp-gateway/
              rm -rf /tmp/openfang-src
              cd ${cfg.dataDir}/whatsapp-gateway
              ${pkgs.nodejs}/bin/npm install --omit=dev
            fi
          fi
        '';
        ExecStart = pkgs.writeShellScript "whatsapp-gateway-run" ''
          cd ${cfg.dataDir}/whatsapp-gateway
          exec ${pkgs.nodejs}/bin/node index.js
        '';
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = cfg.dataDir;
      };
    };

    # Caddy reverse proxy
    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:${toString cfg.listenPort}
      '';
    };
  };
}
