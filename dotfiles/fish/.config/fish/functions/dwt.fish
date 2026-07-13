function dwt --description "alias: devenv wt --no-next (tanstack-first)"
    # Next is legacy — skip its dev server by default (fans thank you).
    # Pass --next to include it for the rare page still living there.
    if contains -- --next $argv
        set argv (string match -v -- --next $argv)
        devenv wt $argv
    else
        devenv wt --no-next $argv
    end
end
