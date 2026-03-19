# Minimal config for initial install. Enable services after booting on real disk.
# See homelab/full.nix for the complete service configuration.
{
  config,
  lib,
  ...
}:
let
  hl = config.homelab;
in
{
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
    frp.enable = false;
    samba.enable = false;
    services = {
      enable = false;
    };
  };
}
