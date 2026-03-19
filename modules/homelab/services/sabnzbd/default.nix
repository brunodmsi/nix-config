{ config, lib, pkgs, ... }:
let
  service = "sabnzbd";
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
      default = "sabnzbd.${homelab.baseDomain}";
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "SABnzbd";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "The free and easy binary newsreader";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "sabnzbd.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Downloads";
    };
  };
  config = lib.mkIf cfg.enable {
    services.${service} = {
      enable = true;
      user = homelab.user;
      group = homelab.group;
    };
    services.caddy.virtualHosts."http://${cfg.url}" = {
      extraConfig = ''
        reverse_proxy http://127.0.0.1:8080
      '';
    };

    systemd.services.sabnzbd = lib.mkIf homelab.services.wireguard-netns.enable {
      bindsTo = [ "netns@${ns}.service" ];
      requires = [
        "network-online.target"
        "${ns}.service"
      ];
      serviceConfig.NetworkNamespacePath = "/var/run/netns/${ns}";
    };

    systemd.sockets."sabnzbd-proxy" = lib.mkIf homelab.services.wireguard-netns.enable {
      enable = true;
      description = "Socket for Proxy to SABnzbd WebUI";
      listenStreams = [ "8080" ];
      wantedBy = [ "sockets.target" ];
    };
    systemd.services."sabnzbd-proxy" = lib.mkIf homelab.services.wireguard-netns.enable {
      enable = true;
      description = "Proxy to SABnzbd in Network Namespace";
      requires = [ "sabnzbd.service" "sabnzbd-proxy.socket" ];
      after = [ "sabnzbd.service" "sabnzbd-proxy.socket" ];
      unitConfig.JoinsNamespaceOf = "sabnzbd.service";
      serviceConfig = {
        User = homelab.user;
        Group = homelab.group;
        ExecStart = "${pkgs.systemd}/lib/systemd/systemd-socket-proxyd --exit-idle-time=5min 127.0.0.1:8080";
        PrivateNetwork = "yes";
      };
    };
  };

}
