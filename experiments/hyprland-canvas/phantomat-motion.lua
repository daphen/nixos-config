hl.curve("canvasPanFollow", { type = "spring", mass = 1, stiffness = 500, damping = 44.721 })
hl.animation({ leaf = "canvasCamera", enabled = true, speed = 2.5, spring = "canvasPanFollow" })
hl.animation({ leaf = "canvasFocus", enabled = true, speed = 8.0, bezier = "default" })
hl.animation({ leaf = "canvasOverview", enabled = true, speed = 8.0, bezier = "default" })
