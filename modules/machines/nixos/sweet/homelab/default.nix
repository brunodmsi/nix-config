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
          "http://grafana.demasi.dev"
          "http://prometheus.demasi.dev"
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
      # Monitoring
      prometheus.enable = true;
      grafana.enable = true;
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

  # Ensure media and backup directories exist with correct ownership
  systemd.tmpfiles.rules = [
    "d /mnt/data1/Downloads 0775 share share - -"
    "d /mnt/data1/Media 0775 share share - -"
    "d /mnt/data1/Media/TV 0775 share share - -"
    "d /mnt/data1/Media/Movies 0775 share share - -"
    "d /mnt/data1/Media/Music 0775 share share - -"
    "d /mnt/data1/Backups 0700 root root - -"
    "d /mnt/data1/Backups/var-lib 0700 root root - -"
    "d /mnt/data1/Backups/persist 0700 root root - -"
  ];

  # Daily backup of critical data to data drive
  systemd.services.backup-to-hdd = {
    description = "Backup critical data to HDD";
    serviceConfig = {
      Type = "oneshot";
      ExecStart = pkgs.writeShellScript "backup-to-hdd" ''
        ${pkgs.rsync}/bin/rsync -a --delete /persist/ /mnt/data1/Backups/persist/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/authelia-main/ /mnt/data1/Backups/var-lib/authelia-main/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/jellyfin/ /mnt/data1/Backups/var-lib/jellyfin/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/sonarr/ /mnt/data1/Backups/var-lib/sonarr/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/radarr/ /mnt/data1/Backups/var-lib/radarr/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/bazarr/ /mnt/data1/Backups/var-lib/bazarr/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/prowlarr/ /mnt/data1/Backups/var-lib/prowlarr/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/deluge/ /mnt/data1/Backups/var-lib/deluge/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/uptime-kuma/ /mnt/data1/Backups/var-lib/uptime-kuma/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/homepage-dashboard/ /mnt/data1/Backups/var-lib/homepage-dashboard/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/grafana/ /mnt/data1/Backups/var-lib/grafana/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/prometheus2/ /mnt/data1/Backups/var-lib/prometheus2/
      '';
    };
  };

  systemd.timers.backup-to-hdd = {
    description = "Daily backup of critical data to HDD";
    wantedBy = [ "timers.target" ];
    timerConfig = {
      OnCalendar = "daily";
      Persistent = true;
      RandomizedDelaySec = "1h";
    };
  };

  environment.systemPackages = [ pkgs.cloudflared ];
}
