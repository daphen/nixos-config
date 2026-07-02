function wt-reroute --description "Re-register all running devenv-wt routes into the wt-proxy caddy (fixes worktree 404s after a devenv deps restart)"
    # After `devenv deps` restarts, the shared wt-proxy caddy comes up with an
    # empty in-memory route table; worktrees only recover when each re-registers.
    # This reproduces devenv's registerWtRoute for every running wt instance so
    # the *.localhost:2015 URLs work immediately instead of after the lag.
    set -l admin http://127.0.0.1:2019

    if not curl -sf -o /dev/null --max-time 1 $admin/config/
        echo "wt-proxy caddy admin unreachable at $admin — is `devenv deps` running?" >&2
        return 1
    end

    set -l count 0
    for line in (ps -ww -o args= -C process-compose | string match -r 'process-compose-wt-')
        set -l sub (string match -rg 'http://([a-z0-9._-]+)\.localhost' -- $line)[1]
        set -l apiport (string match -rg 'api \(:([0-9]+)\)' -- $line)[1]
        set -l wpport (string match -rg 'web-proxy \(:([0-9]+)\)' -- $line)[1]
        test -n "$sub"; and test -n "$apiport"; and test -n "$wpport"; or continue

        set -l route (printf '{"@id":"wt-%s","match":[{"host":["%s.localhost"]}],"handle":[{"handler":"subroute","routes":[{"match":[{"path":["/go-api/*"]}],"handle":[{"handler":"rewrite","strip_path_prefix":"/go-api"},{"handler":"reverse_proxy","upstreams":[{"dial":"localhost:%s"}]}]},{"handle":[{"handler":"reverse_proxy","upstreams":[{"dial":"localhost:%s"}]}]}]}]}' $sub $sub $apiport $wpport)

        curl -sf -o /dev/null -X DELETE "$admin/id/wt-$sub" 2>/dev/null
        if curl -sf -o /dev/null -X POST "$admin/config/apps/http/servers/srv0/routes" \
                -H "Content-Type: application/json" -d "$route"
            echo "✓ $sub.localhost:2015  →  web-proxy :$wpport · api :$apiport"
            set count (math $count + 1)
        else
            echo "✗ $sub — route POST failed" >&2
        end
    end

    if test $count -eq 0
        echo "No running devenv-wt instances found (nothing to re-register)." >&2
        return 1
    end
    echo "Re-registered $count worktree route(s)."
end
