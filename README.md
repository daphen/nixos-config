# NixOS Configuration

This is a complete NixOS configuration migrated from Arch Linux, featuring:
- Niri window manager
- Comprehensive theme system
- 125+ packages
- Full dotfiles management via home-manager

## Directory Structure

```
nixos/
├── flake.nix                    # Main flake configuration
├── flake.lock                   # Flake lock file (generated)
├── configuration.nix            # System configuration
├── hardware-configuration.nix   # Hardware-specific config (to be generated)
├── modules/                     # System modules
│   ├── niri.nix                # Niri window manager
│   ├── audio.nix               # PipeWire audio
│   ├── bluetooth.nix           # Bluetooth
│   └── networking.nix          # Network configuration
├── home/                        # Home Manager configuration
│   ├── home.nix                # Main home config
│   ├── programs/               # Program configurations
│   │   ├── git.nix
│   │   ├── fish.nix
│   │   ├── neovim.nix
│   │   ├── terminals.nix
│   │   └── niri-scripts.nix
│   └── dotfiles/               # Dotfiles configurations
│       ├── theme-system.nix
│       ├── waybar.nix
│       ├── mako.nix
│       └── misc.nix
└── dotfiles-source/            # Symlink to your actual dotfiles
```

## Prerequisites

Before using this configuration, you need to set up the dotfiles-source link:

```bash
cd ~/nixos
ln -s ~/dotfiles dotfiles-source
```

This allows the NixOS configuration to reference your existing dotfiles from `~/dotfiles/`.

## Installation in VM

### Step 1: Clone this repository in the VM

```bash
# In the VM
git clone <your-repo-url> ~/nixos
cd ~/nixos
```

### Step 2: Generate hardware configuration

```bash
# Generate hardware config for your VM
sudo nixos-generate-config --show-hardware-config > hardware-configuration.nix
```

### Step 3: Review and customize

1. **Edit `configuration.nix`**:
   - Update timezone
   - Verify username matches
   - Review package list

2. **Edit `home/programs/git.nix`**:
   - Update email address

3. **Check hostname** in `configuration.nix`:
   - Default is "nixos", change if desired

### Step 4: Build and switch

```bash
# Build the configuration (doesn't activate)
sudo nixos-rebuild build --flake .#nixos

# If build succeeds, switch to new configuration
sudo nixos-rebuild switch --flake .#nixos
```

### Step 5: Reboot

```bash
sudo reboot
```

## Dotfiles Setup

After first boot, you need to set up your dotfiles:

### Option 1: Clone your dotfiles repo

```bash
# Clone your existing dotfiles
git clone <your-dotfiles-repo> ~/dotfiles

# Create the symlink
cd ~/nixos
ln -s ~/dotfiles dotfiles-source

# Rebuild to activate dotfiles
sudo nixos-rebuild switch --flake .#nixos
```

### Option 2: Copy from Arch system

```bash
# On your Arch system, create a git repo of dotfiles
cd ~/dotfiles
git init
git add .
git commit -m "Initial dotfiles"
git remote add origin <your-repo-url>
git push -u origin main

# Then follow Option 1 in the VM
```

## Updating the Configuration

### Update packages

```bash
# Update flake inputs
nix flake update

# Rebuild with updated packages
sudo nixos-rebuild switch --flake .#nixos
```

### Modify configuration

1. Edit the relevant `.nix` files
2. Commit changes (optional but recommended)
3. Rebuild:

```bash
sudo nixos-rebuild switch --flake .#nixos
```

### Test before switching

```bash
# Build without activating
sudo nixos-rebuild build --flake .#nixos

# Test in a VM
sudo nixos-rebuild build-vm --flake .#nixos
./result/bin/run-nixos-vm
```

## Home Manager

Home Manager is integrated into the system configuration. Changes to home-manager configs will be applied when you run `nixos-rebuild switch`.

Alternatively, manage home-manager separately:

```bash
# Switch home-manager only (after system changes)
home-manager switch --flake .#daphen
```

## Theme System

The theme system is activated automatically via home-manager activation scripts.

Manual theme management:

```bash
# Generate themes
cd ~/.config/themes
./theme-manager.sh generate dark

# Apply themes
./theme-manager.sh apply dark

# Toggle between light/dark
./theme-manager.sh toggle
```

## Troubleshooting

### Build errors

```bash
# Check flake inputs
nix flake show

# Validate flake
nix flake check
```

### Missing packages

Some AUR packages from Arch might not have direct Nix equivalents:
- Check [search.nixos.org](https://search.nixos.org)
- Check nixpkgs unstable
- May need to package yourself or find alternatives

### Hardware issues

If hardware isn't detected properly:
```bash
# Regenerate hardware config
sudo nixos-generate-config
# Compare with your hardware-configuration.nix
```

### Niri not starting

1. Check that niri is enabled in `modules/niri.nix`
2. Verify greetd service: `systemctl status greetd`
3. Check logs: `journalctl -u greetd`

### Dotfiles not appearing

1. Verify symlink: `ls -la ~/nixos/dotfiles-source`
2. Check home-manager: `home-manager packages | grep -i config`
3. Rebuild: `sudo nixos-rebuild switch --flake .#nixos`

## Key Files to Review

Before first build, review and customize:

1. **`home/programs/git.nix`** - Update your email
2. **`configuration.nix`** - Timezone, locale, username
3. **`hardware-configuration.nix`** - Generate for your hardware
4. **`flake.nix`** - System name (currently "nixos")

## Migration Notes

This configuration was migrated from Arch Linux with:
- 125 explicitly installed packages
- Custom Niri window manager setup with 19 custom scripts
- Centralized theme system supporting multiple tools
- Comprehensive Neovim configuration with lazy.nvim
- Fish shell with custom functions and theme integration

See `ARCH-TO-NIXOS-MIGRATION-PLAN.md` in your home directory for full migration details.

## Resources

- [NixOS Manual](https://nixos.org/manual/nixos/stable/)
- [Home Manager Manual](https://nix-community.github.io/home-manager/)
- [Nix Flakes](https://nixos.wiki/wiki/Flakes)
- [Search Packages](https://search.nixos.org)
- [Niri Documentation](https://github.com/YaLTeR/niri)

## Contributing Back

If you make improvements to this configuration, consider:
1. Committing changes to git
2. Pushing to your repository
3. Creating reusable modules for others

---

**Next Steps**:
1. Generate hardware-configuration.nix
2. Set up dotfiles-source symlink
3. Build and test in VM
4. Iterate and refine
5. Migrate main system when ready
