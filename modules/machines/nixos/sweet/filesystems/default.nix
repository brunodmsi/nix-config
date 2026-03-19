# Filesystems config - data drives not yet set up.
# See default.full.nix (TODO: create) for the full mergerfs/snapraid config.
# Current hardware: 1x Kingston NVMe 500G (boot), 2x WD 12TB HDD (not configured yet)
{
  config,
  pkgs,
  ...
}:
{
  programs.fuse.userAllowOther = true;

  environment.systemPackages = with pkgs; [
    gptfdisk
    xfsprogs
    parted
    snapraid
    mergerfs
    mergerfs-tools
  ];

  boot.initrd.systemd.enable = true;
}
