import QtQuick
import Quickshell
import Quickshell.Io
import "."

Picker {
    id: root

    open: ReviewCreatePickerState.open
    onCloseRequested: ReviewCreatePickerState.open = false

    placeholder: "search PRs — or paste a PR number / url"
    altLabel: "Enter: review / open   ·   Ctrl+Enter: worktree   ·   Ctrl+Y: copy url   ·   Tab/Ctrl+H/L: switch"

    // Ctrl+Y: copy the focused PR's URL (mirrors the imv copy pattern:
    // wl-copy + a notification so the yank is visible).
    onYank: item => {
        const u = (item && (item.url || item.target)) || ""
        if (!u) return
        Quickshell.execDetached(["sh", "-c",
            "wl-copy -- \"$1\" && notify-send -t 2000 'Copied PR URL' \"$1\"", "_", u])
    }
    subtitleField: "sub"
    glyphField: "glyph"
    glyphColorField: "gcolor"
    ctrlEnterAlt: true
    tabs: ["reviews", "my PRs"]

    // reviews tab: PRs where I'm a reviewer (requested + reviewed, my state).
    // my PRs tab: my open PRs with review decision + CI rollup.
    property var requestedNodes: []
    property var reviewedNodes: []
    property var mineNodes: []

    onActiveChanged: {
        if (active) {
            root.requestedNodes = []
            root.reviewedNodes = []
            root.mineNodes = []
            root.loading = true
            prProc.running = true
        }
    }

    items: root.tab === 1 ? buildMine(root.mineNodes)
                          : buildItems(root.requestedNodes, root.reviewedNodes, root.query)

    // Enter — reviews tab: lightweight review (claude in the main checkout;
    // the skill fetches via gh and serves the visual itself). my-PRs tab:
    // open the PR on GitHub in the work browser.
    onEnter: item => {
        if (!item) return
        ReviewCreatePickerState.open = false
        if (item.action === "url") {
            Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/browser-dispatch",
                "--profile=work", "--new-window", item.target])
            return
        }
        if (!item.number) return
        Quickshell.execDetached(["kitty", "--class", "claude",
            "--working-directory", Quickshell.env("HOME") + "/work/lovable",
            "-e", "bash", "-lc", "claude 'review PR #" + item.number + "'"])
    }

    // Ctrl+Enter: full worktree + devenv stack, for when you want to run the PR.
    onAltAction: item => {
        if (!item || !item.number) return
        ReviewCreatePickerState.open = false
        Quickshell.execDetached([Quickshell.env("HOME") + "/.config/niri/scripts/ws-createreview", item.number])
    }

    Process {
        id: prProc
        command: ["bash", "-lc",
            "cd \"$HOME/work/lovable\" && repo=$(gh repo view --json nameWithOwner -q .nameWithOwner 2>/dev/null) && " +
            "gh api graphql -f query='query($q1:String!,$q2:String!,$q3:String!){" +
            "requested:search(query:$q1,type:ISSUE,first:50){nodes{... on PullRequest{number title url state author{login} viewerLatestReview{state}}}} " +
            "reviewed:search(query:$q2,type:ISSUE,first:50){nodes{... on PullRequest{number title url state author{login} viewerLatestReview{state}}}} " +
            "mine:search(query:$q3,type:ISSUE,first:30){nodes{... on PullRequest{number title url isDraft reviewDecision latestReviews(first:1){totalCount} commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}' " +
            "-f q1=\"repo:$repo is:pr is:open review-requested:@me -author:@me sort:updated-desc\" " +
            "-f q2=\"repo:$repo is:pr reviewed-by:@me -author:@me sort:updated-desc\" " +
            "-f q3=\"repo:$repo is:pr is:open author:@me sort:updated-desc\""]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = (JSON.parse(this.text || "{}").data) || {}
                    root.requestedNodes = (d.requested && d.requested.nodes) || []
                    root.reviewedNodes = (d.reviewed && d.reviewed.nodes) || []
                    root.mineNodes = (d.mine && d.mine.nodes) || []
                } catch (e) {
                    root.requestedNodes = []
                    root.reviewedNodes = []
                    root.mineNodes = []
                }
                root.loading = false
            }
        }
    }

    // Bare number, "#123", or a github pull URL → the PR number.
    function prNum(q) {
        const s = (q || "").trim()
        const m = s.match(/pull\/(\d+)/)
        if (m) return m[1]
        const n = s.replace(/^#/, "")
        return /^\d+$/.test(n) ? n : ""
    }

    // Per-category status glyph (Nerd Font) + theme-aware colour.
    function catMeta(cat) {
        switch (cat) {
        case "awaiting":  return { glyph: "", color: Theme.orange }   // eye — needs my review
        case "changes":   return { glyph: "", color: Theme.red }      // alert — changes requested
        case "commented": return { glyph: "", color: Theme.blue }     // comment
        case "approved":  return { glyph: "", color: Theme.green }    // check
        case "merged":    return { glyph: "", color: Theme.purple }   // branch — merged
        case "closed":    return { glyph: "", color: Theme.fg_muted } // x — dropped
        }
        return { glyph: "", color: Theme.fg_muted }
    }

    function rowFor(pr, cat) {
        const m = catMeta(cat)
        return {
            number: String(pr.number),
            url: pr.url || "",
            label: "#" + pr.number + "  " + (pr.title || ""),
            sub: (pr.author && pr.author.login) ? "@" + pr.author.login : "",
            glyph: m.glyph,
            gcolor: m.color,
        }
    }

    function buildItems(requestedNodes, reviewedNodes, query) {
        const reqSet = {}
        for (const p of (requestedNodes || [])) reqSet[p.number] = true

        const cats = { awaiting: [], changes: [], commented: [], approved: [], merged: [], closed: [] }
        const seen = {}
        // Requested first so open review-requests land in `awaiting`; iteration
        // order (updated-desc from the query) is preserved within each group.
        const place = p => {
            if (seen[p.number]) return
            seen[p.number] = true
            const vr = (p.viewerLatestReview && p.viewerLatestReview.state) || ""
            let cat
            if (p.state === "MERGED") cat = "merged"
            else if (p.state === "CLOSED") cat = "closed"
            else if (reqSet[p.number]) cat = "awaiting"
            else if (vr === "APPROVED") cat = "approved"
            else if (vr === "CHANGES_REQUESTED") cat = "changes"
            else cat = "commented"
            cats[cat].push(p)
        }
        for (const p of (requestedNodes || [])) place(p)
        for (const p of (reviewedNodes || [])) place(p)

        // Order groups by priority; caps keep the "done" states from flooding.
        // No dividers — the colour-coded status glyph on each row carries it.
        const groups = [
            ["awaiting",  99],
            ["changes",   99],
            ["commented", 99],
            ["approved",  99],
            ["merged",    15],
            ["closed",     8],
        ]

        const out = []
        const ref = prNum(query)
        if (ref) out.push({ number: ref, label: "→ Review PR #" + ref, sub: query, glyph: "", gcolor: Theme.fg })

        for (const g of groups) {
            const list = cats[g[0]]
            for (const p of list.slice(0, g[1])) out.push(rowFor(p, g[0]))
        }
        return out
    }

    // my PRs tab — one status glyph per row: failing CI beats review state
    // (it's the thing to act on), then approved / changes / commented / waiting.
    function buildMine(nodes) {
        const out = []
        for (const p of (nodes || [])) {
            const ci = (((p.commits || {}).nodes || [])[0] || {}).commit
            const ciState = (ci && ci.statusCheckRollup && ci.statusCheckRollup.state) || ""
            const dec = p.reviewDecision || ""
            const commented = ((p.latestReviews || {}).totalCount || 0) > 0
            let glyph, color, sub = ""
            if (ciState === "FAILURE" || ciState === "ERROR") {
                glyph = ""; color = Theme.red
                sub = dec === "APPROVED" ? "ci failing · approved" : "ci failing"
            } else if (dec === "APPROVED")           { glyph = ""; color = Theme.green }
            else if (dec === "CHANGES_REQUESTED")    { glyph = ""; color = Theme.red }
            else if (commented)                      { glyph = ""; color = Theme.blue }
            else                                     { glyph = ""; color = Theme.fg_muted }
            if (!sub && ciState === "PENDING") sub = "ci pending"
            if (!sub && p.isDraft) sub = "draft"
            out.push({
                action: "url",
                target: p.url || "",
                url: p.url || "",
                number: String(p.number),
                label: "#" + p.number + "  " + (p.title || ""),
                sub: sub,
                glyph: glyph,
                gcolor: color,
            })
        }
        return out
    }
}
