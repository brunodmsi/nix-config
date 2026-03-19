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
    security.acme = {
      acceptTerms = true;
      defaults.email = "brunodmsi@gmail.com"; # TODO: update to your actual email
      certs.${config.homelab.baseDomain} = {
        reloadServices = [ "caddy.service" ];
        domain = "${config.homelab.baseDomain}";
        extraDomainNames = [ "*.${config.homelab.baseDomain}" ];
        dnsProvider = "cloudflare";
        dnsResolver = "1.1.1.1:53";
        dnsPropagationCheck = true;
        group = config.services.caddy.group;
        environmentFile = config.homelab.cloudflare.dnsCredentialsFile;
      };
    };
    services.caddy = {
      enable = true;
      globalConfig = ''
        auto_https off
      '';
      virtualHosts = {
        "http://${config.homelab.baseDomain}" = {
          extraConfig = ''
            redir https://{host}{uri}
          '';
        };
        "http://*.${config.homelab.baseDomain}" = {
          extraConfig = ''
            redir https://{host}{uri}
          '';
        };

      };
    };
    nixpkgs.config.permittedInsecurePackages = [
      "dotnet-sdk-6.0.428"
      "aspnetcore-runtime-6.0.36"
    ];
    virtualisation.podman = {
      dockerCompat = true;
      autoPrune.enable = true;
      extraPackages = [ pkgs.zfs ];
      defaultNetwork.settings = {
        dns_enabled = true;
      };
    };
    virtualisation.oci-containers = {
      backend = "podman";
    };

    networking.firewall.interfaces.podman0.allowedUDPPorts =
      lib.lists.optionals config.virtualisation.podman.enable
        [ 53 ];
  };

  imports = [
    ./arr/prowlarr
    ./arr/bazarr
    ./arr/jellyseerr
    ./arr/sonarr
    ./arr/radarr
    #./arr/lidarr
    ./deluge
    #./deemix
    ./forgejo
    ./forgejo-runner
    ./homepage
    ./immich
    ./jellyfin
    ./keycloak
    ./matrix
    ./plausible
    ./microbin
    ./miniflux
    ./monitoring/grafana
    ./monitoring/prometheus
    ./monitoring/prometheus/exporters/shelly_plug_exporter
    ./nextcloud
    ./smarthome/homeassistant
    ./smarthome/raspberrymatic
    ./paperless-ngx
    ./sabnzbd
    ./slskd
    ./uptime-kuma
    ./vaultwarden
    ./wireguard-netns
  ];
}
