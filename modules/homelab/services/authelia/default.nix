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
    oidc = {
      enable = lib.mkEnableOption "OIDC identity provider";
      hmacSecretFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to OIDC HMAC secret file";
      };
      issuerPrivateKeyFile = lib.mkOption {
        type = lib.types.path;
        description = "Path to OIDC issuer RSA private key file";
      };
      clients = lib.mkOption {
        type = lib.types.listOf (lib.types.submodule {
          options = {
            client_id = lib.mkOption { type = lib.types.str; };
            client_name = lib.mkOption { type = lib.types.str; };
            client_secret_hash_file = lib.mkOption {
              type = lib.types.path;
              description = "Path to file containing the pbkdf2-hashed client secret";
            };
            authorization_policy = lib.mkOption {
              type = lib.types.str;
              default = "two_factor";
            };
            redirect_uris = lib.mkOption { type = lib.types.listOf lib.types.str; };
            scopes = lib.mkOption {
              type = lib.types.listOf lib.types.str;
              default = [ "openid" "profile" "email" ];
            };
          };
        });
        default = [ ];
      };
    };
  };

  config = lib.mkIf cfg.enable {
    services.authelia.instances.main = {
      enable = true;
      secrets = {
        jwtSecretFile = cfg.jwtSecretFile;
        storageEncryptionKeyFile = cfg.storageEncryptionKeyFile;
        sessionSecretFile = cfg.sessionSecretFile;
      } // lib.optionalAttrs cfg.oidc.enable {
        oidcHmacSecretFile = cfg.oidc.hmacSecretFile;
        oidcIssuerPrivateKeyFile = cfg.oidc.issuerPrivateKeyFile;
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

        identity_providers = lib.mkIf cfg.oidc.enable {
          oidc = {
            issuer = "https://${autheliaUrl}";
            clients = map (c: {
              inherit (c) client_id client_name authorization_policy redirect_uris scopes;
              client_secret = "{{ secret \"${c.client_secret_hash_file}\" }}";
              token_endpoint_auth_method = "client_secret_post";
              grant_types = [ "authorization_code" ];
              response_types = [ "code" ];
            }) cfg.oidc.clients;
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
