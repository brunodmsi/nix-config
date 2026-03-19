# Service configuration - enabling incrementally.
# See homelab/full.nix for the complete service configuration.
{
  config,
  lib,
  ...
}:
{
  homelab = {
    enable = true;
    baseDomain = "s.demasi.dev";
    cloudflare.dnsCredentialsFile = "/dev/null"; # placeholder until agenix is set up
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
    };
  };
}
