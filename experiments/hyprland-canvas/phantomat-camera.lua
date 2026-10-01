hl.curve("canvasCameraEase", { type = "bezier", points = { { 0.22, 1.0 }, { 0.36, 1.0 } } })
hl.animation({ leaf = "canvasFocus", enabled = true, speed = 8.0, bezier = "canvasCameraEase" })
