{ config, lib, pkgs, ... }:
let
  service = "prowlarr";
  cfg = config.homelab.services.${service};
  homelab = config.homelab;
  ns = homelab.services.wireguard-netns.namespace;
in
{
  options.homelab.services.${service} = {
    enable = lib.mkEnableOption {
      description = "Enable ${service}";
    };
    configDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/${service}";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "${service}.${homelab.baseDomain}";
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "Prowlarr";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "PVR indexer";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "prowlarr.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Arr";
    };
  };
  config = lib.mkIf cfg.enable {
    services.${service} = {
      enable = true;
    };
    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:9696
      '';
    };

    systemd.services.prowlarr = lib.mkIf homelab.services.wireguard-netns.enable {
      bindsTo = [ "netns@${ns}.service" ];
      requires = [
        "network-online.target"
        "${ns}.service"
      ];
      serviceConfig.NetworkNamespacePath = "/var/run/netns/${ns}";
    };

    systemd.sockets."prowlarr-proxy" = lib.mkIf homelab.services.wireguard-netns.enable {
      enable = true;
      description = "Socket for Proxy to Prowlarr WebUI";
      listenStreams = [ "9696" ];
      wantedBy = [ "sockets.target" ];
    };
    systemd.services."prowlarr-proxy" = lib.mkIf homelab.services.wireguard-netns.enable {
      enable = true;
      description = "Proxy to Prowlarr in Network Namespace";
      requires = [ "prowlarr.service" "prowlarr-proxy.socket" ];
      after = [ "prowlarr.service" "prowlarr-proxy.socket" ];
      unitConfig.JoinsNamespaceOf = "prowlarr.service";
      serviceConfig = {
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5min 127.0.0.1:9696";
        PrivateNetwork = "yes";
      };
    };
  };
}
