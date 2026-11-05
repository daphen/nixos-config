local CLI = "@spritecook@"

local function saved_sprite()
  local spr = app.sprite
  if not spr then return app.alert("Open a sprite first.") end
  if not app.fs.isFile(spr.filename) or not spr.filename:match("%.aseprite$") then
    return app.alert("Save the sprite as an .aseprite file inside a spritecook project first.")
  end
  app.command.SaveFile()
  return spr
end

local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end

local function run(args)
  local log = os.tmpname()
  local ok = os.execute(CLI .. " " .. args .. " > " .. quote(log) .. " 2>&1")
  local out = io.open(log):read("a")
  os.remove(log)
  return ok, out
end

local function reopen(spr, frame)
  local path = spr.filename
  spr:close()
  app.open(path)
  if frame then app.frame = app.sprite.frames[math.min(frame, #app.sprite.frames)] end
end

function init(plugin)
  plugin:newMenuGroup { id = "spritecook_menu", title = "Spritecook", group = "edit_menu" }

  plugin:newCommand {
    id = "SpritecookLint", title = "Check Pixels", group = "spritecook_menu",
    onclick = function() dofile(app.fs.joinPath(plugin.path, "Lint.lua")) end,
  }

  plugin:newCommand {
    id = "SpritecookAnimate", title = "Generate Animation…", group = "spritecook_menu",
    onclick = function()
      local spr = saved_sprite()
      if not spr then return end
      local dlg = Dialog("Generate Animation")
      dlg:combobox { id = "tag", label = "Animation", option = "walk", options = { "idle", "walk", "run", "jump", "attack", "hurt" } }
      dlg:slider { id = "frames", label = "Frames", min = 2, max = 8, value = 4 }
      dlg:entry { id = "prompt", label = "Motion notes" }
      dlg:label { text = "Uses frame 1 as the reference. Takes about a minute." }
      dlg:button { id = "ok", text = "Generate" }
      dlg:button { text = "Cancel" }
      dlg:show()
      local d = dlg.data
      if not d.ok then return end
      local first = #spr.frames + 1
      local ok, out = run(string.format("animate %s %s --frames %d --prompt %s",
        quote(spr.filename), quote(d.tag), d.frames, quote(d.prompt)))
      if not ok then return app.alert { title = "Spritecook", text = out } end
      reopen(spr, first)
    end,
  }

  plugin:newCommand {
    id = "SpritecookExport", title = "Export Sprite Sheet", group = "spritecook_menu",
    onclick = function()
      local spr = saved_sprite()
      if not spr then return end
      local ok, out = run("export " .. quote(spr.filename))
      app.alert { title = "Spritecook", text = ok and ("Exported " .. out) or out }
    end,
  }
end
