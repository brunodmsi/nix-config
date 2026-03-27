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
      default = "/mnt/data1/Nextcloud";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "cloud.${hl.baseDomain}";
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
      default = "bmasi";
    };
    admin.passwordFile = lib.mkOption {
      type = lib.types.path;
    };
  };

  config = lib.mkIf cfg.enable {
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0775 nextcloud ${hl.group} - -"
    ];

    # Nginx listens internally, Caddy proxies externally
    services.nginx.virtualHosts."nix-nextcloud".listen = [
      {
        addr = "127.0.0.1";
        port = 8009;
      }
    ];

    # Bind mount data to the data drive
    fileSystems."${config.services.nextcloud.home}/data" = {
      device = cfg.dataDir;
      fsType = "none";
      options = [ "bind" ];
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
          ;
      };
      settings = {
        overwriteprotocol = "https";
        overwritecliurl = "https://${cfg.url}";
        default_phone_region = "BR";
        trusted_proxies = [ "127.0.0.1" ];
        trusted_domains = [ cfg.url ];
        overwritehost = cfg.url;
      };
      config = {
        dbtype = "pgsql";
        adminuser = cfg.admin.username;
        adminpassFile = cfg.admin.passwordFile;
      };
    };

    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:8009 {
          header_up X-Forwarded-Proto "https"
          header_up X-Forwarded-Port "443"
        }
      '';
    };
  };
}
