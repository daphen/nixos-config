#!/usr/bin/env python3

import json
import sys
import re
import os
from pathlib import Path

def _hex_to_rgb(h):
    h = h.lstrip('#')
    return tuple(int(h[i:i + 2], 16) for i in (0, 2, 4))

def _mix(base_hex, tint_hex, alpha):
    b, t = _hex_to_rgb(base_hex), _hex_to_rgb(tint_hex)
    return '#{:02X}{:02X}{:02X}'.format(
        *(round(b[i] * (1 - alpha) + t[i] * alpha) for i in range(3)))

# Elevation ladder: two authored anchors (bg + surface) per mode, higher
# steps derived by compositing fg over surface1 — over surface, never bg,
# so the steps inherit the palette's warmth (a neutral-bg mix reads cold).
# Dark mode needs roughly double the alpha for the same perceived step.
_LADDER_STEPS = {
    'light': {'surface2': 0.045, 'surface3': 0.08},
    'dark':  {'surface2': 0.09,  'surface3': 0.15},
}

def _add_derived(themes):
    for mode, steps in _LADDER_STEPS.items():
        if mode not in themes:
            continue
        bg = themes[mode].get('background', {})
        fg = themes[mode].get('foreground', {}).get('primary')
        s1 = bg.get('surface')
        if not (fg and s1):
            continue
        bg['surface1'] = s1
        # surface0: the whisper step between bg and surface1 (chin bands,
        # barely-raised wells). Midpoint of the two anchors keeps the warmth —
        # an fg tint over a neutral bg would read cold.
        bg.setdefault('surface0', _mix(bg.get('primary', s1), s1, 0.5))
        for name, alpha in steps.items():
            bg.setdefault(name, _mix(s1, fg, alpha))
    return themes

def load_colors(colors_file, theme_mode):
    """Load colors from JSON file for specified theme mode."""
    with open(colors_file, 'r') as f:
        data = json.load(f)
    return _add_derived(data['themes'])[theme_mode]

def load_all_colors(colors_file):
    """Load all colors from JSON file."""
    with open(colors_file, 'r') as f:
        data = json.load(f)
    return _add_derived(data['themes'])

def get_nested_color(colors, path, max_depth=5, theme_context=None):
    """Get color value from nested path with recursive reference resolution."""
    keys = path.split('.')
    value = colors
    for key in keys:
        if key in value:
            value = value[key]
        else:
            return None
    
    # If the value is a string that looks like another reference, resolve it recursively
    if isinstance(value, str) and '.' in value and max_depth > 0:
        # Check if this looks like a color reference (not a hex color)
        if not value.startswith('#'):
            # If we have a theme context and the reference doesn't include theme, prepend it
            if theme_context and not any(theme in value for theme in ['dark', 'light']):
                themed_reference = f"{theme_context}.{value}"
                resolved = get_nested_color(colors, themed_reference, max_depth - 1, theme_context)
            else:
                resolved = get_nested_color(colors, value, max_depth - 1, theme_context)
            if resolved:
                return resolved
    
    return value

def process_template(template_file, colors_file, theme_mode, output_file, tool_name=None):
    """Process template file and replace color variables."""

    # Fish expects bare hex colors without '#' prefix (it treats '#' as a comment)
    strip_hash = tool_name in ('fish', 'tide')
    
    # Templates that bundle both themes side-by-side and let the consumer
    # pick at runtime (prefers-color-scheme media query, vim background
    # autocmd, etc.) need access to both palettes in a single pass.
    base = os.path.basename(template_file)
    is_dual_theme_template = (
        'nvim' in base
        or base.startswith('chromium-palette')
        or base.startswith('quickshell')
        or base.startswith('review')
        or base.startswith('newtab')
    )

    if is_dual_theme_template:
        all_colors = load_all_colors(colors_file)
        colors = all_colors  # Contains both 'dark' and 'light' themes
    else:
        # Load colors for specific theme mode
        colors = load_colors(colors_file, theme_mode)
    
    # Read template
    with open(template_file, 'r') as f:
        content = f.read()
    
    # Find all variables in format {{path.to.color}}
    variables = re.findall(r'\{\{([^}]+)\}\}', content)
    
    # Replace each variable with actual color value
    for var in variables:
        # Extract theme context if the path starts with dark/light
        theme_context = None
        if var.startswith(('dark.', 'light.')):
            theme_context = var.split('.')[0]
        
        color_value = get_nested_color(colors, var, 5, theme_context)
        if color_value:
            if strip_hash and isinstance(color_value, str) and color_value.startswith('#'):
                color_value = color_value[1:]
            content = content.replace(f'{{{{{var}}}}}', color_value)
        else:
            print(f"Warning: Color not found for path '{var}'", file=sys.stderr)
    
    # Write output
    os.makedirs(os.path.dirname(output_file), exist_ok=True)
    with open(output_file, 'w') as f:
        f.write(content)
    
    print(f"Generated: {output_file}")

def emit_json(colors_file):
    """Print colors.json with the derived surface ladder injected, references
    left intact. The theme editor consumes this so the ladder has a single
    source of truth (this file) rather than a reimplementation in TypeScript."""
    with open(colors_file, 'r') as f:
        data = json.load(f)
    data['themes'] = _add_derived(data['themes'])
    json.dump(data, sys.stdout)

def main():
    if len(sys.argv) >= 3 and sys.argv[1] == '--emit-json':
        emit_json(sys.argv[2])
        return

    if len(sys.argv) < 5:
        print("Usage: theme-processor.py <template_file> <colors_file> <theme_mode> <output_file> [tool_name]")
        print("   or: theme-processor.py --emit-json <colors_file>")
        sys.exit(1)
    
    template_file, colors_file, theme_mode, output_file = sys.argv[1:5]
    tool_name = sys.argv[5] if len(sys.argv) > 5 else None
    
    try:
        process_template(template_file, colors_file, theme_mode, output_file, tool_name)
    except Exception as e:
        print(f"Error: {e}", file=sys.stderr)
        sys.exit(1)

if __name__ == "__main__":
    main()