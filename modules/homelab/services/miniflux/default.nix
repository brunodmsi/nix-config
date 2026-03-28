{
  config,
  lib,
  ...
}:
let
  service = "miniflux";
  hl = config.homelab;
  cfg = hl.services.${service};
  addr = "127.0.0.1";
  port = 8067;
in
{
  options.homelab.services.${service} = {
    enable = lib.mkEnableOption {
      description = "Enable ${service}";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "news.${hl.baseDomain}";
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "Miniflux";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "Minimalist and opinionated feed reader";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "miniflux-light.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Services";
    };
    adminCredentialsFile = lib.mkOption {
      description = "File with admin credentials (ADMIN_USERNAME=x\\nADMIN_PASSWORD=y)";
      type = lib.types.path;
    };
  };

  config = lib.mkIf cfg.enable {
    services.${service} = {
      enable = true;
      adminCredentialsFile = cfg.adminCredentialsFile;
      config = {
        BASE_URL = "https://${cfg.url}";
        CREATE_ADMIN = true;
        LISTEN_ADDR = "${addr}:${toString port}";
        DATABASE_URL = "user=miniflux host=127.0.0.1 dbname=miniflux sslmode=disable";
      };
    };

    services.postgresql.authentication = lib.mkBefore ''
      host miniflux miniflux 127.0.0.1/32 trust
    '';

    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://${addr}:${toString port}
      '';
    };
  };
}
