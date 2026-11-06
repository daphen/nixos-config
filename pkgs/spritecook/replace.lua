-- Replace the cels of one tag's frames, in order, with the listed images.
local p = app.params
local spr = app.open(p.out)
local layer = spr.layers[1]
for _, l in ipairs(spr.layers) do
  if l.name == "sprite" then layer = l end
end
local tag
for _, t in ipairs(spr.tags) do
  if t.name == p.tag then tag = t end
end
if not tag then error("no tag " .. p.tag) end
local index = tag.fromFrame.frameNumber
for path in io.lines(p.list) do
  if index > tag.toFrame.frameNumber then error("more images than frames in " .. p.tag) end
  spr:newCel(layer, spr.frames[index], Image { fromFile = path }, Point(0, 0))
  index = index + 1
end
spr:saveAs(p.out)
