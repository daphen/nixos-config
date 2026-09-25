return function(ctx)
	local hl = ctx.hl

	hl.curve("canvasMotion", { type = "spring", mass = 1, stiffness = 1200, damping = 69.282 })
	hl.curve("canvasFade", { type = "bezier", points = { { 0.2, 0.8 }, { 0.2, 1 } } })
	hl.animation({ leaf = "windowsMove", enabled = true, speed = 2.5, spring = "canvasMotion" })
	hl.animation({ leaf = "canvasCamera", enabled = true, speed = 2.5, spring = "canvasMotion" })
	hl.animation({ leaf = "windowsIn", enabled = true, speed = 2.0, spring = "canvasMotion" })
	hl.animation({ leaf = "windowsOut", enabled = true, speed = 0.8, bezier = "canvasFade" })
	hl.animation({ leaf = "fadeIn", enabled = true, speed = 0.4, bezier = "canvasFade" })
	hl.animation({ leaf = "fadeOut", enabled = true, speed = 0.8, bezier = "canvasFade" })
	hl.window_rule({ name = "canvas-floating-animation", match = { float = true }, animation = "rise 2% 98%" })
	hl.window_rule({ name = "canvas-tiled-animation", match = { float = false }, animation = "popin 100%" })
end
