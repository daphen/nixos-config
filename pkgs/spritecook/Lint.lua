-- Pixel-art cleanup checks. Batch mode prints a report; in the editor it paints issues on a "spritecook lint" layer.
local spr = app.sprite
if not spr then return print("no sprite open") end

local LAYER = "spritecook lint"
local MARK = { stray = Color(255, 0, 80), double = Color(255, 200, 0), palette = Color(0, 220, 255), alpha = Color(200, 0, 255) }

local palette = {}
for i = 0, #spr.palettes[1] - 1 do
  local c = spr.palettes[1]:getColor(i)
  palette[app.pixelColor.rgba(c.red, c.green, c.blue, 255)] = true
end

local function checks(image)
  local w, h = image.width, image.height
  local function at(x, y)
    if x < 0 or y < 0 or x >= w or y >= h then return 0 end
    return image:getPixel(x, y)
  end
  local function same(x, y, c) return at(x, y) == c end
  local found = {}
  for y = 0, h - 1 do
    for x = 0, w - 1 do
      local c = at(x, y)
      local a = app.pixelColor.rgbaA(c)
      if a > 0 then
        local kind
        if a < 255 then
          kind = "alpha"
        elseif not palette[c] then
          kind = "palette"
        else
          local alone = true
          for dy = -1, 1 do
            for dx = -1, 1 do
              if (dx ~= 0 or dy ~= 0) and same(x + dx, y + dy, c) then alone = false end
            end
          end
          local edge = at(x - 1, y) == 0 or at(x + 1, y) == 0 or at(x, y - 1) == 0 or at(x, y + 1) == 0
          if alone then
            kind = "stray"
          elseif edge then
            -- An L-corner in the outline that thickens the 1px line (what Aseprite's pixel-perfect pencil removes).
            for _, d in ipairs { { -1, 1 }, { 1, 1 }, { -1, -1 }, { 1, -1 } } do
              local hx, vy = d[1], d[2]
              if same(x + hx, y, c) and same(x, y + vy, c) and not same(x - hx, y, c)
                and not same(x, y - vy, c) and not same(x + hx, y + vy, c) then
                kind = "double"
              end
            end
          end
        end
        if kind then found[#found + 1] = { x = x, y = y, kind = kind } end
      end
    end
  end
  return found
end

local function flatten(frame)
  local image = Image(spr.spec)
  image:clear()
  for _, layer in ipairs(spr.layers) do
    local cel = layer.isVisible and layer.name ~= LAYER and layer:cel(frame)
    if cel then image:drawImage(cel.image, cel.position) end
  end
  return image
end

local results, total = {}, 0
for _, frame in ipairs(spr.frames) do
  results[frame.frameNumber] = checks(flatten(frame))
  total = total + #results[frame.frameNumber]
end

if not app.isUIAvailable then
  local counts = {}
  for n, found in pairs(results) do
    for _, f in ipairs(found) do
      counts[f.kind] = (counts[f.kind] or 0) + 1
      if (counts[f.kind] or 0) <= 5 then print(string.format("frame %d  %3d,%-3d %s", n, f.x, f.y, f.kind)) end
    end
  end
  return print(string.format("%d issues: %d stray, %d doubled corners, %d off-palette, %d semi-transparent",
    total, counts.stray or 0, counts.double or 0, counts.palette or 0, counts.alpha or 0))
end

app.transaction("Spritecook lint", function()
  for _, layer in ipairs(spr.layers) do
    if layer.name == LAYER then spr:deleteLayer(layer) end
  end
  if total == 0 then return end
  local layer = spr:newLayer()
  layer.name = LAYER
  layer.opacity = 170
  for n, found in pairs(results) do
    if #found > 0 then
      local image = Image(spr.spec)
      image:clear()
      for _, f in ipairs(found) do image:drawPixel(f.x, f.y, MARK[f.kind]) end
      spr:newCel(layer, n, image, Point(0, 0))
    end
  end
end)
app.refresh()
app.alert { title = "Spritecook lint", text = {
  total == 0 and "Clean: no issues found." or string.format("%d issues marked on the \"%s\" layer:", total, LAYER),
  total > 0 and "red = stray pixel, yellow = doubled corner, cyan = off-palette, purple = semi-transparent" or "",
  total > 0 and "Run lint again after fixing; the layer is skipped on export." or "" } }
