{
  config,
  lib,
  pkgs,
  ...
}:
let
  service = "keycloak";
  cfg = config.homelab.services.${service};
in
{
  options.homelab.services.${service} = {
    enable = lib.mkEnableOption {
      description = "Enable ${service}";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "login.demasi.dev";
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "Keycloak";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "Open Source Identity and Access Management";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "keycloak.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Services";
    };
    dbPasswordFile = lib.mkOption {
      type = lib.types.path;
    };
    oauth2ProxyEnvFile = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression ''
        pkgs.writeText "oauth2proxy-envfile" '''
          OAUTH2_PROXY_CLIENT_SECRET=foobar
          OAUTH2_PROXY_COOKIE_SECRET=barfoo
        '''
      '';
    };
    role = lib.mkOption {
      type = lib.types.enum [
        "client"
        "server"
      ];
      default = "client";
    };
  };
  config =
    let
      mkIfElse =
        p: yes: no:
        lib.mkMerge [
          (lib.mkIf p yes)
          (lib.mkIf (!p) no)
        ];
    in
    mkIfElse (cfg.role == "client")
      # client
      (lib.mkIf cfg.enable {
        environment.systemPackages = [
          pkgs.keycloak
          pkgs.custom_keycloak_themes.bmasi
        ];
        nixpkgs.overlays = [
          (_final: _prev: {
            custom_keycloak_themes = {
              bmasi = pkgs.callPackage ./theme.nix { };
            };
          })
        ];
        services.oauth2-proxy = {
          enable = true;
          keyFile = cfg.oauth2ProxyEnvFile;
          reverseProxy = true;
          provider = "keycloak-oidc";
          oidcIssuerUrl = "https://${cfg.url}/realms/master";
          cookie = {
            expire = "672h";
            refresh = "1h";
            secure = true;
            httpOnly = true;
            domain = lib.strings.removePrefix "login" cfg.url;
          };
          httpAddress = "127.0.0.1:4192";
          clientID = "oauth2-proxy";
          upstream = [ "http://[::]:0/" ];
          scope = "openid profile email";
          email.domains = [ "*" ];
          extraConfig = {
            skip-provider-button = true;
            whitelist-domain = [ ("*" + (lib.strings.removePrefix "login" cfg.url)) ];
          };
        };
        services.${service} = {
          enable = true;
          initialAdminPassword = "schneke123";
          database.passwordFile = cfg.dbPasswordFile;
          themes = {
            bmasi = pkgs.custom_keycloak_themes.bmasi;
          };
          settings = {
            spi-theme-static-max-age = "-1";
            spi-theme-cache-themes = false;
            spi-theme-cache-templates = false;
            http-port = 8821;
            hostname = cfg.url;
            hostname-strict = false;
            hostname-strict-https = false;
            proxy-headers = "xforwarded";
            http-enabled = true;
          };
        };
        services.frp.settings.proxies = [
          {
            name = service;
            type = "tcp";
            localIP = "127.0.0.1";
            localPort = 8821;
            remotePort = 8821;
          }
          {
            name = "oauth2-proxy";
            type = "tcp";
            localIP = "127.0.0.1";
            localPort = 4192;
            remotePort = 4192;
          }

        ];
      })
      # server
      {
        services.caddy.virtualHosts."${cfg.url}" = {
          useACMEHost = "demasi.dev";
          extraConfig = ''
            reverse_proxy http://127.0.0.1:8821
            handle /oauth2/* {
              reverse_proxy http://127.0.0.1:4192 {
                header_up X-Real-IP {remote_host}
                header_up X-Forwarded-Uri {uri}
              }
            }
          '';
        };
      };

}
