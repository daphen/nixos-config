import QtQuick
import Quickshell
import Quickshell.Io
import "."

Picker {
    id: root

    open: ReviewCreatePickerState.open
    onCloseRequested: ReviewCreatePickerState.open = false

    placeholder: "search my review PRs — or paste a PR number / url"
    altLabel: "Enter: review here (+ visual)    ·    Ctrl+Enter: full worktree to run the PR"
    subtitleField: "sub"
    glyphField: "glyph"
    glyphColorField: "gcolor"
    ctrlEnterAlt: true

    // PRs where I'm a reviewer, fetched on each open: open review requests +
    // everything I've reviewed (any state). Both carry my latest review state.
    property var requestedNodes: []
    property var reviewedNodes: []

    onActiveChanged: {
        if (active) {
            root.requestedNodes = []
            root.reviewedNodes = []
            root.loading = true
            prProc.running = true
        }
    }

    items: buildItems(root.requestedNodes, root.reviewedNodes, root.query)

    // Enter: lightweight review — a single claude window in the main checkout
    // (so gh resolves the repo). The review-pr skill fetches the diff via gh
    // and opens the visual review in the browser itself; no worktree/devenv.
    onEnter: item => {
        if (!item || !item.number) return
        ReviewCreatePickerState.open = false
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
            "gh api graphql -f query='query($q1:String!,$q2:String!){" +
            "requested:search(query:$q1,type:ISSUE,first:50){nodes{... on PullRequest{number title state author{login} viewerLatestReview{state}}}} " +
            "reviewed:search(query:$q2,type:ISSUE,first:50){nodes{... on PullRequest{number title state author{login} viewerLatestReview{state}}}}}' " +
            "-f q1=\"repo:$repo is:pr is:open review-requested:@me -author:@me sort:updated-desc\" " +
            "-f q2=\"repo:$repo is:pr reviewed-by:@me -author:@me sort:updated-desc\""]
        stdout: StdioCollector {
            onStreamFinished: {
                try {
                    const d = (JSON.parse(this.text || "{}").data) || {}
                    root.requestedNodes = (d.requested && d.requested.nodes) || []
                    root.reviewedNodes = (d.reviewed && d.reviewed.nodes) || []
                } catch (e) {
                    root.requestedNodes = []
                    root.reviewedNodes = []
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
}
