{ config, lib, ... }:
{
  services.snapraid.exclude = [
    "*.unrecoverable"
    "/tmp/"
    "/lost+found/"
    "/Media/Movies/"
    "/Media/TV/"
    "/Media/Music/"
    "/Downloads/"
  ];

  systemd.services = lib.attrsets.optionalAttrs (config.services.snapraid.enable) {
    snapraid-sync = {
      onSuccess = [ "wa-notify@snapraid-sync.service" ];
      onFailure = [ "wa-notify@snapraid-sync.service" ];
      serviceConfig = {
        RestrictNamespaces = lib.mkForce false;
        RestrictAddressFamilies = lib.mkForce "";
      };
    };
    snapraid-scrub = {
      onSuccess = [ "wa-notify@snapraid-scrub.service" ];
      onFailure = [ "wa-notify@snapraid-scrub.service" ];
      serviceConfig = {
        RestrictNamespaces = lib.mkForce false;
        RestrictAddressFamilies = lib.mkForce "";
      };
    };
  };
}
