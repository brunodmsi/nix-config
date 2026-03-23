# Per-sender agent router — routes WhatsApp messages to per-user OpenFang agents
{
  config,
  lib,
  pkgs,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.openfang;
  dbUrl = "postgresql://openfang@127.0.0.1:5432/openfang";
  routerPort = 50052;
  openfangApi = "http://127.0.0.1:50051";

  # Use writeTextFile to avoid Nix '' escaping issues with JS template literals
  routerScript = pkgs.writeTextFile {
    name = "openfang-message-router.mjs";
    text = builtins.readFile ./message-router.js;
  };
in
{
  config = lib.mkIf cfg.enable {
    systemd.services.openfang-message-router = {
      description = "OpenFang per-sender message router";
      after = [ "openfang.service" "postgresql.service" "openfang-db-init.service" ];
      requires = [ "openfang.service" "postgresql.service" ];
      wantedBy = [ "multi-user.target" ];
      path = with pkgs; [ bash coreutils curl jq postgresql ];
      environment = {
        HOME = cfg.configDir;
        ROUTER_PORT = toString routerPort;
        OPENFANG_API = openfangApi;
        DB_URL = dbUrl;
        OPENFANG_BIN = "${cfg.configDir}/.openfang/bin/openfang";
        OPENFANG_CONFIG = "${cfg.configDir}/.openfang/config.toml";
        MANIFEST_PATH = "/etc/openfang/agent-manifest.toml";
      };
      serviceConfig = {
        ExecStart = "${pkgs.nodejs_22}/bin/node ${routerScript}";
        Restart = "on-failure";
        RestartSec = 5;
      };
    };
  };
}
