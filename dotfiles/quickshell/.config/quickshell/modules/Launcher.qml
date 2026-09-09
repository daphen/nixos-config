import QtQuick
import Quickshell
import Quickshell.Io
import "."

Picker {
    id: root

    readonly property string home: Quickshell.env("HOME")
    property var niriActions: []

    function displayShortcut(binding) {
        const names = { Mod: "Super", Super: "Super", Ctrl: "Ctrl", Shift: "Shift", Alt: "Alt", Slash: "/", Escape: "Escape", Return: "Enter", Space: "Space" }
        return String(binding).split("+").map(part => {
            if (names[part]) return names[part]
            return part.length === 1 ? part.toUpperCase() : part
        }).join("+")
    }

    function bindingBody(text, openBrace) {
        let depth = 0
        let quoted = false
        let escaped = false
        for (let i = openBrace; i < text.length; i++) {
            const ch = text[i]
            if (quoted) {
                if (escaped) escaped = false
                else if (ch === "\\") escaped = true
                else if (ch === "\"") quoted = false
                continue
            }
            if (ch === "\"") quoted = true
            else if (ch === "{") depth++
            else if (ch === "}" && --depth === 0) return text.slice(openBrace + 1, i)
        }
        return ""
    }

    function quotedArguments(body) {
        const out = []
        const pattern = /"((?:\\.|[^"\\])*)"/g
        let match
        while ((match = pattern.exec(body)) !== null) {
            try { out.push(JSON.parse("\"" + match[1] + "\"")) }
            catch (error) { return [] }
        }
        return out
    }

    function parsedCommand(body) {
        const command = body.trim().match(/^([A-Za-z0-9-]+)/)
        if (!command) return null
        if (command[1] === "spawn-sh") {
            const args = quotedArguments(body)
            return args.length ? { kind: "shell", args: ["sh", "-c", args[0]] } : null
        }
        if (command[1] === "spawn") {
            const args = quotedArguments(body)
            return args.length ? { kind: "spawn", args: args } : null
        }
        return { kind: "niri", args: ["niri", "msg", "action", command[1]] }
    }

    function parseBindings(text) {
        const source = text || ""
        const out = []
        const pattern = /^\s*([A-Za-z0-9+]+)\s+[^\n{]*hotkey-overlay-title="([^"]+)"[^\n{]*\{/gm
        let match
        while ((match = pattern.exec(source)) !== null) {
            if (match[1] === "Super+Ctrl+q" || match[1] === "Super+Space") continue
            const shortcut = displayShortcut(match[1])
            const existing = out.find(item => item.label === match[2])
            if (existing) {
                existing.shortcut += " / " + shortcut
                continue
            }
            const brace = match.index + match[0].lastIndexOf("{")
            const command = parsedCommand(bindingBody(source, brace))
            if (!command) continue
            out.push({
                label: match[2],
                subtitle: "Niri action",
                shortcut: shortcut,
                command: command.args
            })
        }
        out.sort((a, b) => a.label.localeCompare(b.label))
        return out
    }

    function actionShortcut(labels) {
        for (let i = 0; i < labels.length; i++) {
            const action = niriActions.find(item => item.label === labels[i])
            if (action) return action.shortcut
        }
        return ""
    }

    function appShortcut(app) {
        const text = ((app.name || "") + " " + (app.id || "")).toLowerCase()
        if (text.indexOf("1password") >= 0) return actionShortcut(["Open 1Password"])
        if (text.indexOf("btop") >= 0) return actionShortcut(["System Monitor"])
        if (text.indexOf("dsqrd") >= 0) return actionShortcut(["Discord"])
        if (text.indexOf("helium") >= 0) {
            const personal = actionShortcut(["Personal Browser"])
            const work = actionShortcut(["Work Browser"])
            return personal && work ? personal + " / " + work : personal || work
        }
        if (text.indexOf("kitty-open") >= 0) return ""
        if (text.indexOf("kitty") >= 0) return actionShortcut(["New Terminal"])
        if (text.indexOf("mlqs") >= 0) return actionShortcut(["Mail"])
        if (text.indexOf("qstns") >= 0) return actionShortcut(["Chat"])
        if (text.indexOf("slack") >= 0) return actionShortcut(["Slack"])
        if (text.indexOf("spotify_player") >= 0 || text.indexOf("spotify-player") >= 0)
            return actionShortcut(["Spotify"])
        if (text.indexOf("yazi") >= 0) return actionShortcut(["Files"])
        return ""
    }

    FileView {
        path: root.home + "/.config/niri/config.kdl"
        watchChanges: true
        onFileChanged: reload()
        onLoaded: root.niriActions = root.parseBindings(text())
        onLoadFailed: root.niriActions = []
    }

    open: LauncherState.open
    onCloseRequested: LauncherState.open = false

    placeholder: "Search applications and actions…"
    subtitleField: "subtitle"
    trailingField: "shortcut"
    trailingKeycaps: true

    items: {
        const out = [{ divider: true, label: "Actions" }]
        for (let i = 0; i < niriActions.length; i++) out.push(niriActions[i])
        out.push({ label: "Choose Wallpaper", subtitle: "Desktop appearance", action: "wallpaper" })

        const apps = []
        const all = DesktopEntries.applications.values
        for (let i = 0; i < all.length; i++) {
            const app = all[i]
            if (app.noDisplay) continue
            apps.push({
                app: app,
                label: app.name || app.id || "?",
                subtitle: app.genericName || "",
                shortcut: appShortcut(app)
            })
        }
        apps.sort((a, b) => a.label.localeCompare(b.label))
        out.push({ divider: true, label: "Applications" })
        return out.concat(apps)
    }

    onEnter: item => {
        if (!item) return
        if (item.action === "wallpaper") WallpaperPickerState.show()
        else if (item.command) Quickshell.execDetached(item.command)
        else if (item.app && item.app.execute) item.app.execute()
    }
}
