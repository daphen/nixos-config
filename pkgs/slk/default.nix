# slk — Slack TUI. Built from our fork (github:daphen/slk-fork), which carries
# notification/presence/thread-broadcast/paste/subteam-mention fixes as source
# (was a Nix patch; folded into the fork, same pattern as endcord). Upstream is
# gammons/slk; pull upstream into ~/personal/slk-fork, push, then bump rev+hash.
# Auth is browser-cookie (xoxc + d), done once via `slk --add-workspace`;
# tokens live in ~/.local/share/slk/tokens.
{ lib, buildGoModule, fetchFromGitHub, pkg-config, xorg }:

buildGoModule rec {
  pname = "slk";
  version = "0.9.0";

  src = fetchFromGitHub {
    owner = "daphen";
    repo = "slk-fork";
    rev = "9587f8f0edc0e74cf9ff21c1ace3dfcf9b10bf2a";
    hash = "sha256-FPt76pFFDMSRY7gA66DUEtDwqYyQ8VZMgsz7GkYt08I=";
  };

  vendorHash = "sha256-dPa469oNv6eYyDdly3uhc273DAGz+erc0E3K/am7WoY=";

  # golang.design/x/clipboard uses cgo + X11 (Xlib.h) on Linux.
  nativeBuildInputs = [ pkg-config ];
  buildInputs = [ xorg.libX11 ];

  subPackages = [ "cmd/slk" ];

  ldflags = [ "-s" "-w" "-X main.version=${version}" ];

  meta = {
    description = "Blazingly fast Slack TUI";
    homepage = "https://getslk.sh/";
    license = lib.licenses.mit;
    mainProgram = "slk";
  };
}
