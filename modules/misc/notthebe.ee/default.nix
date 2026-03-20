{
  config,
  ...
}:
let
  domain = "notthebe.ee";
in
{
  systemd.tmpfiles.rules = [
    "d /var/www 0775 deploy deploy - -"
    "d /var/www/notthebe.ee 0775 deploy deploy - -"
  ];

  services.caddy = {
    enable = true;
    email = "moe@notthebe.ee";
    user = "deploy";
    group = "deploy";
    virtualHosts."${domain}" = {
      extraConfig = ''
        file_server
        root ${config.users.users.deploy.home}
      '';
    };
  };

  users.groups = {
    deploy = { };
  };
  users.users.deploy = {
    isNormalUser = true;
    home = "/var/www/notthebe.ee";
    group = "deploy";
    openssh.authorizedKeys.keys = [
      "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIFZlmu/rT4l97r9qi15rgvNTDcG6GS4qSOniBOhCCaNh git@git.notthebe.ee"
    ];
  };

  networking.firewall.allowedTCPPorts = [
    80
    443
  ];

}
