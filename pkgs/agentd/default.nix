# agentd — Go daemon supervising `pi --mode rpc` children for the nvim agent
# rail. Built from the git+ssh flake input (flake=false: the repo has no
# flake.nix), so `src` is passed in from flake.nix.
{ pkgs, src }:

pkgs.buildGoModule {
  pname = "agentd";
  version = "0-unstable";
  inherit src;
  # Pure stdlib — no external modules, so no vendor step.
  vendorHash = null;
  # Only the daemon binary; the ui/ dir is a separate quickshell app.
  subPackages = [ "." ];
  meta.mainProgram = "agentd";
}
