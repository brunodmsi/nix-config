{
  config,
  lib,
  pkgs,
  ...
}:
let
  service = "authelia";
  cfg = config.homelab.services.${service};
  homelab = config.homelab;
  autheliaUrl = "auth.${homelab.baseDomain}";
in
{
  options.homelab.services.${service} = {
    enable = lib.mkEnableOption {
      description = "Enable Authelia authentication";
    };
    jwtSecretFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to JWT secret file";
    };
    sessionSecretFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to session secret file";
    };
    storageEncryptionKeyFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to storage encryption key file";
    };
    usersFile = lib.mkOption {
      type = lib.types.path;
      description = "Path to users database file (age-encrypted, decrypted by agenix)";
    };
    protectedServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ ];
      description = "List of Caddy virtual host names to protect with Authelia";
    };
  };

  config = lib.mkIf cfg.enable {
    services.authelia.instances.main = {
      enable = true;
      secrets = {
        jwtSecretFile = cfg.jwtSecretFile;
        storageEncryptionKeyFile = cfg.storageEncryptionKeyFile;
        sessionSecretFile = cfg.sessionSecretFile;
      };
      settings = {
        theme = "dark";
        default_2fa_method = "totp";

        server = {
          address = "tcp://127.0.0.1:9091";
        };

        session = {
          name = "authelia_session";
          expiration = "12h";
          inactivity = "45m";
          remember_me = "1M";
          cookies = [
            {
              domain = homelab.baseDomain;
              authelia_url = "https://${autheliaUrl}";
            }
          ];
        };

        authentication_backend = {
          file = {
            path = cfg.usersFile;
            password = {
              algorithm = "argon2id";
            };
          };
        };

        access_control = {
          default_policy = "two_factor";
        };

        storage = {
          local = {
            path = "/var/lib/authelia-main/db.sqlite3";
          };
        };

        notifier = {
          filesystem = {
            filename = "/var/lib/authelia-main/notifications.txt";
          };
        };
      };
    };

    # Caddy: Authelia vhost + forward auth on protected services
    services.caddy.virtualHosts = lib.mkMerge ([
      {
        "http://${autheliaUrl}" = {
          extraConfig = ''
            reverse_proxy http://127.0.0.1:9091
          '';
        };
      }
    ] ++ map (vhost: {
        "${vhost}" = {
          extraConfig = lib.mkBefore ''
            forward_auth http://127.0.0.1:9091 {
              uri /api/authz/forward-auth
              copy_headers Remote-User Remote-Groups Remote-Name Remote-Email
              header_up X-Forwarded-Proto "https"
            }
          '';
        };
      }) cfg.protectedServices
    );
  };
}
