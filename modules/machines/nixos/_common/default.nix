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
    bmasi = {
      isNormalUser = true;
      hashedPasswordFile = config.age.secrets.hashedUserPassword.path;
      extraGroups = [ "wheel" ];
    };
    root = {
      hashedPasswordFile = config.age.secrets.hashedUserPassword.path;
    };
  };

  # Use persistent SSH host keys (survive immutable root rollback)
  services.openssh = {
    enable = true;
    settings = {
      PasswordAuthentication = true;
      PermitRootLogin = "yes";
    };
    ports = [ 22 ];
    hostKeys = [
      {
        path = "/persist/ssh/ssh_host_ed25519_key";
        type = "ed25519";
      }
      {
        path = "/persist/ssh/ssh_host_rsa_key";
        type = "rsa";
        bits = 4096;
      }
    ];
  };

  security.sudo = {
    enable = true;
    wheelNeedsPassword = false;
  };

  programs.git.enable = true;
  programs.bash.shellAliases = {
    sudo = "sudo ";
    gpush = "GIT_SSH_COMMAND='ssh -i /persist/ssh/ssh_host_ed25519_key' git push";
    gpull = "GIT_SSH_COMMAND='ssh -i /persist/ssh/ssh_host_ed25519_key' git pull";
    rebuild = "cd /etc/nixos && sudo gpull && sudo nixos-rebuild switch --flake /etc/nixos#sweet";
    age-edit = "cd /tmp/nix-secrets && sudo GIT_SSH_COMMAND='ssh -i /persist/ssh/ssh_host_ed25519_key' git pull && sudo EDITOR=nano nix run github:ryantm/agenix -- -e";
  };

  environment.systemPackages = with pkgs; [
    wget
    eza
    tmux
    rsync
    jq
    ripgrep
  ];
}
