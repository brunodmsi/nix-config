{
  config,
  lib,
  ...
}:
let
  service = "nextflux";
  hl = config.homelab;
  cfg = hl.services.${service};
  minifluxCfg = hl.services.miniflux;
  port = 3000;
in
{
  options.homelab.services.${service} = {
    enable = lib.mkEnableOption {
      description = "Enable ${service}";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "reader.${hl.baseDomain}";
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "Nextflux";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "Modern frontend for Miniflux RSS reader";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "miniflux-light.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Services";
    };
    minifluxUrl = lib.mkOption {
      type = lib.types.str;
      default = "https://${minifluxCfg.url}";
      description = "Public URL of the Miniflux instance for API access";
    };
  };

  config = lib.mkIf cfg.enable {
    virtualisation.oci-containers.containers.${service} = {
      image = "ghcr.io/electh/nextflux:latest";
      ports = [ "127.0.0.1:${toString port}:${toString port}" ];
      environment = {
        NEXT_PUBLIC_API_ENDPOINT = cfg.minifluxUrl;
      };
      extraOptions = [
        "--pull=newer"
      ];
    };

    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:${toString port}
      '';
    };
  };
}
