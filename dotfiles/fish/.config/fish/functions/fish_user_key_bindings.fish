function fish_user_key_bindings
  if functions -q fzf_key_bindings
      fzf_key_bindings
  end

  # Remove default Alt+C binding in both modes
  bind -M insert -e \ec
  bind -M default -e \ec

  # Custom bindings for both insert and normal modes
  # Bindings for CTRL+E
  bind -M insert \ce fzf-cd-widget
  bind -M default \ce fzf-cd-widget

  # Bindings for CTRL+F
  bind -M insert \cf fzf-file-widget
  bind -M default \cf fzf-file-widget

  # Use system clipboard for vi mode yank and paste
  bind -M default y 'commandline | wl-copy'
  bind -M default p 'commandline -i (wl-paste)'
  bind -M visual y 'commandline | wl-copy'
end
