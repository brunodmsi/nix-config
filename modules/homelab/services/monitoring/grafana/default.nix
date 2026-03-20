{
  config,
  lib,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.grafana;
in
{
  options.homelab.services.grafana = {
    enable = lib.mkEnableOption "Grafana dashboards";
    url = lib.mkOption {
      type = lib.types.str;
      default = "grafana.${homelab.baseDomain}";
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "Grafana";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "Platform for data analytics and monitoring";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "grafana.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Observability";
    };
  };

  config = lib.mkIf cfg.enable {
    services.grafana = {
      enable = true;
      settings = {
        server = {
          http_addr = "127.0.0.1";
          http_port = 3000;
          domain = cfg.url;
          root_url = "https://${cfg.url}";
        };
        security = {
          admin_user = "bmasi";
          admin_password = "$__file{/var/lib/grafana/admin-password}";
        };
        analytics.reporting_enabled = false;
      };

      provision = {
        enable = true;
        datasources.settings.datasources = [
          {
            name = "Prometheus";
            type = "prometheus";
            url = "http://localhost:9090";
            isDefault = true;
          }
        ];
      };
    };

    # Create default admin password if it doesn't exist
    systemd.services.grafana.preStart = lib.mkBefore ''
      if [ ! -f /var/lib/grafana/admin-password ]; then
        echo "changeme" > /var/lib/grafana/admin-password
      fi
    '';

    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:3000
      '';
    };
  };
}
