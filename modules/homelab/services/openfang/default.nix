{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.openfang;
  patchScript = pkgs.writeText "patch-gateway.py" ''
    import sys, pathlib
    f = pathlib.Path(sys.argv[1])
    src = f.read_text()
    if "PATCHED_V3" in src:
        print("[patch] Already patched")
        sys.exit(0)

    # 1. Use senderPn for DM replies instead of LID
    src = src.replace(
        ": remoteJid;",
        ": (msg.key.senderPn || remoteJid);"
    )

    # 2. Add dedup + detailed logging after "const phone = " line
    old_phone = "const pushName = msg.pushName || phone;"
    new_phone = old_phone + """
      // PATCHED_V3: dedup + detailed logging
      const msgId = msg.key.id;
      if (!globalThis._seenMsgs) globalThis._seenMsgs = new Set();
      if (globalThis._seenMsgs.has(msgId)) { console.log('[gateway] DEDUP: skipping ' + msgId); continue; }
      globalThis._seenMsgs.add(msgId);
      if (globalThis._seenMsgs.size > 1000) globalThis._seenMsgs.clear();
      console.log('[gateway] MSG ' + msgId + ' | remoteJid=' + remoteJid + ' | senderPn=' + (msg.key.senderPn || 'none') + ' | senderJid=' + senderJid + ' | phone=' + phone);"""

    src = src.replace(old_phone, new_phone)

    # 3. Add reply JID logging
    src = src.replace(
        "await sock.sendMessage(replyJid",
        "console.log('[gateway] REPLY: sending to ' + replyJid); await sock.sendMessage(replyJid"
    )

    f.write_text(src)
    print("[patch] Gateway patched (V3: senderPn + dedup + logging)")
  '';
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
    # Node.js >= 18 required for WhatsApp Web gateway
    environment.systemPackages = [ pkgs.nodejs_22 ];

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
      mode = "web"
      default_agent = "${lib.toLower cfg.agentName}"
    '';

    # OpenFang main service
    systemd.services.openfang = {
      description = "OpenFang AI Agent";
      after = [ "network-online.target" "openfang-install.service" ];
      wants = [ "network-online.target" ];
      requires = [ "openfang-install.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ bash coreutils gnugrep gnused findutils curl jq postgresql ];
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
          export HOME=${cfg.configDir}
          exec ${cfg.configDir}/.openfang/bin/openfang start --yolo --config ${cfg.configDir}/.openfang/config.toml
        '';
        Restart = "on-failure";
        RestartSec = 10;
        WorkingDirectory = cfg.dataDir;
      };
    };

    # Ensure Fluzy agent exists, re-spawn on config changes
    systemd.services.openfang-sync-agents = {
      description = "Ensure ${cfg.agentName} agent exists";
      after = [ "openfang.service" ];
      requires = [ "openfang.service" ];
      wantedBy = [ "multi-user.target" ];
      environment.HOME = cfg.configDir;
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = pkgs.writeShellScript "openfang-sync-agents" ''
          export PATH=${pkgs.coreutils}/bin:${pkgs.curl}/bin:${pkgs.jq}/bin:$PATH
          export HOME=${cfg.configDir}

          OPENFANG_API="http://127.0.0.1:50051"
          OPENFANG_BIN="${cfg.configDir}/.openfang/bin/openfang"
          OPENFANG_CONFIG="${cfg.configDir}/.openfang/config.toml"

          # Wait for API
          for i in $(seq 1 30); do
            ${pkgs.curl}/bin/curl -sf "$OPENFANG_API/api/agents" >/dev/null 2>&1 && break
            sleep 2
          done

          # Kill existing agents and re-spawn with current manifest
          AGENTS=$(${pkgs.curl}/bin/curl -s "$OPENFANG_API/api/agents" | ${pkgs.jq}/bin/jq -r '.[].id')
          for AGENT_ID in $AGENTS; do
            $OPENFANG_BIN agent kill --config "$OPENFANG_CONFIG" "$AGENT_ID" 2>/dev/null || true
          done

          $OPENFANG_BIN agent spawn --config "$OPENFANG_CONFIG" /etc/openfang/agent-manifest.toml

          # Write agent ID to file for gateway to use
          AGENT_ID=$(${pkgs.curl}/bin/curl -s "$OPENFANG_API/api/agents" | ${pkgs.jq}/bin/jq -r '.[0].id')
          echo "$AGENT_ID" > ${cfg.dataDir}/default-agent-id
          echo "[sync] Agent ID: $AGENT_ID"
        '';
      };
    };

    # WhatsApp Web Gateway
    systemd.services.openfang-whatsapp-gateway = {
      description = "OpenFang WhatsApp Web Gateway";
      after = [ "network-online.target" "openfang-install.service" "openfang-sync-agents.service" ];
      wants = [ "network-online.target" ];
      requires = [ "openfang-install.service" "openfang-sync-agents.service" ];
      wantedBy = [ "multi-user.target" ];
      environment = {
        HOME = cfg.configDir;
        WHATSAPP_GATEWAY_PORT = toString cfg.whatsappGatewayPort;
        OPENFANG_URL = "http://127.0.0.1:50051";
      };
      serviceConfig = {
        Type = "simple";
        ExecStartPre = pkgs.writeShellScript "openfang-wa-gateway-install" ''
          export PATH=${pkgs.git}/bin:${pkgs.nodejs_22}/bin:${pkgs.coreutils}/bin:$PATH
          GATEWAY_DIR="${cfg.dataDir}/whatsapp-gateway"
          if [ ! -f "$GATEWAY_DIR/index.js" ]; then
            mkdir -p "$GATEWAY_DIR"
            cd "$GATEWAY_DIR"
            ${pkgs.git}/bin/git clone --depth 1 https://github.com/RightNow-AI/openfang.git /tmp/openfang-repo
            cp /tmp/openfang-repo/packages/whatsapp-gateway/* "$GATEWAY_DIR/" 2>/dev/null || true
            cp -r /tmp/openfang-repo/packages/whatsapp-gateway/.* "$GATEWAY_DIR/" 2>/dev/null || true
            rm -rf /tmp/openfang-repo
          fi
          cd "$GATEWAY_DIR"
          ${pkgs.nodejs_22}/bin/npm install --omit=dev 2>&1

          # Patch gateway for LID fix + dedup + logging
          ${pkgs.python3}/bin/python3 ${patchScript} "$GATEWAY_DIR/index.js"
        '';
        ExecStart = pkgs.writeShellScript "openfang-wa-gateway-run" ''
          export PATH=${pkgs.nodejs_22}/bin:$PATH
          export OPENFANG_DEFAULT_AGENT=$(cat ${cfg.dataDir}/default-agent-id)
          exec ${pkgs.nodejs_22}/bin/node ${cfg.dataDir}/whatsapp-gateway/index.js
        '';
        Restart = "on-failure";
        RestartSec = 5;
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
