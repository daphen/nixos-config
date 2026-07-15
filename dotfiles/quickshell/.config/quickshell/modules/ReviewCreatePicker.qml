import QtQuick
import Quickshell
import Quickshell.Io
import "."

Picker {
    id: root

    open: ReviewCreatePickerState.open
    onCloseRequested: ReviewCreatePickerState.open = false

    // the placeholder doubles as the refresh signal: cached rows paint
    // instantly on open, and this flips back once fresh data lands
    placeholder: prProc.running ? "search PRs — refreshing…"
                                : "search PRs — or paste a PR number / url"
    enterLabel: "review / open"
    altLabel: "Ctrl+Enter: worktree   ·   Ctrl+Y: copy url"

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
    // Nodes live in the State singleton: cached results paint instantly and
    // the fetch refreshes them in place — no empty flash on every open.
    onActiveChanged: {
        if (active) {
            root.loading = !ReviewCreatePickerState.hasCache
            prProc.running = true
        }
    }

    items: root.tab === 1 ? buildMine(ReviewCreatePickerState.mineNodes)
                          : buildItems(ReviewCreatePickerState.requestedNodes,
                                       ReviewCreatePickerState.reviewedNodes, root.query)

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
            "requested:search(query:$q1,type:ISSUE,first:50){nodes{... on PullRequest{number title url headRefName state author{login} viewerLatestReview{state}}}} " +
            "reviewed:search(query:$q2,type:ISSUE,first:50){nodes{... on PullRequest{number title url headRefName state author{login} viewerLatestReview{state}}}} " +
            "mine:search(query:$q3,type:ISSUE,first:40){nodes{... on PullRequest{number title url headRefName state isDraft reviewDecision latestReviews(first:1){totalCount} commits(last:1){nodes{commit{statusCheckRollup{state}}}}}}}}' " +
            "-f q1=\"repo:$repo is:pr is:open review-requested:@me -author:@me sort:updated-desc\" " +
            "-f q2=\"repo:$repo is:pr reviewed-by:@me -author:@me sort:updated-desc\" " +
            "-f q3=\"repo:$repo is:pr author:@me sort:updated-desc\" " +
            "| tee \"$(mkdir -p \"$HOME/.cache/quickshell\" && echo \"$HOME/.cache/quickshell/review-prs.json\")\""]
        stdout: StdioCollector {
            onStreamFinished: {
                ReviewCreatePickerState.parse(this.text)
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

    // Linear ticket id from the branch (convention: it's always in the branch
    // name, e.g. daphen/every-1234-…), else an explicit KEY-123 in the title
    // (other teams: SCA-2482 …); else the PR number.
    function ticketFor(pr) {
        const m = ((pr.headRefName || "") + " " + (pr.title || "")).match(/every-(\d+)/i)
        if (m) return "EVERY-" + m[1]
        const t = (pr.title || "").match(/\b([A-Z][A-Z0-9]{1,9}-\d+)\b/)
        return t ? t[1] : "#" + pr.number
    }

    function rowFor(pr, cat) {
        const m = catMeta(cat)
        return {
            number: String(pr.number),
            url: pr.url || "",
            label: ticketFor(pr) + "  " + (pr.title || ""),
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


    // my PRs tab — open first, then recently merged/closed (capped). Open rows
    // get one status glyph: failing CI beats review state (it's the thing to
    // act on), then approved / changes / commented / waiting.
    function buildMine(nodes) {
        const open = [], done = []
        for (const p of (nodes || [])) {
            let glyph, color, sub = ""
            if (p.state === "MERGED")      { glyph = "\uf126"; color = Theme.purple; sub = "merged" }
            else if (p.state === "CLOSED") { glyph = "\uf00d"; color = Theme.fg_muted; sub = "closed" }
            else {
                const ci = (((p.commits || {}).nodes || [])[0] || {}).commit
                const ciState = (ci && ci.statusCheckRollup && ci.statusCheckRollup.state) || ""
                const dec = p.reviewDecision || ""
                const commented = ((p.latestReviews || {}).totalCount || 0) > 0
                if (ciState === "FAILURE" || ciState === "ERROR") {
                    glyph = "\uf00d"; color = Theme.red
                    sub = dec === "APPROVED" ? "ci failing \u00b7 approved" : "ci failing"
                } else if (dec === "APPROVED")           { glyph = "\uf00c"; color = Theme.green }
                else if (dec === "CHANGES_REQUESTED")    { glyph = "\uf071"; color = Theme.red }
                else if (commented)                      { glyph = "\uf075"; color = Theme.blue }
                else                                     { glyph = "\uf10c"; color = Theme.fg_muted }
                if (!sub && ciState === "PENDING") sub = "ci pending"
                if (!sub && p.isDraft) sub = "draft"
            }
            const row = {
                action: "url",
                target: p.url || "",
                url: p.url || "",
                number: String(p.number),
                label: ticketFor(p) + "  " + (p.title || ""),
                sub: sub,
                glyph: glyph,
                gcolor: color,
            }
            if (p.state === "OPEN") open.push(row); else done.push(row)
        }
        return open.concat(done.slice(0, 15))
    }
}
