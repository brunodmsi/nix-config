{
  config,
  lib,
  ...
}:
let
  homelab = config.homelab;
  cfg = homelab.services.prometheus;
in
{
  options.homelab.services.prometheus = {
    enable = lib.mkEnableOption "Prometheus monitoring";
    url = lib.mkOption {
      type = lib.types.str;
      default = "prometheus.${homelab.baseDomain}";
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "Prometheus";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "Monitoring system & time series database";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "prometheus.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Observability";
    };
  };

  config = lib.mkIf cfg.enable {
    services.prometheus = {
      enable = true;
      port = 9090;
      retentionTime = "30d";

      exporters = {
        node = {
          enable = true;
          port = 9100;
          enabledCollectors = [
            "systemd"
            "processes"
            "filesystem"
            "diskstats"
            "meminfo"
            "netdev"
            "cpu"
            "loadavg"
            "hwmon"
          ];
        };
      };

      scrapeConfigs = [
        {
          job_name = "node";
          static_configs = [
            { targets = [ "localhost:9100" ]; }
          ];
          scrape_interval = "15s";
        }
        {
          job_name = "prometheus";
          static_configs = [
            { targets = [ "localhost:9090" ]; }
          ];
          scrape_interval = "15s";
        }
      ];
    };

    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:9090
      '';
    };
  };
}
