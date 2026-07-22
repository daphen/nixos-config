#!/usr/bin/env python3

import json
import sys
import re
import os
from pathlib import Path

import math

def _round_half_even(x):
    f = math.floor(x)
    d = x - f
    if d < 0.5: return f
    if d > 0.5: return f + 1
    return f if f % 2 == 0 else f + 1

def _hex_to_oklch(h):
    def lin(c):
        c /= 255
        return c / 12.92 if c <= 0.04045 else ((c + 0.055) / 1.055) ** 2.4
    r, g, b = (lin(int(h[i:i + 2], 16)) for i in (1, 3, 5))
    l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b
    m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b
    s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b
    l_, m_, s_ = l ** (1 / 3), m ** (1 / 3), s ** (1 / 3)
    L = 0.2104542553 * l_ + 0.7936177850 * m_ - 0.0040720468 * s_
    a = 1.9779984951 * l_ - 2.4285922050 * m_ + 0.4505937099 * s_
    bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.8086757660 * s_
    return L, math.hypot(a, bb), math.degrees(math.atan2(bb, a)) % 360

def _oklch_to_hex(L, C, H):
    a = C * math.cos(math.radians(H))
    b = C * math.sin(math.radians(H))
    l_ = L + 0.3963377774 * a + 0.2158037573 * b
    m_ = L - 0.1055613458 * a - 0.0638541728 * b
    s_ = L - 0.0894841775 * a - 1.2914855480 * b
    l, m, s = l_ ** 3, m_ ** 3, s_ ** 3
    r = +4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s
    g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s
    bl = -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    def enc(x):
        x = max(0.0, min(1.0, x))
        x = 12.92 * x if x <= 0.0031308 else 1.055 * x ** (1 / 2.4) - 0.055
        return max(0, min(255, _round_half_even(x * 255)))
    return '#{:02X}{:02X}{:02X}'.format(enc(r), enc(g), enc(bl))

# Elevation ladder: every surface is background.primary shifted in OKLCH.
# Authored in colors.json ("surfaces".{mode}) as per-step lightness deltas
# (dL) plus per-step chroma/hue drift (dC/dH, applied x step index, so higher
# surfaces drift more). surface == surface1. Defaults reproduce the previously
# hand-authored ladder. OKLCH keeps equal dL steps perceptually even.
_LADDER_FALLBACK = {
    'dark':  {'dL': [0.0088, 0.0131, 0.0921, 0.1394], 'dC': [0.0] * 4, 'dH': [0.0] * 4},
    'light': {'dL': [-0.0119, -0.0239, -0.0539, -0.0811], 'dC': [0.0] * 4, 'dH': [0.0] * 4},
}

def _per_step(v, n):
    """Accept either a per-step list or a scalar broadcast across n steps."""
    if isinstance(v, (list, tuple)):
        return [v[i] if i < len(v) else 0.0 for i in range(n)]
    return [v] * n

def _add_derived(themes, surfaces=None):
    surfaces = surfaces or {}
    for mode in ('light', 'dark'):
        if mode not in themes:
            continue
        bg = themes[mode].get('background', {})
        primary = bg.get('primary')
        if not primary:
            continue
        cfg = surfaces.get(mode) or _LADDER_FALLBACK[mode]
        dLs = cfg.get('dL', _LADDER_FALLBACK[mode]['dL'])
        n = len(dLs)
        dCs = _per_step(cfg.get('dC', 0.0), n)
        dHs = _per_step(cfg.get('dH', 0.0), n)
        L0, C0, H0 = _hex_to_oklch(primary)
        for i, dL in enumerate(dLs):
            bg[f'surface{i}'] = _oklch_to_hex(
                L0 + dL, max(0.0, C0 + dCs[i]), H0 + dHs[i])
        # Canonical mid surface for consumers predating the numbered ladder.
        bg['surface'] = bg.get('surface1', primary)
    return themes

def load_colors(colors_file, theme_mode):
    """Load colors from JSON file for specified theme mode."""
    with open(colors_file, 'r') as f:
        data = json.load(f)
    return _add_derived(data['themes'], data.get('surfaces'))[theme_mode]

def load_all_colors(colors_file):
    """Load all colors from JSON file."""
    with open(colors_file, 'r') as f:
        data = json.load(f)
    return _add_derived(data['themes'], data.get('surfaces'))

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
    data['themes'] = _add_derived(data['themes'], data.get('surfaces'))
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