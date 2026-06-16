function clip2path --description "Save clipboard image to temp file and output path"
    # Check if clipboard contains an image
    if wl-paste --list-types 2>/dev/null | grep -q "^image/"
        # Generate timestamp-based filename
        set timestamp (date +%Y%m%d_%H%M%S)
        set filename "/tmp/clip_$timestamp.png"

        # Save clipboard image to file
        wl-paste --type image/png > $filename 2>/dev/null

        if test -f $filename
            # Output the path (will appear in terminal)
            echo $filename
        else
            echo "Error: Failed to save clipboard image" >&2
            return 1
        end
    else
        echo "Error: No image found in clipboard" >&2
        return 1
    end
end
