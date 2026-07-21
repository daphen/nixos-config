function dwt --description "alias: devenv wt (TanStack-first; --next adds Next.js)"
    # Next.js is off by default in `devenv wt` now, so plain passthrough gives
    # the light TanStack-first slice. Pass --next (or --nextjs) to include the
    # Next.js app + web-proxy for the rare page still living there.
    if contains -- --next $argv
        set argv (string match -v -- --next $argv)
        devenv wt --nextjs $argv
    else
        devenv wt $argv
    end
end
