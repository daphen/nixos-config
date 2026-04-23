return {
	"mason.nvim",
	cmd = { "Mason", "MasonUpdate", "MasonInstall", "MasonUninstall" },
	lazy = true,  -- Only load on command to avoid startup overhead
	opts = {
		ui = {
			icons = {
				package_installed = "✓",
				package_pending = "➜",
				package_uninstalled = "✗",
			},
		},
		-- Disable automatic registry update on startup
		registries = {
			"github:mason-org/mason-registry",
		},
		max_concurrent_installers = 4,
	},
}
