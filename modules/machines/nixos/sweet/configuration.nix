# Minimal config for initial install. See configuration.full.nix for the complete version.
{
  config,
  lib,
  pkgs,
  inputs,
  ...
}:
{
  hardware = {
    enableRedistributableFirmware = true;
    cpu.amd.updateMicrocode = true;
    graphics = {
      enable = true;
    };
    nvidia = {
      open = false;
      modesetting.enable = true;
    };
  };
  services.xserver.videoDrivers = [ "nvidia" ];
  hardware.nvidia-container-toolkit.enable = true;
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
        "nvme-KINGSTON_SNV3S500G_50026B76878184EA"
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

  age = {
    identityPaths = [ "/persist/ssh/ssh_host_ed25519_key" ];
    secrets = {
      cloudflareDnsApiCredentials.file = "${inputs.secrets}/cloudflareDnsApiCredentials.age";
      cloudflareTunnelToken.file = "${inputs.secrets}/cloudflareTunnelToken.age";
      autheliaJwtSecret = {
        file = "${inputs.secrets}/autheliaJwtSecret.age";
        owner = "authelia-main";
      };
      autheliaSessionSecret = {
        file = "${inputs.secrets}/autheliaSessionSecret.age";
        owner = "authelia-main";
      };
      autheliaStorageEncryptionKey = {
        file = "${inputs.secrets}/autheliaStorageEncryptionKey.age";
        owner = "authelia-main";
      };
      autheliaUsersFile = {
        file = "${inputs.secrets}/autheliaUsersFile.age";
        owner = "authelia-main";
      };
      mullvadWireguard.file = "${inputs.secrets}/mullvadWireguard.age";
      nextcloudAdminPassword.file = "${inputs.secrets}/nextcloudAdminPassword.age";
      hashedUserPassword.file = "${inputs.secrets}/hashedUserPassword.age";
      openfangApiKey.file = "${inputs.secrets}/openfangApiKey.age";
      whatsappAllowedSenders.file = "${inputs.secrets}/whatsappAllowedSenders.age";
      paperlessPassword.file = "${inputs.secrets}/paperlessPassword.age";
    };
  };

  # Skip flaky psycopg tests that break paperless build
  nixpkgs.config.packageOverrides = pkgs: {
    python313Packages = pkgs.python313Packages.override {
      overrides = _self: super: {
        psycopg = super.psycopg.overrideAttrs (_: {
          doCheck = false;
        });
      };
    };
  };

  # Allow running dynamically linked binaries (e.g. OpenFang)
  programs.nix-ld.enable = true;

  environment.systemPackages = with pkgs; [
    pciutils
    glances
    hdparm
    smartmontools
    git
  ];
}
