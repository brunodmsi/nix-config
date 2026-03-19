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
    cloudflare.dnsCredentialsFile = config.age.secrets.cloudflareDnsApiCredentials.path;
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
      authelia = {
        enable = true;
        jwtSecretFile = config.age.secrets.autheliaJwtSecret.path;
        sessionSecretFile = config.age.secrets.autheliaSessionSecret.path;
        storageEncryptionKeyFile = config.age.secrets.autheliaStorageEncryptionKey.path;
        usersFile = config.age.secrets.autheliaUsersFile.path;
        protectedServices = [
          "http://homepage.demasi.dev"
          "http://uptime.demasi.dev"
          "http://deluge.demasi.dev"
        ];
      };
      # Arr stack
      sonarr.enable = true;
      radarr.enable = true;
      bazarr.enable = true;
      prowlarr.enable = true;
      jellyseerr.enable = true;
      # Download clients (run in VPN namespace)
      deluge.enable = true;
      # VPN namespace
      wireguard-netns = {
        enable = true;
        configFile = config.age.secrets.mullvadWireguard.path;
      };
    };
  };

  # Cloudflare Tunnel — token-based, routes managed in dashboard
  systemd.services.cloudflared-tunnel = {
    description = "Cloudflare Tunnel";
    after = [ "network-online.target" ];
    wants = [ "network-online.target" ];
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      ExecStart = pkgs.writeShellScript "cloudflared-run" ''
        exec ${pkgs.cloudflared}/bin/cloudflared tunnel --no-autoupdate --protocol http2 run --token $(cat ${config.age.secrets.cloudflareTunnelToken.path})
      '';
      Restart = "on-failure";
      RestartSec = 5;
    };
  };

  environment.systemPackages = [ pkgs.cloudflared ];
}
