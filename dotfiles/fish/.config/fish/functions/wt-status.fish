function wt-status --description "At-a-glance health of each running devenv-wt worktree: api readiness, web-proxy, and wt-proxy route registration"
    set -l admin http://127.0.0.1:2019
    set -l routes (curl -sf --max-time 1 "$admin/config/apps/http/servers/srv0/routes" 2>/dev/null)
    if test -z "$routes"
        echo "(wt-proxy caddy admin unreachable at $admin — `devenv deps` down? route column unknown)" >&2
    end

    printf "%-34s  %-20s  %-12s  %s\n" WORKTREE API WEB-PROXY ROUTE
    set -l found 0
    for line in (ps -ww -o args= -C process-compose | string match -r 'process-compose-wt-')
        set -l sub (string match -rg 'http://([a-z0-9._-]+)\.localhost' -- $line)[1]
        set -l apiport (string match -rg 'api \(:([0-9]+)\)' -- $line)[1]
        set -l wpport (string match -rg 'web-proxy \(:([0-9]+)\)' -- $line)[1]
        test -n "$sub"; and test -n "$apiport"; and test -n "$wpport"; or continue
        set found (math $found + 1)

        set -l apicode (timeout 3 curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$apiport/health 2>/dev/null)
        set -l wpcode (timeout 3 curl -s -o /dev/null -w '%{http_code}' http://127.0.0.1:$wpport/ 2>/dev/null)

        set -l api
        switch $apicode
            case 200; set api "✓ ready"
            case 000; set api "… building/down"
            case '*'; set api "⚠ $apicode"
        end

        set -l wp "✓ up"
        test "$wpcode" = 000; and set wp "✗ down"

        set -l route "✓"
        if test -n "$routes"
            string match -q "*\"$sub.localhost\"*" -- $routes; or set route "✗ wt-reroute"
        else
            set route "?"
        end

        printf "%-34s  %-20s  %-12s  %s\n" "$sub" "$api" "$wp" "$route"
    end
    test $found -eq 0; and echo "No running devenv-wt instances." >&2
end
