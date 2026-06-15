{ pkgs, inputs, neovim }:
# A single ephemeral dev environment: all CLI tools + dotfile configs
# packaged into a script that sets up env vars and execs fish. Designed for
# `nix run github:daphen/nixos-portable-config#daphen-env`, with no profile
# installs, no home-manager, and no per-host state — disconnect from a
# sandbox and nothing is left behind.

let
  dotfiles = inputs.dotfiles;

  # Build a read-only config tree in the Nix store and point XDG_CONFIG_HOME
  # at it. Tools find their configs via well-known relative paths from
  # XDG_CONFIG_HOME (fish/, starship/, etc.). For tools that don't honor
  # XDG_CONFIG_HOME, we set tool-specific env vars explicitly below.
  configRoot = pkgs.runCommand "daphen-env-config" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    mkdir -p $out/fish $out/starship $out/nvim/colors

    # Fish: config.fish, conf.d, functions, fish_plugins (completions/ isn't
    # in the dotfiles repo — fish autoloads built-in completions from the
    # Nix package itself). Copy each optionally so a missing file doesn't
    # tank the whole build.
    for src in config.fish fish_plugins; do
      if [ -e "${dotfiles}/fish/.config/fish/$src" ]; then
        cp "${dotfiles}/fish/.config/fish/$src" "$out/fish/$src"
      fi
    done
    for dir in conf.d functions completions; do
      if [ -d "${dotfiles}/fish/.config/fish/$dir" ]; then
        cp -r "${dotfiles}/fish/.config/fish/$dir" "$out/fish/$dir"
      fi
    done

    # Files & dirs copied from the dotfiles store path inherit nix-store
    # permissions (0444 for files, 0555 for dirs) — read-only. The subsequent
    # heredocs need to create new files inside these dirs and overwrite some
    # existing ones, so flip everything under $out to user-writable up front.
    chmod -R u+w "$out"

    # Claude Code themes — the CLI's pre-installed in the lovbox image, but
    # it reads themes from ~/.claude/themes/. Ship daphen's custom ones so
    # the prompt colors match proart. The wrapper script symlinks/copies
    # this dir into $HOME at launch.
    if [ -d "${dotfiles}/claude/.claude/themes" ]; then
      mkdir -p "$out/claude/themes"
      cp -r "${dotfiles}/claude/.claude/themes"/* "$out/claude/themes/" 2>/dev/null || true
    fi

    # Starship + nvim colorschemes: generated from the dotfiles' single
    # source of truth (themes/colors.json + per-tool templates), driven by
    # the same theme-processor.py used on proart. Means: edit colors.json,
    # push dotfiles, next `nix run --refresh` in a sandbox picks up the
    # new palette automatically — no manual sync.
    THEMES=${dotfiles}/themes/.config/themes
    for mode in light dark; do
      python3 $THEMES/theme-processor.py \
        $THEMES/templates/starship.template \
        $THEMES/colors.json \
        $mode \
        $out/starship/$mode.toml
      # Sandbox prompt: insert a minimal top-level `format` (cloud + dir +
      # prompt char, one line) BEFORE the first [section] header. The
      # template's existing `format` sits inside [palettes.custom] and is
      # silently ignored by starship (TOML scoping bug, kept as-is to avoid
      # changing proart's prompt). Our injected one takes effect because
      # it's at root scope.
      python3 ${./inject-sandbox-format.py} "$out/starship/$mode.toml"
    done

    # nvim colorscheme files — dual-theme lua, generated from the same
    # palette. Land under $out/nvim/colors/, which the runtime wrapper
    # copies to $WRITABLE_CONFIG/nvim/colors. Since the wrapper sets
    # XDG_CONFIG_HOME to $WRITABLE_CONFIG, the wrapped nvim discovers
    # them via standard runtimepath (XDG_CONFIG_HOME/nvim).
    python3 $THEMES/theme-processor.py \
      $THEMES/templates/nvim-dark.template \
      $THEMES/colors.json \
      dark \
      $out/nvim/colors/custom-theme-dark.lua \
      nvim
    python3 $THEMES/theme-processor.py \
      $THEMES/templates/nvim-light.template \
      $THEMES/colors.json \
      light \
      $out/nvim/colors/custom-theme-light.lua \
      nvim

    # lov-gh-auth: one-shot fish function to wire gh + git to YOUR identity
    # inside a sandbox. Shared lovbox sandboxes inject the org GitHub App
    # bot's token by default, so PRs/pushes are attributed to the bot. Run
    # this once per sandbox (state persists on the PVC) with your personal
    # gh token pasted as the argument, or via stdin.
    cat > $out/fish/functions/lov-gh-auth.fish <<'GHEOF'
    function lov-gh-auth --description "Authenticate gh + git as you (not the lovbox bot) in this sandbox"
        set -l token $argv[1]
        if test -z "$token"
            echo "Usage: lov-gh-auth <github-token>"
            echo "  or:  echo <token> | lov-gh-auth"
            echo
            echo "Get your token on proart:"
            echo "  gh auth token"
            echo
            echo "Then paste it as the argument here."
            if not isatty stdin
                read token
            else
                return 1
            end
        end
        if test -z "$token"
            echo "✗ No token provided."
            return 1
        end
        echo "$token" | gh auth login --with-token --hostname github.com
        and git config --global --replace-all credential.helper "!gh auth git-credential"
        and echo "✓ gh + git wired to your identity. PRs/pushes will now show as you."
    end
    GHEOF

    # Override the dotfiles toggle_theme with a sandbox-friendly version.
    # The full theme-manager.sh expects niri/kitty/waybar to be running and
    # ships dozens of generated theme files — none of which exist remotely.
    # This sandbox version just flips ~/.config/theme_mode; nvim's existing
    # fs_event watcher in colorscheme.lua picks up the change live.
    cat > $out/fish/functions/toggle_theme.fish <<'FEOF'
    function toggle_theme --description "Flip ~/.config/theme_mode between dark and light (sandbox version)"
        set -l current "light"
        if test -f ~/.config/theme_mode
            set current (cat ~/.config/theme_mode)
        end
        set -l next "dark"
        if test "$current" = "dark"
            set next "light"
        end
        echo "$next" > ~/.config/theme_mode
        echo "→ theme_mode: $next"
    end
    FEOF

    # Git: write a minimal gitconfig pointing delta as the pager, set
    # identity from dotfiles, skip the includeIf entries (they reference
    # absolute paths under ~/personal etc. that don't exist on sandboxes).
    cat > $out/gitconfig <<'GITEOF'
    [init]
        defaultBranch = main
    [fetch]
        prune = true
    [user]
        name = David Karlsson
        email = davidkarlssson@gmail.com
    [pull]
        rebase = true
    [core]
        pager = delta
    [interactive]
        diffFilter = delta --color-only
    [delta]
        navigate = true
        light = false
        side-by-side = true
    [merge]
        conflictstyle = diff3
    [diff]
        colorMoved = default
    GITEOF
  '';

  # Tools that should be on PATH inside the dev-env shell. writeShellApplication
  # adds runtimeInputs to PATH for the wrapper script's execution; we `exec
  # fish` from the wrapper, so fish inherits the modified PATH.
  tools = with pkgs; [
    neovim
    fish
    git
    starship
    fzf
    zoxide
    ripgrep
    fd
    bat
    jq
    gh
    delta
    fastfetch
    openssh
  ];

in pkgs.writeShellApplication {
  name = "daphen-env";
  runtimeInputs = tools;
  # writeShellApplication uses `set -euo pipefail`. Allow unset vars when
  # sourcing fish (fish's loader checks several env vars optionally).
  text = ''
    set +u

    # The configRoot derivation lives in /nix/store (read-only), but fish
    # needs to *write* universal variables, history, etc. under
    # XDG_CONFIG_HOME/fish/. So sync the read-only tree to a writable
    # location (~/.config/daphen-env) and point env vars there. cp with
    # --no-preserve=mode strips the read-only bits from store files;
    # we leave already-extant non-source files (fish_variables, etc.)
    # alone so they persist across sessions.
    WRITABLE_CONFIG="$HOME/.config/daphen-env"
    mkdir -p "$WRITABLE_CONFIG"
    cp -rL --no-preserve=mode "${configRoot}"/. "$WRITABLE_CONFIG/"
    chmod -R u+w "$WRITABLE_CONFIG"

    # Default ~/.config/theme_mode to "light" on first launch so nvim's
    # colorscheme.lua picks the light variant. Doesn't clobber an existing
    # preference — the toggle_theme function writes there too.
    if [ ! -f "$HOME/.config/theme_mode" ]; then
      mkdir -p "$HOME/.config"
      echo light > "$HOME/.config/theme_mode"
    fi

    # Sync Claude Code themes into ~/.claude/themes/ so the CLI in the
    # sandbox (pre-installed by the lovbox image) picks them up. Copy
    # rather than symlink so claude can write its own state alongside
    # without trying to write into the read-only nix store.
    if [ -d "${configRoot}/claude/themes" ]; then
      mkdir -p "$HOME/.claude/themes"
      cp -fL "${configRoot}/claude/themes"/* "$HOME/.claude/themes/" 2>/dev/null || true
    fi

    # Wire notes-memory MCP via claude's own CLI — Claude v2 rewrites
    # ~/.claude.json on session end and drops hand-written mcpServers.
    if [ -n "''${NOTES_MEMORY_TOKEN:-}" ] && command -v claude >/dev/null; then
      claude mcp remove notes-memory --scope user >/dev/null 2>&1 || true
      claude mcp add --scope user notes-memory \
        --transport http https://notes-sigma-tawny.vercel.app/api/mcp \
        --header "Authorization: Bearer ''${NOTES_MEMORY_TOKEN}" >/dev/null 2>&1 || true
    fi

    # Materialize the matching starship variant. Re-evaluated each launch
    # so an `exec fish` after toggle_theme picks up the new prompt.
    THEME_MODE=$(cat "$HOME/.config/theme_mode" 2>/dev/null || echo light)
    if [ -e "$WRITABLE_CONFIG/starship/$THEME_MODE.toml" ]; then
      cp -f "$WRITABLE_CONFIG/starship/$THEME_MODE.toml" "$WRITABLE_CONFIG/starship/starship.toml"
    fi

    export XDG_CONFIG_HOME="$WRITABLE_CONFIG"
    export GIT_CONFIG_GLOBAL="$WRITABLE_CONFIG/gitconfig"
    export STARSHIP_CONFIG="$WRITABLE_CONFIG/starship/starship.toml"
    export EDITOR="nvim"
    export VISUAL="nvim"
    exec ${pkgs.fish}/bin/fish -l "$@"
  '';
}
