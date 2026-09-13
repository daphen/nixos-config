# Hyprland canvas experiment

The shipping package remains `nix build path:.`. Its only Hyprland source
change is `whole-canvas-camera.patch`; the Aquamarine nested-configure patch is
applied independently by the overlay.

## Incremental camera loop

```bash
./dev bootstrap                         # once: pinned source + Ninja full build
$EDITOR ~/.cache/hyprland-canvas-dev/source/src/render/Renderer.cpp
./dev build                             # changed translation units + validation
./dev export                            # source diff -> canonical shipping patch
```

`dev` enters the flake's shell itself. The shell inherits the overlay package's
exact build inputs and compiler, including the patched Aquamarine. Source,
Ninja state, and the last config-validated install persist under
`$XDG_CACHE_HOME/hyprland-canvas-dev/` (default `~/.cache/`).

`./dev export` emits a stable full-index diff from the locked Hyprland source.
`./dev sync` refuses a dirty source; after exporting or saving work elsewhere,
`./dev sync --force` resets it and reapplies the checked-in patch.

From a TTY, `./run-login --dev` explicitly selects the validated dev package. Plain
`./run-login` keeps its existing cached-Nix-package behavior. No command changes
live symlinks.

On this machine, touching only `src/render/Renderer.cpp` and running `./dev
build` took **47.226 seconds** including relink, config verification, and
publishing the validated package.
