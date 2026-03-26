# Storage: 2x WD 12TB HDD (1 data + 1 parity via snapraid)
# Format after first boot:
#   mkfs.xfs -L Data1 /dev/disk/by-id/ata-WDC_WD120EFGX-68CPHN0_WD-B00XRDHD
#   mkfs.xfs -L Parity1 /dev/disk/by-id/ata-WDC_WD120EFGX-68CPHN0_WD-B00XSP6D
{
  config,
  pkgs,
  ...
}:
let
  hl = config.homelab;
in
{
  imports = [
    ./snapraid.nix
  ];

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

  fileSystems."/mnt/data1" = {
    device = "/dev/disk/by-label/Data1";
    fsType = "xfs";
    options = [ "nofail" "nosuid" "nodev" "noexec" ];
  };

  fileSystems."/mnt/parity1" = {
    device = "/dev/disk/by-label/Parity1";
    fsType = "xfs";
    options = [ "nofail" "nosuid" "nodev" "noexec" ];
  };
}
