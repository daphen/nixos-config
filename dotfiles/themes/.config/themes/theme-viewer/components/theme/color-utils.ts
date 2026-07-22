import { HSL, ColorTheme } from './types';

export function hexToHsl(hex: string): HSL {
  const r = parseInt(hex.slice(1, 3), 16) / 255;
  const g = parseInt(hex.slice(3, 5), 16) / 255;
  const b = parseInt(hex.slice(5, 7), 16) / 255;

  const max = Math.max(r, g, b);
  const min = Math.min(r, g, b);
  let h = 0;
  let s = 0;
  const l = (max + min) / 2;

  if (max !== min) {
    const d = max - min;
    s = l > 0.5 ? d / (2 - max - min) : d / (max + min);
    switch (max) {
      case r:
        h = (g - b) / d + (g < b ? 6 : 0);
        break;
      case g:
        h = (b - r) / d + 2;
        break;
      case b:
        h = (r - g) / d + 4;
        break;
    }
    h /= 6;
  }

  return { h: h * 360, s: s * 100, l: l * 100 };
}

export function hslToHex(h: number, s: number, l: number): string {
  h /= 360;
  s /= 100;
  l /= 100;

  const hue2rgb = (p: number, q: number, t: number) => {
    if (t < 0) t += 1;
    if (t > 1) t -= 1;
    if (t < 1 / 6) return p + (q - p) * 6 * t;
    if (t < 1 / 2) return q;
    if (t < 2 / 3) return p + (q - p) * (2 / 3 - t) * 6;
    return p;
  };

  if (s === 0) {
    const grey = Math.round(l * 255);
    return `#${grey.toString(16).padStart(2, "0").repeat(3)}`;
  }

  const q = l < 0.5 ? l * (1 + s) : l + s - l * s;
  const p = 2 * l - q;
  const r = Math.round(hue2rgb(p, q, h + 1 / 3) * 255);
  const g = Math.round(hue2rgb(p, q, h) * 255);
  const b = Math.round(hue2rgb(p, q, h - 1 / 3) * 255);

  return `#${r.toString(16).padStart(2, "0")}${g.toString(16).padStart(2, "0")}${b.toString(16).padStart(2, "0")}`;
}

// Preview mirror of theme-processor.py's OKLCH surface derivation. The knobs
// (colors.json "surfaces") are the single source; Python stays authoritative
// for generated files. This recomputes the ladder live so sliders respond
// instantly — parity with Python is byte-verified.
export interface SurfaceDelta {
  dL: number[];
  dC: number[];
  dH: number[];
  dBorder: number[]; // per-surface hairline alpha (fg @ a); webapp preview
}

export const SURFACE_DELTA_FALLBACK: Record<"dark" | "light", SurfaceDelta> = {
  dark: {
    dL: [0.0088, 0.0131, 0.0921, 0.1394],
    dC: [0, 0, 0, 0],
    dH: [0, 0, 0, 0],
    dBorder: [0.15, 0.15, 0.15, 0.15],
  },
  light: {
    dL: [-0.0119, -0.0239, -0.0539, -0.0811],
    dC: [0, 0, 0, 0],
    dH: [0, 0, 0, 0],
    dBorder: [0.12, 0.12, 0.12, 0.12],
  },
};

function roundHalfEven(n: number): number {
  const f = Math.floor(n);
  const diff = n - f;
  if (diff < 0.5) return f;
  if (diff > 0.5) return f + 1;
  return f % 2 === 0 ? f : f + 1;
}

function hexToOklch(h: string): [number, number, number] {
  const lin = (c: number) => {
    c /= 255;
    return c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4);
  };
  const [r, g, b] = [1, 3, 5].map((i) => lin(parseInt(h.slice(i, i + 2), 16)));
  const l = 0.4122214708 * r + 0.5363325363 * g + 0.0514459929 * b;
  const m = 0.2119034982 * r + 0.6806995451 * g + 0.1073969566 * b;
  const s = 0.0883024619 * r + 0.2817188376 * g + 0.6299787005 * b;
  const l_ = Math.cbrt(l), m_ = Math.cbrt(m), s_ = Math.cbrt(s);
  const L = 0.2104542553 * l_ + 0.793617785 * m_ - 0.0040720468 * s_;
  const a = 1.9779984951 * l_ - 2.428592205 * m_ + 0.4505937099 * s_;
  const bb = 0.0259040371 * l_ + 0.7827717662 * m_ - 0.808675766 * s_;
  return [L, Math.hypot(a, bb), ((Math.atan2(bb, a) * 180) / Math.PI + 360) % 360];
}

function oklchToHex(L: number, C: number, H: number): string {
  const a = C * Math.cos((H * Math.PI) / 180);
  const b = C * Math.sin((H * Math.PI) / 180);
  const l_ = L + 0.3963377774 * a + 0.2158037573 * b;
  const m_ = L - 0.1055613458 * a - 0.0638541728 * b;
  const s_ = L - 0.0894841775 * a - 1.291485548 * b;
  const l = l_ ** 3, m = m_ ** 3, s = s_ ** 3;
  const r = 4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s;
  const g = -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s;
  const bl = -0.0041960863 * l - 0.7034186147 * m + 1.707614701 * s;
  const enc = (x: number) => {
    x = Math.max(0, Math.min(1, x));
    x = x <= 0.0031308 ? 12.92 * x : 1.055 * Math.pow(x, 1 / 2.4) - 0.055;
    return Math.max(0, Math.min(255, roundHalfEven(x * 255)));
  };
  return `#${[enc(r), enc(g), enc(bl)].map((v) => v.toString(16).padStart(2, "0")).join("")}`.toUpperCase();
}

// Returns surface0..3 (and surface == surface1) derived from primary in OKLCH.
export function deriveSurfaces(primary: string, delta: SurfaceDelta): Record<string, string> {
  const [L0, C0, H0] = hexToOklch(primary);
  const out: Record<string, string> = {};
  delta.dL.forEach((dL, i) => {
    out[`surface${i}`] = oklchToHex(
      L0 + dL,
      Math.max(0, C0 + (delta.dC[i] ?? 0)),
      H0 + (delta.dH[i] ?? 0),
    );
  });
  out.surface = out.surface1 ?? primary;
  return out;
}

export function resolveColor(colorValue: string, theme: any): string {
  if (colorValue.startsWith("#")) {
    return colorValue;
  }

  const parts = colorValue.split(".");
  if (parts.length === 2) {
    const [category, name] = parts;
    return theme[category]?.[name] || colorValue;
  }

  return colorValue;
}

export function createResolvedTheme(rawTheme: any): ColorTheme {
  const resolved = JSON.parse(JSON.stringify(rawTheme));

  // Resolve semantic colors
  if (resolved.semantic) {
    for (const [key, value] of Object.entries(resolved.semantic)) {
      if (typeof value === "string") {
        resolved.semantic[key] = resolveColor(value as string, rawTheme);
      }
    }
  }

  // Resolve terminal colors
  if (resolved.terminal) {
    for (const [key, value] of Object.entries(resolved.terminal)) {
      if (typeof value === "string") {
        resolved.terminal[key] = resolveColor(value as string, rawTheme);
      }
    }
  }

  return resolved;
}