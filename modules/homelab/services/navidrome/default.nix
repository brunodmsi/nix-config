{
  config,
  lib,
  ...
}:
let
  service = "navidrome";
  hl = config.homelab;
  cfg = hl.services.${service};
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
    musicDir = lib.mkOption {
      type = lib.types.str;
      default = "${hl.mounts.fast}/Media/Music/Library";
    };
    url = lib.mkOption {
      type = lib.types.str;
      default = "music.goose.party";
    };
    environmentFile = lib.mkOption {
      type = lib.types.path;
      example = lib.literalExpression ''
        pkgs.writeText "navidrome-env" '''
          ND_LASTFM_APIKEY=abcabc
          ND_LASTFM_SECRET=abcabc
        '''
      '';
    };
    homepage.name = lib.mkOption {
      type = lib.types.str;
      default = "Navidrome";
    };
    homepage.description = lib.mkOption {
      type = lib.types.str;
      default = "Self-hosted music streaming service";
    };
    homepage.icon = lib.mkOption {
      type = lib.types.str;
      default = "navidrome.svg";
    };
    homepage.category = lib.mkOption {
      type = lib.types.str;
      default = "Media";
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
      (lib.mkIf cfg.enable {
        systemd.tmpfiles.rules = [
          "d ${cfg.musicDir} 0775 ${hl.user} ${hl.group} - -"
        ];
        systemd.services.navidrome.serviceConfig.EnvironmentFile = lib.mkIf (
          cfg.environmentFile != null
        ) cfg.environmentFile;
        services.${service} = {
          enable = true;
          user = hl.user;
          group = hl.group;
          settings = {
            MusicFolder = "${cfg.musicDir}";
            DefaultDownsamplingFormat = "aac";
          };
        };
        services.frp.settings.proxies = [
          {
            name = service;
            type = "tcp";
            localIP = config.services.${service}.settings.Address;
            localPort = config.services.${service}.settings.Port;
            remotePort = config.services.${service}.settings.Port;
          }
        ];
      })
      # server
      {
        services.caddy.virtualHosts."${cfg.url}" = {
          useACMEHost = "goose.party";
          extraConfig = ''
            reverse_proxy http://${config.services.${service}.settings.Address}:${
              toString config.services.${service}.settings.Port
            }
          '';
        };
      };
}
