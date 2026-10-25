import QtQuick
import Quickshell
import Quickshell.Io

Item {
    id: root

    property bool connected: false
    property var sessions: []
    property var conversations: ({})
    property var asks: ({})
    property int revision: 0
    property string error: ""
    property var queued: ({})
    property int queuedRevision: 0
    property int localMessageSequence: 0

    readonly property string socketPath: Quickshell.env("QSTNS_AGENTD_SOCK")
        || (Quickshell.env("XDG_RUNTIME_DIR") + "/agentd-chat.sock")

    signal turnFinished(string session)

    function send(message) {
        if (!socketLoader.item || !socketLoader.item.connected) {
            error = "Chat service unavailable"
            return false
        }
        socketLoader.item.write(JSON.stringify(message) + "\n")
        return true
    }

    function openSession(id) {
        if (!id) return
        send({ type: "get_entries", session: id })
    }

    function createSession(initialPrompt, requestedProfile) {
        var id = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx".replace(/[xy]/g, function(c) {
            var r = Math.floor(Math.random() * 16)
            return (c === "x" ? r : (r & 3) | 8).toString(16)
        })
        var command = {
            type: "spawn",
            session: id,
            cwd: Quickshell.env("HOME") + "/.local/share/agentd/chat",
            profile: requestedProfile || "chat"
        }
        if (initialPrompt && initialPrompt.trim()) command.prompt = initialPrompt.trim()
        send(command)
        if (command.prompt) addLocalMessage(id, command.prompt)
        return id
    }

    function addLocalMessage(id, text) {
        var c = conversations[id] || { id: id, title: "New chat", updatedAt: "", messages: [] }
        c.messages = c.messages.slice()
        localMessageSequence++
        var localKey = "local:" + id + ":" + localMessageSequence
        c.messages.push({ key: localKey + ":user", role: "user", content: text,
                          timestamp: new Date().toISOString() })
        c.messages.push({ key: localKey + ":assistant", role: "assistant", content: "",
                          timestamp: new Date().toISOString(), streaming: true })
        conversations[id] = c
        revision++
    }

    function dispatchPrompt(id, text, type) {
        if (!id || !text.trim()) return false
        if (!send({ type: type, session: id, message: text })) return false
        addLocalMessage(id, text)
        return true
    }

    function prompt(id, text) {
        return dispatchPrompt(id, text, sessionBusy(id) ? "steer" : "prompt")
    }

    function enqueue(id, text) {
        if (!id || !text.trim()) return false
        if (!sessionBusy(id)) return dispatchPrompt(id, text, "prompt")
        var next = Object.assign({}, queued)
        next[id] = (next[id] || []).concat([text])
        queued = next
        queuedRevision++
        return true
    }

    function queuedFor(id) {
        queuedRevision
        return (queued[id] || []).length
    }

    function flushQueue(id) {
        var items = queued[id] || []
        if (!items.length) return
        var next = Object.assign({}, queued)
        next[id] = items.slice(1)
        if (!next[id].length) delete next[id]
        queued = next
        queuedRevision++
        dispatchPrompt(id, items[0], "prompt")
    }

    function abort(id) {
        send({ type: "abort", session: id })
    }

    function stopSession(id) {
        if (!id || !send({ type: "stop", session: id })) return false
        sessions = sessions.filter(function(session) {
            return (session.id || session.name) !== id
        })
        var nextConversations = Object.assign({}, conversations)
        delete nextConversations[id]
        conversations = nextConversations
        var nextAsks = Object.assign({}, asks)
        delete nextAsks[id]
        asks = nextAsks
        var nextQueued = Object.assign({}, queued)
        delete nextQueued[id]
        queued = nextQueued
        queuedRevision++
        revision++
        return true
    }

    function answer(id, payload) {
        var ask = asks[id]
        if (!ask) return
        var response = { type: "extension_ui_response", session: id, id: ask.id }
        for (var k in payload) response[k] = payload[k]
        send(response)
        var next = Object.assign({}, asks)
        delete next[id]
        asks = next
        revision++
    }

    function sessionBusy(id) {
        for (var i = 0; i < sessions.length; i++)
            if (sessions[i].id === id || sessions[i].name === id)
                return sessions[i].status === "streaming"
        return false
    }

    function sessionProfile(id) {
        revision
        for (var i = 0; i < sessions.length; i++)
            if (sessions[i].id === id || sessions[i].name === id)
                return sessions[i].profile || "chat"
        return "chat"
    }

    function conversation(id) {
        revision
        return conversations[id] || { id: id, title: "New chat", updatedAt: "", messages: [] }
    }

    function filtered(query) {
        revision
        var q = String(query || "").trim().toLowerCase()
        var out = []
        for (var i = 0; i < sessions.length; i++) {
            var id = sessions[i].id || sessions[i].name
            var c = conversation(id)
            var haystack = c.title
            for (var j = 0; j < c.messages.length; j++) haystack += "\n" + c.messages[j].content
            if (!q || haystack.toLowerCase().indexOf(q) >= 0) out.push(c)
        }
        out.sort(function(a, b) { return String(b.updatedAt).localeCompare(String(a.updatedAt)) })
        return out
    }

    function textFromContent(content) {
        if (typeof content === "string") return content
        var out = []
        for (var i = 0; i < (content || []).length; i++)
            if (content[i].type === "text" && content[i].text) out.push(content[i].text)
        return out.join("\n")
    }

    function transcript(entries, leafId) {
        var byId = {}, leaf = leafId || ""
        for (var i = 0; i < entries.length; i++) {
            if (entries[i].id) byId[entries[i].id] = entries[i]
            if (!leaf && entries[i].id) leaf = entries[i].id
        }
        var chain = [], seen = {}
        while (leaf && byId[leaf] && !seen[leaf]) {
            seen[leaf] = true
            chain.push(byId[leaf])
            leaf = byId[leaf].parentId
        }
        chain.reverse()
        var messages = [], title = "New chat", updated = ""
        for (var j = 0; j < chain.length; j++) {
            var e = chain[j]
            if (e.timestamp && e.timestamp > updated) updated = e.timestamp
            if (e.type !== "message" || !e.message) continue
            var role = e.message.role
            if (role !== "user" && role !== "assistant") continue
            var text = textFromContent(e.message.content)
            if (!text) continue
            // pi expands /skill invocations into the full SKILL.md inline; show
            // a one-line chip instead of the manual dump.
            text = text.replace(/<skill\s+name="([^"]+)"[^>]*>[\s\S]*?<\/skill>\s*/g,
                                function(_, n) { return "(/" + n + " — skill instructions folded)\n" }).trim()
            if (!text) continue
            messages.push({ key: (e.id || ("entry:" + j)) + ":" + role,
                            role: role, content: text, timestamp: e.timestamp || "" })
            if (role === "user" && title === "New chat")
                title = text.length > 60 ? text.slice(0, 60) + "…" : text
        }
        return { title: title, updatedAt: updated, messages: messages }
    }

    function partialText(event) {
        var a = event.assistantMessageEvent || {}
        var partial = a.partial || {}
        return textFromContent(partial.content)
    }

    function updatePartial(id, text) {
        if (!text) return
        var c = conversation(id)
        c.messages = c.messages.slice()
        var last = c.messages[c.messages.length - 1]
        if (!last || last.role !== "assistant") {
            c.messages.push({ key: "stream:" + id, role: "assistant", content: text, streaming: true })
        } else {
            c.messages[c.messages.length - 1] = {
                key: last.key || ("stream:" + id), role: "assistant", content: text,
                timestamp: last.timestamp || "", streaming: true
            }
        }
        c.updatedAt = new Date().toISOString()
        conversations[id] = c
        revision++
    }

    function onLine(data) {
        var m
        try { m = JSON.parse(data) } catch (_) { return }
        if (!m) return
        if (m.type === "roster") {
            sessions = m.sessions || []
            for (var i = 0; i < sessions.length; i++) {
                var id = sessions[i].id || sessions[i].name
                if (!conversations[id]) conversations[id] = {
                    id: id, title: "New chat", updatedAt: sessions[i].updated_at || "", messages: []
                }
                openSession(id)
            }
            revision++
            return
        }
        var id = m.session
        if (!id) return
        if (m.type === "response" && m.command === "get_entries" && m.data) {
            var t = transcript(m.data.entries || [], m.data.leafId)
            conversations[id] = { id: id, title: t.title, updatedAt: t.updatedAt, messages: t.messages }
            revision++
            return
        }
        if (m.type === "message_update") {
            updatePartial(id, partialText(m))
        } else if (m.type === "tool_execution_start") {
            var c = conversation(id)
            c.toolActive = true
            conversations[id] = c
            revision++
        } else if (m.type === "message_end" || m.type === "turn_end" || m.type === "agent_end") {
            openSession(id)
            if (m.type === "agent_end") {
                turnFinished(id)
                flushQueue(id)
            }
        } else if (m.type === "extension_ui_request") {
            if (m.method === "confirm" || m.method === "select" || m.method === "input" || m.method === "editor") {
                var next = Object.assign({}, asks)
                next[id] = m
                asks = next
                revision++
            }
        } else if (m.type === "error") {
            error = String(m.error || "Reply interrupted")
        }
    }

    Loader {
        id: socketLoader
        active: true
        sourceComponent: Socket {
            path: root.socketPath
            connected: true
            parser: SplitParser { onRead: data => root.onLine(data) }
            onConnectionStateChanged: root.connected = connected
        }
    }

    Timer {
        interval: 2000
        repeat: true
        running: !(socketLoader.item && socketLoader.item.connected)
        onTriggered: { socketLoader.active = false; socketLoader.active = true }
    }
}
