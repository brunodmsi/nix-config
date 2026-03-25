{ ... }:
{
  # Ensure the persist content dir exists (not created by the snapraid module)
  systemd.tmpfiles.rules = [
    "d /persist/snapraid 0755 root root -"
  ];

  services.snapraid = {
    enable = true;
    parityFiles = [
      "/mnt/parity1/snapraid.parity"
    ];
    contentFiles = [
      "/mnt/data1/snapraid.content"
      "/persist/snapraid/snapraid.content"
    ];
    dataDisks = {
      d1 = "/mnt/data1";
    };
  };
}
