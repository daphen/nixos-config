{
  inputs = {
    hyprland.url = "github:hyprwm/Hyprland/f05d73f35795ded80d7e1264a37e41b461625f9f";
    nixpkgs.follows = "hyprland/nixpkgs";
  };

  outputs = { hyprland, nixpkgs, ... }:
    let
      system = "x86_64-linux";
      nestedConfigureFix = builtins.toFile "aquamarine-nested-configure.patch" ''
        diff --git a/include/aquamarine/backend/Wayland.hpp b/include/aquamarine/backend/Wayland.hpp
        --- a/include/aquamarine/backend/Wayland.hpp
        +++ b/include/aquamarine/backend/Wayland.hpp
        @@ -90,6 +90,7 @@ namespace Aquamarine {
                     Hyprutils::Memory::CSharedPointer<CCXdgToplevel> xdgToplevel;
                     Hyprutils::Memory::CSharedPointer<CCWlCallback>  frameCallback;
                     Hyprutils::Math::Vector2D                        surfaceSize;
        +            Hyprutils::Math::Vector2D                        pendingSize;
                 } waylandState;
        
                 friend class CWaylandBackend;
        diff --git a/src/backend/Wayland.cpp b/src/backend/Wayland.cpp
        --- a/src/backend/Wayland.cpp
        +++ b/src/backend/Wayland.cpp
        @@ -526,6 +526,12 @@ Aquamarine::CWaylandOutput::CWaylandOutput(const std::string& name_, Hyprutils::
             waylandState.xdgSurface->setConfigure([this](CCXdgSurface* r, uint32_t serial) {
                 backend->backend->log(AQ_LOG_DEBUG, std::format("Output {}: configure surface with {}", name, serial));
                 r->sendAckConfigure(serial);
        +        if (waylandState.pendingSize != Vector2D{}) {
        +            events.state.emit(SStateEvent{.size = waylandState.pendingSize});
        +            waylandState.pendingSize = {};
        +        }
        +        if (needsFrame)
        +            sched.frameReady.emit();
             });
        
             waylandState.xdgToplevel = makeShared<CCXdgToplevel>(waylandState.xdgSurface->sendGetToplevel());
        @@ -545,12 +551,11 @@ Aquamarine::CWaylandOutput::CWaylandOutput(const std::string& name_, Hyprutils::
                     w = 1280;
                     h = 720;
                 }
        -        events.state.emit(SStateEvent{.size = {w, h}});
        +        waylandState.pendingSize = {w, h};
                 // Kick off the first frame synchronously: the consumer expects events.frame in
                 // the same dispatch cycle as the toplevel configure. Deferring via scheduleFrame's
                 // idle races the first commit and can leave the output blank until the next event.
                 needsFrame = true;
        -        sched.frameReady.emit();
             });
        
             waylandState.xdgToplevel->setClose([this](CCXdgToplevel* r) { destroy(); });
      '';
      pkgs = import nixpkgs {
        inherit system;
        overlays = [
          hyprland.overlays.hyprland-packages
          (_final: prev: {
            aquamarine = prev.aquamarine.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [ nestedConfigureFix ];
            });
            hyprland = prev.hyprland.overrideAttrs (old: {
              patches = (old.patches or [ ]) ++ [ ./whole-canvas-camera.patch ];
            });
          })
        ];
      };
      canvasPackage = pkgs.hyprland;
      guiutilsPackage = hyprland.inputs.hyprland-guiutils.packages.${system}.default;
      cmakeFlags = builtins.concatStringsSep " " canvasPackage.cmakeFlags;
    in {
      packages.${system} = {
        default = canvasPackage;
        guiutils = guiutilsPackage;
      };

      devShells.${system}.default = pkgs.mkShell.override { stdenv = canvasPackage.stdenv; } {
        inputsFrom = [ canvasPackage ];
        packages = [ pkgs.git pkgs.ninja ];
        shellHook = ''
          export HYPRLAND_CANVAS_DEV_SHELL=1
          export HYPRLAND_PINNED_SOURCE=${hyprland.outPath}
          export HYPRLAND_PINNED_REV=${hyprland.rev}
          export HYPRLAND_CMAKE_FLAGS=${pkgs.lib.escapeShellArg cmakeFlags}
          export GIT_COMMIT_HASH=${canvasPackage.GIT_COMMIT_HASH}
          export GIT_COMMIT_DATE=${canvasPackage.GIT_COMMIT_DATE}
          export GIT_COMMITS=${pkgs.lib.escapeShellArg canvasPackage.GIT_COMMITS}
          export GIT_DIRTY=${canvasPackage.GIT_DIRTY}
          export GIT_TAG=${canvasPackage.GIT_TAG}
        '';
      };
    };
}
