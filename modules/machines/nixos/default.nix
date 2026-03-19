# Minimal builder for initial install. See default.full.nix for the complete version.
{
  lib,
  self,
  ...
}:
let
  entries = builtins.attrNames (builtins.readDir ./.);
  configs = builtins.filter (dir: builtins.pathExists (./. + "/${dir}/configuration.nix")) entries;
in
{

  flake.nixosConfigurations =
    lib.listToAttrs (
      builtins.map (
        name:
        lib.nameValuePair name (
          self.inputs.nixpkgs.lib.nixosSystem {
            system = "x86_64-linux";
            specialArgs = {
              inherit (self) inputs;
              self = {
                nixosModules = self.nixosModules;
              };
            };

            modules = [
              ../../homelab
              ../../misc/email
              ../../misc/tg-notify
              ../../misc/mover
              ../../misc/withings2intervals
              self.inputs.agenix.nixosModules.default
              self.inputs.autoaspm.nixosModules.default
              (./. + "/_common/default.nix")
              (./. + "/${name}/configuration.nix")
            ];
          }
        )
      ) configs
    );
}
