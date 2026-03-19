{
  config,
  lib,
  pkgs,
  ...
}:
let
  service = "nextcloud";
  cfg = config.homelab.services.${service};
  hl = config.homelab;
in
{
  options.homelab.services.${service} = {
    enable = lib.mkEnableOption {
      description = "Enable ${service}";
    };
    dataDir = lib.mkOption {
      type = lib.types.str;
      default = "${hl.mounts.fast}/Media/Nextcloud";
    };
    configDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/${service}";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "cloud.s.demasi.dev";
    };
    monitoredServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "phpfpm-nextcloud"
      ];
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "Nextcloud";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "Enterprise File Storage and Collaboration";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "nextcloud.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Services";
    };
    admin.username = lib.mkOption {
      type = lib.types.str;
      example = "admin";
    };
    admin.passwordFile = lib.mkOption {
      type = lib.types.str;
      example = lib.literalExpression ''
        pkgs.writeText "nc-admin-password" '''
        super-secret-password
        '''
      '';
    };
    role = lib.mkOption {
      type = lib.types.enum [
        "client"
        "server"
      ];
      default = "client";
    };
  };
  config =
    let
      mkIfElse =
        p: yes: no:
        lib.mkMerge [
          (lib.mkIf p yes)
          (lib.mkIf (!p) no)
        ];
    in
    mkIfElse (cfg.role == "client")
      # client
      (lib.mkIf cfg.enable {
        systemd.tmpfiles.rules = lib.lists.forEach [ "" ] (
          x: "d ${cfg.dataDir}/${x} 0775 nextcloud ${hl.group} - -"
        );
        services.nginx.virtualHosts."nix-nextcloud".listen = [
          {
            addr = "127.0.0.1";
            port = 8009;
          }
        ];
        fileSystems."${config.services.nextcloud.home}/data" = {
          device = cfg.dataDir;
          fsType = "none";
          options = [
            "bind"
          ];
        };
        services.nextcloud = {
          enable = true;
          hostName = "nix-nextcloud";
          package = pkgs.nextcloud32;
          database.createLocally = true;
          configureRedis = true;
          maxUploadSize = "16G";
          https = true;
          autoUpdateApps.enable = true;
          extraAppsEnable = true;
          extraApps = with config.services.nextcloud.package.packages.apps; {
            inherit
              calendar
              contacts
              mail
              notes
              tasks
              gpoddersync
              uppush
              ;
          };

          settings = {
            overwriteprotocol = "https";
            default_phone_region = "DE";
          };
          config = {
            dbtype = "pgsql";
            adminuser = cfg.admin.username;
            adminpassFile = cfg.admin.passwordFile;
          };
        };
        services.frp.settings.proxies = [
          {
            name = service;
            type = "tcp";
            localIP = "127.0.0.1";
            localPort = 8009;
            remotePort = 8009;
          }
        ];
      })
      # server
      {
        services.caddy.virtualHosts."${cfg.url}" = {
          useACMEHost = "s.demasi.dev";
          extraConfig = ''
            reverse_proxy http://127.0.0.1:8009
          '';
        };
      };
}
