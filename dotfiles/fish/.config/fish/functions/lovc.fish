function lovc --description "Lovable agent CLI with LOVABLE_API_KEY injected from 1Password"
    # Already in the environment (cockpit-add-lol exports it into LoL tabs, or
    # a parent shell did) — reuse it. 1Password's CLI integration re-authorizes
    # per calling process, so re-reading here means one prompt per tab.
    if set -q LOVABLE_API_KEY; and test -n "$LOVABLE_API_KEY"
        command lovc $argv
        return $status
    end
    # Key lives only in 1Password (public dotfiles repo) — fetched per call,
    # never written to disk. Workspace-scoped access token (PAM-minted).
    set -l key (op read 'op://Private/lovc/text' 2>/dev/null)
    if test -z "$key"
        echo "lovc: couldn't read LOVABLE_API_KEY from 1Password (op://Private/lovc/text)." >&2
        echo "      Run `eval (op signin)` first, or check the item." >&2
        return 1
    end
    command env LOVABLE_API_KEY="$key" lovc $argv
end
