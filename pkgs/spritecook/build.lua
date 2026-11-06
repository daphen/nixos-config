local p = app.params
local size = tonumber(p.size)
local spr, layer, first, ranges

if p.append == "1" then
  spr = app.open(p.out)
  if spr.width ~= size or spr.height ~= size then
    error(string.format("sprite is %dx%d but the project size is %d", spr.width, spr.height, size))
  end
  layer = spr.layers[1]
  for _, l in ipairs(spr.layers) do
    if l.name == "sprite" then layer = l end
  end
  first = #spr.frames + 1
  -- Appending after a tag's last frame stretches that tag; remember every range and restore it.
  ranges = {}
  for _, t in ipairs(spr.tags) do ranges[t] = { t.fromFrame.frameNumber, t.toFrame.frameNumber } end
else
  spr = Sprite(size, size, ColorMode.RGB)
  layer = spr.layers[1]
  layer.name = "sprite"
  first = 1
end

spr:setPalette(Palette { fromFile = p.palette })

local index = first
for path in io.lines(p.list) do
  local frame = spr.frames[index] or spr:newEmptyFrame(index)
  if p.tag ~= "" then frame.duration = 0.12 end
  spr:newCel(layer, frame, Image { fromFile = path }, Point(0, 0))
  index = index + 1
end

for t, range in pairs(ranges or {}) do
  t.fromFrame = spr.frames[range[1]]
  t.toFrame = spr.frames[range[2]]
end

if p.tag ~= "" then
  local tag = spr:newTag(first, index - 1)
  tag.name = p.tag
end

spr:saveAs(p.out)
