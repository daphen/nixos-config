let
  flake = builtins.getFlake "path:/nix/store/vkqdmnh9dpw5saffgqppdxvyq86w8fc6-source";
  base = flake.nixosConfigurations.proart;
in
base.extendModules {
  modules = [
    ({ lib, ... }: {
      home-manager.users.daphen.home.packages = lib.mkForce (
        map (package:
          if lib.getName package == "cockpit-qs" then
            builtins.storePath /nix/store/7lcbhk7pd0lz6v4yfs3acnzlz54jnqi8-cockpit-qs
          else package
        ) base.config.home-manager.users.daphen.home.packages
      );
    })
  ];
}
