# slk — Slack TUI (gammons/slk). Single static Go binary, bubbletea/lipgloss,
# kitty-graphics inline images, vim-modal. Auth is browser-cookie (xoxc + d),
# done once via `slk --add-workspace`; tokens live in ~/.local/share/slk/tokens.
{ lib, buildGoModule, fetchFromGitHub, pkg-config, xorg }:

buildGoModule rec {
  pname = "slk";
  version = "0.9.0";

  src = fetchFromGitHub {
    owner = "gammons";
    repo = "slk";
    rev = "v${version}";
    hash = "sha256-hLkJUyxFqxm+SZQHdub0N1Q7X5TtVPv+OdidiPXKkes=";
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
