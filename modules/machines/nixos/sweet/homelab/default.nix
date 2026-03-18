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
    baseDomain = "goose.party";
    cloudflare.dnsCredentialsFile = config.age.secrets.cloudflareDnsApiCredentials.path;
    timeZone = "Europe/Berlin";
    mounts = {
      config = "/persist/opt/services";
      slow = "/mnt/mergerfs_slow";
      fast = "/mnt/cache";
      merged = "/mnt/user";
    };
    frp = {
      enable = false;
    };
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
        s3.url = "https://s3.eu-central-003.backblazeb2.com/notthebee-ojfca-backups";
        s3.environmentFile = config.age.secrets.resticBackblazeEnv.path;
        local.enable = true;
      };
      keycloak = {
        enable = true;
        dbPasswordFile = config.age.secrets.keycloakDbPasswordFile.path;
        oauth2ProxyEnvFile = config.age.secrets.oauth2ProxyEnvFile.path;
      };
      radicale = {
        enable = true;
        passwordFile = config.age.secrets.radicaleHtpasswd.path;
      };
      immich = {
        enable = true;
        mediaDir = "${hl.mounts.fast}/Media/Photos";
      };
      invoiceplane = {
        enable = true;
      };
      homepage = {
        enable = true;
        misc = [
          {
            PiKVM =
              let
                ip = config.homelab.networks.local.lan.reservations.pikvm.Address;
              in
              {
                href = "https://${ip}";
                siteMonitor = "https://${ip}";
                description = "Open-source KVM solution";
                icon = "pikvm.png";
              };
          }
          {
            FritzBox = {
              href = "http://192.168.178.1";
              siteMonitor = "http://192.168.178.1";
              description = "Cable Modem WebUI";
              icon = "avm-fritzbox.png";
            };
          }
          {
            "Immich (Parents)" = {
              href = "https://photos.aria.goose.party";
              description = "Self-hosted photo and video management solution";
              icon = "immich.svg";
              siteMonitor = "";
            };
          }
        ];
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
      jellyseerr = {
        enable = true;
      };
      nextcloud = {
        enable = true;
        admin = {
          username = "notthebee";
          passwordFile = config.age.secrets.nextcloudAdminPassword.path;
        };
      };
      vaultwarden = {
        enable = true;
      };
      microbin = {
        enable = true;
      };
      miniflux = {
        enable = true;
        adminCredentialsFile = config.age.secrets.minifluxAdminPassword.path;
      };
      navidrome = {
        enable = true;
        environmentFile = config.age.secrets.navidromeEnv.path;
      };
      audiobookshelf.enable = true;
      uptime-kuma.enable = true;
      deluge.enable = true;
      wireguard-netns = {
        enable = false;
      };
    };
  };
}
