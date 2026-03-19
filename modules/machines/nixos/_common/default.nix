# Minimal common config for initial install. See default.full.nix for the complete version.
{
  config,
  pkgs,
  lib,
  ...
}:
{
  system.stateVersion = "22.11";

  imports = [
    ./filesystems
    ./nix
  ];

  time.timeZone = "Europe/Berlin";

  users.users = {
    notthebee = {
      isNormalUser = true;
      initialPassword = "changeme";
      extraGroups = [ "wheel" ];
    };
    root = {
      initialPassword = "changeme";
    };
  };

  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
    ports = [ 22 ];
  };

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  programs.git.enable = true;

  environment.systemPackages = with pkgs; [
    wget
    eza
    tmux
    rsync
    jq
    ripgrep
  ];
}
