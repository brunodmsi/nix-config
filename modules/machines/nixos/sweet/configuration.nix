# Minimal config for initial install. See configuration.full.nix for the complete version.
{
  config,
  lib,
  pkgs,
  ...
}:
{
  hardware = {
    enableRedistributableFirmware = true;
    cpu.intel.updateMicrocode = true;
    graphics = {
      enable = true;
      extraPackages = with pkgs; [
        intel-media-driver
        intel-vaapi-driver
        libva-vdpau-driver
        intel-compute-runtime
        vpl-gpu-rt
      ];
    };
  };
  boot = {
    zfs.forceImportRoot = true;
    kernelParams = [
      "pcie_aspm=force"
      "consoleblank=60"
      "acpi_enforce_resources=lax"
    ];
    kernelModules = [
      "coretemp"
    ];
  };

  networking = {
    useDHCP = true;
    hostName = "sweet";
    hostId = "0730ae51";
    firewall = {
      enable = true;
      allowPing = true;
    };
  };

  # UPDATE THESE with your actual disk IDs from `ls /dev/disk/by-id/`
  zfs-root = {
    boot = {
      partitionScheme = {
        biosBoot = "-part4";
        efiBoot = "-part2";
        bootPool = "-part1";
        rootPool = "-part3";
      };
      bootDevices = [
        "ata-Samsung_SSD_870_EVO_250GB_S6PENL0T902873K"
        "ata-Samsung_SSD_870_EVO_250GB_S6PENL0T905657B"
      ];
      immutable = true;
      availableKernelModules = [
        "uhci_hcd"
        "ehci_pci"
        "ahci"
        "sd_mod"
        "sr_mod"
      ];
      removableEfi = true;
    };
  };

  imports = [
    ../../../misc/zfs-root
    ./filesystems
    ./homelab
  ];

  virtualisation.docker.storageDriver = "overlay2";

  environment.systemPackages = with pkgs; [
    pciutils
    glances
    hdparm
    smartmontools
    git
  ];
}
