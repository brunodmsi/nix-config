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
          "http://agent.demasi.dev"
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
      # Photos
      immich = {
        enable = true;
        mediaDir = "/mnt/data1/Media/Photos";
      };
      # Nextcloud
      nextcloud = {
        enable = true;
        admin.passwordFile = config.age.secrets.nextcloudAdminPassword.path;
      };
      # Documents
      paperless = {
        enable = true;
        passwordFile = config.age.secrets.paperlessPassword.path;
      };
      # AI Agent
      openfang = {
        enable = true;
        agentName = "Fluzy";
        systemPrompt = ''
          You are Fluzy, a friendly and fun personal assistant on WhatsApp.
          You help the people you talk to by taking their requests and fulfilling them.
          Be conversational, warm, and a little playful — keep your responses concise since this is WhatsApp.
          You can use emojis to make the conversation more lively.
          IMPORTANT: Always end every single response with the Hungary flag emoji 🇭🇺
        '';
        llmProvider = "anthropic";
        llmModel = "claude-haiku-4-5-20251001";
        apiKeyEnvVar = "ANTHROPIC_API_KEY";
        apiKeyFile = config.age.secrets.openfangApiKey.path;
        allowedSendersFile = config.age.secrets.whatsappAllowedSenders.path;
        jellyseerr = {
          enable = true;
          apiKeyFile = config.age.secrets.jellyseerrApiKey.path;
        };
      };
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
    "d /mnt/data1/Media/Photos 0775 immich share - -"
    "d /mnt/data1/Documents 0775 share share - -"
    "d /mnt/data1/Documents/Paperless 0775 share share - -"
    "d /mnt/data1/Documents/Paperless/Documents 0775 share share - -"
    "d /mnt/data1/Documents/Paperless/Import 0775 share share - -"
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
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/nextcloud/ /mnt/data1/Backups/var-lib/nextcloud/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/postgresql/ /mnt/data1/Backups/var-lib/postgresql/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/immich/ /mnt/data1/Backups/var-lib/immich/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/paperless/ /mnt/data1/Backups/var-lib/paperless/
        ${pkgs.rsync}/bin/rsync -a --delete /var/lib/openfang/ /mnt/data1/Backups/var-lib/openfang/
        ${pkgs.rsync}/bin/rsync -a --delete /persist/openfang/ /mnt/data1/Backups/persist/openfang/
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
