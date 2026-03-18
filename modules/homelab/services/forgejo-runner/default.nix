{
  lib,
  pkgs,
  config,
  ...
}:
let
  service = "forgejo-runner";
  cfg = config.homelab.services.${service};
  hl = config.homelab;
in
{
  options.homelab.services.${service} = {
    enable = lib.mkEnableOption {
      description = "Enable ${service}";
    };
    runnerName = lib.mkOption {
      type = lib.types.str;
      default = config.networking.hostName;
      example = "runner-1";
    };
    forgejoUrl = lib.mkOption {
      type = lib.types.str;
      example = "git.foo.bar";
    };
    monitoredServices = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "gitea-runner-default"
      ];
    };
    tokenFile = lib.mkOption {
      type = lib.types.str;
      example = lib.literalExpression ''
        pkgs.writeText "token.txt" '''
          TOKEN=foobar
        '''
      '';
    };
    atticTokenFile = lib.mkOption {
      type = lib.types.str;
      example = lib.literalExpression ''
        pkgs.writeText "token.txt" '''
          ATTIC_SERVER_TOKEN_RS256_SECRET_BASE64=foobar
        '''
      '';
    };
    atticUrl = lib.mkOption {
      type = lib.types.str;
      default = "cache.${hl.baseDomain}";
    };
  };
  config = lib.mkIf cfg.enable {
    virtualisation.podman.enable = true;
    services.atticd = {
      enable = true;
      environmentFile = cfg.atticTokenFile;
      settings = {
        listen = "127.0.0.1:8080";
        allowed-hosts = [ cfg.atticUrl ];
        api-endpoint = "https://${cfg.atticUrl}/";
        jwt = { };
      };
    };
    services.caddy.virtualHosts."${cfg.atticUrl}" = {
      useACMEHost = hl.baseDomain;
      extraConfig = ''
        reverse_proxy http://${toString config.services.atticd.settings.listen}
        request_body {
          max_size 50GB
        }
      '';
    };
    services.gitea-actions-runner = {
      package = pkgs.forgejo-runner;
      instances.default = {
        enable = true;
        url = "https://${cfg.forgejoUrl}";
        name = config.networking.hostName;
        tokenFile = cfg.tokenFile;
        hostPackages = with pkgs; [
          nodejs
          buildah
          fuse-overlayfs
          bash
          coreutils
          curl
          gawk
          gitMinimal
          gnused
          wget
        ];
        settings = {
          runner.capacity = 2;
        };
        labels = [
          "nix:docker://git.notthebe.ee/notthebee/nix-ci-builder:latest"
          "debian-latest:docker://node:current-trixie"
          "buildah:docker://quay.io/containers/buildah:latest"
        ];
      };
    };
  };
}
