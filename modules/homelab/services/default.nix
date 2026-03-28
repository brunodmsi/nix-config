{
  config,
  lib,
  pkgs,
  ...
}:
let
  cfg = config.homelab;
in
{
  options.homelab = {
    services = {
      enable = lib.mkEnableOption "Settings and services for the homelab";
    };
    frp = {
      enable = lib.mkEnableOption "Settings and services for the homelab";
      serverHostname = lib.mkOption {
        type = lib.types.str;
        description = "A hostname entry in the config.homelab.network.external which should be used as a server";
        default = "spencer";
      };
      tokenFile = lib.mkOption {
        type = lib.types.str;
        example = lib.literalExpression ''
          pkgs.writeText "token.txt" '''
            12345678
          '''
        '';
      };
    };
  };

  config = lib.mkIf config.homelab.services.enable {
    networking.firewall.allowedTCPPorts = [
      80
      443
    ]
    ++ (lib.optionals (
      config.networking.hostName == cfg.frp.serverHostname && config.homelab.frp.enable
    ) [ 7000 ]);
    systemd.services.frp.serviceConfig.LoadCredential =
      lib.mkIf config.homelab.frp.enable "frpToken:${cfg.frp.tokenFile}";
    services.frp = lib.mkIf config.homelab.frp.enable {
      enable = true;
      role = if (config.networking.hostName == cfg.frp.serverHostname) then "server" else "client";
      settings =
        let
          common = {
            auth.tokenSource.type = "file";
            auth.tokenSource.file.path = "/run/credentials/frp.service/frpToken";
          };
        in
        if (config.networking.hostName == cfg.frp.serverHostname) then
          {
            bindAddr = "0.0.0.0";
            bindPort = 7000;
          }
          // common
        else
          {
            serverAddr =
              lib.removeSuffix "/24"
                config.homelab.networks.external.${cfg.frp.serverHostname}.v4.address;
            serverPort = 7000;
          }
          // common;
    };
    services.caddy = {
      enable = true;
      globalConfig = ''
        auto_https off
      '';
    };
    nixpkgs.config.permittedInsecurePackages = [
      "dotnet-sdk-6.0.428"
      "aspnetcore-runtime-6.0.36"
    ];
    virtualisation.podman = {
      enable = true;
      dockerCompat = true;
    };
  };

  imports = [
    ./authelia
    ./arr/prowlarr
    ./arr/bazarr
    ./arr/jellyseerr
    ./arr/sonarr
    ./arr/radarr
    ./deluge
    ./homepage
    ./immich
    ./jellyfin
    ./microbin
    ./miniflux
    ./nextflux
    ./monitoring/prometheus
    ./monitoring/grafana
    ./nextcloud
    ./openfang
    ./paperless-ngx
    ./uptime-kuma
    ./vaultwarden
    ./wireguard-netns
    ./coding-agents
  ];
}
