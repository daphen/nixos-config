{ config, pkgs, ... }:

{
  # Git Configuration
  # =================
  
  programs.git = {
    enable = true;
    
    userName = "daphen";
    userEmail = "your-email@example.com";  # TODO: Update with your email
    
    extraConfig = {
      init.defaultBranch = "main";
      pull.rebase = false;
      core.editor = "nvim";
      
      # Additional git settings
      push.autoSetupRemote = true;
      rerere.enabled = true;
    };
    
    # Git aliases
    aliases = {
      st = "status";
      co = "checkout";
      br = "branch";
      ci = "commit";
      unstage = "reset HEAD --";
      last = "log -1 HEAD";
      visual = "log --graph --oneline --all";
    };
    
    # Git ignore globally
    ignores = [
      ".DS_Store"
      "*.swp"
      "*.swo"
      "*~"
      ".direnv"
      "node_modules"
      ".env"
      ".vscode"
      ".idea"
    ];
  };

  # GitHub CLI
  programs.gh = {
    enable = true;
    settings = {
      git_protocol = "ssh";
      editor = "nvim";
    };
  };

  # Lazygit
  programs.lazygit = {
    enable = true;
    settings = {
      gui = {
        theme = {
          activeBorderColor = [ "#a9b9ef" "bold" ];
          inactiveBorderColor = [ "#767676" ];
          selectedLineBgColor = [ "#121e42" ];
        };
      };
    };
  };
}
