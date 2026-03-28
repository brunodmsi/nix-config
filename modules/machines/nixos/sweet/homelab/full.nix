# Full service configuration. After initial install and boot, replace default.nix with this file.
{
  config,
  lib,
  ...
}:
let
  hl = config.homelab;
in
{
  services.fail2ban-cloudflare = {
    enable = true;
    apiKeyFile = config.age.secrets.cloudflareFirewallApiKey.path;
    zoneId = "5a125e72bca5869bfb929db157d89d96";
  };
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
    samba = {
      enable = true;
      passwordFile = config.age.secrets.sambaPassword.path;
      shares = {
        Backups = {
          path = "${hl.mounts.merged}/Backups";
        };
        Documents = {
          path = "${hl.mounts.fast}/Documents";
        };
        Media = {
          path = "${hl.mounts.merged}/Media";
        };
        Music = {
          path = "${hl.mounts.fast}/Media/Music";
        };
        Misc = {
          path = "${hl.mounts.merged}/Misc";
        };
        TimeMachine = {
          path = "${hl.mounts.fast}/TimeMachine";
          "fruit:time machine" = "yes";
        };
        YoutubeArchive = {
          path = "${hl.mounts.merged}/YoutubeArchive";
        };
        YoutubeCurrent = {
          path = "${hl.mounts.fast}/YoutubeCurrent";
        };
      };
    };
    services = {
      enable = true;
      slskd = {
        enable = true;
        environmentFile = config.age.secrets.slskdEnvironmentFile.path;
      };
      backup = {
        enable = true;
        passwordFile = config.age.secrets.resticPassword.path;
        s3.enable = true;
        s3.url = "https://s3.eu-central-003.backblazeb2.com/bmasi-ojfca-backups";
        s3.environmentFile = config.age.secrets.resticBackblazeEnv.path;
        local.enable = true;
      };
      keycloak = {
        enable = true;
        dbPasswordFile = config.age.secrets.keycloakDbPasswordFile.path;
        oauth2ProxyEnvFile = config.age.secrets.oauth2ProxyEnvFile.path;
      };
      immich = {
        enable = true;
        mediaDir = "${hl.mounts.fast}/Media/Photos";
      };
      homepage = {
        enable = true;
        misc = [ ];
      };
      jellyfin.enable = true;
      paperless = {
        enable = true;
        passwordFile = config.age.secrets.paperlessPassword.path;
      };
      sabnzbd.enable = true;
      sonarr.enable = true;
      radarr.enable = true;
      bazarr.enable = true;
      prowlarr.enable = true;
      jellyseerr.enable = true;
      nextcloud = {
        enable = true;
        admin = {
          username = "bmasi";
          passwordFile = config.age.secrets.nextcloudAdminPassword.path;
        };
      };
      vaultwarden.enable = true;
      microbin.enable = true;
      miniflux = {
        enable = true;
        adminCredentialsFile = config.age.secrets.minifluxAdminPassword.path;
      };
      nextflux.enable = true;
      uptime-kuma.enable = true;
      deluge.enable = true;
      wireguard-netns.enable = false;
    };
  };
}
