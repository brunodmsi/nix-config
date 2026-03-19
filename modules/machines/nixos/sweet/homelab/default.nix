# Service configuration - enabling incrementally.
# See homelab/full.nix for the complete service configuration.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  homelab = {
    enable = true;
    baseDomain = "demasi.dev";
    cloudflare.dnsCredentialsFile = "/persist/secrets/cloudflare-dns";
    timeZone = "Europe/Berlin";
    mounts = {
      config = "/persist/opt/services";
      slow = "/mnt/mergerfs_slow";
      fast = "/mnt/cache";
      merged = "/mnt/user";
    };
    frp.enable = false;
    samba.enable = false;
    services = {
      enable = true;
      uptime-kuma.enable = true;
      jellyfin.enable = true;
      homepage = {
        enable = true;
        misc = [ ];
      };
    };
  };

  # Cloudflare Tunnel — token-based (remotely managed via dashboard)
  systemd.services.cloudflared-tunnel = {
    description = "Cloudflare Tunnel";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = pkgs.writeShellScript "cloudflared-run" ''
        exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate --protocol http2 run --token $(cat /persist/secrets/cloudflare-tunnel-token)
      '';
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  environment.systemPackages = [ pkgs.cloudflared ];
}
