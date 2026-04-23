{ pkgs, inputs, lib }:

let
  # Shared formatters & linters — on PATH for conform.nvim, nvim-lint, and direct use
  lintAndFormat = with pkgs; [
    # Formatters
    prettier
    stylua
    black
    ruff
    alejandra
    nixpkgs-fmt

    # Linters
    eslint_d
    shellcheck
    statix
  ];

  # Custom plugins not yet packaged in nixpkgs. Commits pinned from current
  # lazy-lock.json. Hashes are lib.fakeHash placeholders — Nix will tell us
  # the real hash on first build; update them then.
  customPlugins = {
    "99" = pkgs.vimUtils.buildVimPlugin {
      pname = "99";
      version = "unstable-2026-04";
      src = pkgs.fetchFromGitHub {
        owner = "ThePrimeagen";
        repo = "99";
        rev = "ec9872f7df7f4eb8b319719c1c253eb3ea8877ed";
        hash = "sha256-z8hafm8EWS7dXoDXnZ/1ddvtpWKVUtJfvQmWT4zXIdg=";
      };
      doCheck = false;
    };

    jumppack = pkgs.vimUtils.buildVimPlugin {
      pname = "jumppack";
      version = "unstable-2026-04";
      src = pkgs.fetchFromGitHub {
        owner = "suliatis";
        repo = "jumppack";
        rev = "68113c3ddea4fdedab6a351b937e23fc18ad6f01";
        hash = "sha256-AfBrVnL69XkGkXxBZhAK2renUESeIKHb6CXBcW2fdDE=";
      };
      doCheck = false;
    };

    lualine-macro-recording = pkgs.vimUtils.buildVimPlugin {
      pname = "lualine-macro-recording";
      version = "unstable-2026-04";
      src = pkgs.fetchFromGitHub {
        owner = "yavorski";
        repo = "lualine-macro-recording.nvim";
        rev = "e2dcf63ba74e6111b53e1520a4f8a17a3d7427a1";
        hash = "sha256-Jcgddq7ImqHHSGXPUheWfg6t5OenK4a9IBIUcOswXsk=";
      };
      doCheck = false;
    };

    lualine-so-fancy = pkgs.vimUtils.buildVimPlugin {
      pname = "lualine-so-fancy";
      version = "unstable-2026-04";
      src = pkgs.fetchFromGitHub {
        owner = "meuter";
        repo = "lualine-so-fancy.nvim";
        rev = "6ba7b138f2ca435673eb04c2cf85f0757df69b07";
        hash = "sha256-Ctdt8kCG+4ynpfEHpvUhFQpbhcaLg0hoPX+yPkUQGS0=";
      };
      doCheck = false;
    };

    minty = pkgs.vimUtils.buildVimPlugin {
      pname = "minty";
      version = "unstable-2026-04";
      src = pkgs.fetchFromGitHub {
        owner = "nvzone";
        repo = "minty";
        rev = "aafc9e8e0afe6bf57580858a2849578d8d8db9e0";
        hash = "sha256-jdz0cR1uz1EdxFCuxndsK9gyTZ2jg8wdYA0v33SevOg=";
      };
      doCheck = false;
    };

    ripple = pkgs.vimUtils.buildVimPlugin {
      pname = "ripple-nvim";
      version = "unstable-2026-04";
      src = pkgs.fetchFromGitHub {
        owner = "ian-howell";
        repo = "ripple.nvim";
        rev = "8009919a22bee1ae84b7e6b24c6a05e777644761";
        hash = "sha256-Meb3h/gJkYajw1FIkUsZkuWTvwirHrRK/Se4WTlPP3s=";
      };
      doCheck = false;
    };

    vim-maximizer = pkgs.vimUtils.buildVimPlugin {
      pname = "vim-maximizer";
      version = "unstable-2026-04";
      src = pkgs.fetchFromGitHub {
        owner = "szw";
        repo = "vim-maximizer";
        rev = "2e54952fe91e140a2e69f35f22131219fcd9c5f1";
        hash = "sha256-+VPcMn4NuxLRpY1nXz7APaXlRQVZD3Y7SprB/hvNKww=";
      };
      doCheck = false;
    };

    volt = pkgs.vimUtils.buildVimPlugin {
      pname = "volt";
      version = "unstable-2026-04";
      src = pkgs.fetchFromGitHub {
        owner = "nvzone";
        repo = "volt";
        rev = "620de1321f275ec9d80028c68d1b88b409c0c8b1";
        hash = "sha256-5Xao1+QXZOvqwCXL6zWpckJPO1LDb8I7wtikMRFQ3Jk=";
      };
      doCheck = false;
    };

    # Local ai-tracker plugin (vendored from dotfiles) — reference as a regular
    # lua require path rather than a plugin. See lua/ai-tracker/.
  };

  # Neovim wrapper module definition.
  nvimWrapper = { wlib, pkgs, lib, config, ... }: {
    imports = [ wlib.wrapperModules.neovim ];

    options = {
      settings = {
        test_mode = lib.mkOption {
          type = lib.types.bool;
          default = false;
          description = "If true, read lua config from disk (dev mode) instead of the Nix store.";
        };

        wrapped_config = lib.mkOption {
          type = wlib.types.stringable;
          default = ./.;
        };

        unwrapped_config = lib.mkOption {
          type = lib.types.either wlib.types.stringable lib.types.luaInline;
          default = lib.generators.mkLuaInline
            "vim.uv.os_homedir() .. '/nixos/packages/neovim'";
        };
      };
    };

    config = {
      settings.config_directory =
        if config.settings.test_mode
        then config.settings.unwrapped_config
        else config.settings.wrapped_config;

      # devMode uses "vim" as binary name so both derivations can coexist
      binName = lib.mkIf config.settings.test_mode (lib.mkDefault "vim");
      settings.dont_link = config.binName != "nvim";

      # ── LSP servers, formatters, linters ──────────────────────────────
      extraPackages = with pkgs; [
        # Language servers
        lua-language-server
        pyright
        nil
        bash-language-server
        tailwindcss-language-server
        emmet-ls
        vscode-langservers-extracted # cssls, html, eslint_ls, jsonls
        typescript-language-server
        svelte-language-server

        # Runtime deps the nvim config or plugins may invoke
        ripgrep
        fd
        git
      ] ++ lintAndFormat;

      specs = {
        initLua = {
          data = null;
          before = [ "MAIN_INIT" ];
          config = ''
            require('init')
            require('lz.n').load('plugins')
            require('lz.n').load('plugins.lsp')
          '';
        };

        # ── Plugins (always loaded) ──────────────────────────────────────
        start = let p = pkgs.vimPlugins; in [
          p.lz-n
          p.plenary-nvim
          p.nui-nvim
          p.nvim-web-devicons
          p.mini-icons
          p.nvim-treesitter.withAllGrammars
          p.nvim-treesitter-textobjects
          p.vim-tmux-navigator

          # Completion (needed early so cmp integrations work)
          p.nvim-cmp
          p.cmp-nvim-lsp
          p.cmp_luasnip
          p.luasnip
          p.friendly-snippets

          # LSP core
          p.nvim-lspconfig
          p.nvim-lsp-file-operations

          # Eagerly loaded because other plugins' config hooks require() them
          # synchronously at startup (before lz.n would trigger lazy load).
          p.nvim-notify
        ];

        # ── Plugins (lazy loaded via lz.n) ────────────────────────────────
        opt = let p = pkgs.vimPlugins; in {
          lazy = true;
          data = [
            # UI
            p.noice-nvim
            p.dressing-nvim
            p.fastaction-nvim
            p.lualine-nvim
            customPlugins.lualine-macro-recording
            customPlugins.lualine-so-fancy
            p.snacks-nvim
            p.markview-nvim
            p.neo-tree-nvim
            p.fyler-nvim
            p.floaterm
            customPlugins.volt

            # Editing
            p.nvim-autopairs
            p.nvim-highlight-colors
            p.mini-nvim
            p.quicker-nvim
            customPlugins.minty
            customPlugins.ripple
            customPlugins.vim-maximizer

            # Git
            p.gitsigns-nvim
            p.diffview-nvim

            # LSP / Mason / formatting / linting
            p.mason-nvim
            p.mason-lspconfig-nvim
            p.conform-nvim
            p.nvim-lint

            # Navigation
            customPlugins.jumppack

            # Sessions
            p.auto-session

            # Terminals / scrollback
            p.kitty-scrollback-nvim

            # AI tooling
            customPlugins."99"
          ];
        };
      };
    };
  };

in {
  # Portable neovim — config baked into the Nix store.
  # Run anywhere with Nix: nix run github:daphen/nixos-config#neovim
  neovim = inputs.wrapper-modules.wrappers.neovim.wrap {
    inherit pkgs;
    imports = [ nvimWrapper ];
  };

  # Dev mode — reads lua config from ~/nixos/packages/neovim/ so edits
  # take effect instantly without rebuilding. Binary is `vim` to coexist.
  devMode = inputs.wrapper-modules.wrappers.neovim.wrap {
    inherit pkgs;
    imports = [
      nvimWrapper
      { settings.test_mode = true; }
    ];
  };

  # Auto-detect wrapper. Uses devMode if repo is cloned locally at
  # ~/nixos (live-edit workflow), otherwise the baked portable nvim.
  neovimDynamic = pkgs.writeShellApplication {
    name = "nvim";
    text = ''
      if [ -d "$HOME/nixos/packages/neovim/lua" ]; then
        exec ${lib.getExe (inputs.wrapper-modules.wrappers.neovim.wrap {
          inherit pkgs;
          imports = [ nvimWrapper { settings.test_mode = true; } ];
        })} "$@"
      else
        exec ${lib.getExe (inputs.wrapper-modules.wrappers.neovim.wrap {
          inherit pkgs;
          imports = [ nvimWrapper ];
        })} "$@"
      fi
    '';
  };

  # Make `neovim` the default for `nix run .` with no attribute
  default = inputs.wrapper-modules.wrappers.neovim.wrap {
    inherit pkgs;
    imports = [ nvimWrapper ];
  };
}
