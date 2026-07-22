import { ColorTheme } from './types';
import { deriveSurfaces, SurfaceDelta } from './color-utils';

interface SurfacePreviewProps {
  theme: ColorTheme;
  mode: 'light' | 'dark';
  delta: SurfaceDelta;
  onDLChange: (index: number, value: number) => void;
  onDCChange: (value: number) => void;
  onDHChange: (value: number) => void;
  onColorClick: (category: string, name: string, color: string) => void;
}

const SANS = "'Geist', ui-sans-serif, system-ui, sans-serif";
const MONO = "'BerkeleyMono Nerd Font', 'Berkeley Mono', ui-monospace, monospace";

function rgba(hex: string, a: number): string {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
}

export function SurfacePreview({
  theme,
  mode,
  delta,
  onDLChange,
  onDCChange,
  onDHChange,
  onColorClick,
}: SurfacePreviewProps) {
  const b = theme.background;
  const fg = theme.foreground;
  // Live-derive the ladder from primary + the OKLCH knobs so sliders update
  // instantly; primary is the sole editable anchor.
  const surf = deriveSurfaces(b.primary, delta);
  // Theme.qml: hairline = fg @ semantic.hairpin_alpha. panelBorder is a
  // separate literal in Picker.qml (fg @ 0.10 dark / 0.15 light).
  const hairlineAlpha =
    parseFloat(String(theme.semantic.hairpin_alpha)) || (mode === 'dark' ? 0.15 : 0.12);
  const hairline = rgba(fg.primary, hairlineAlpha);
  const panelBorder = rgba(fg.primary, mode === 'dark' ? 0.1 : 0.15);
  const capBg = mode === 'light' ? b.primary : surf.surface2;

  const click =
    (category: string, name: string) =>
    (e: React.MouseEvent) => {
      e.stopPropagation();
      const color = (theme[category as keyof ColorTheme] as Record<string, string>)[name];
      if (color) onColorClick(category, name, color);
    };

  const Cap = ({ children }: { children: React.ReactNode }) => (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        minWidth: 22,
        height: 22,
        padding: '0 6px',
        borderRadius: 7,
        backgroundColor: capBg,
        border: `1px solid ${hairline}`,
        color: fg.muted,
        fontFamily: MONO,
        fontSize: 11,
        fontWeight: 500,
      }}
    >
      {children}
    </span>
  );

  const ladder: { name: string; color: string; derived: boolean; editKey?: string }[] = [
    { name: 'primary', color: b.primary, derived: false, editKey: 'primary' },
    { name: 'surface0', color: surf.surface0, derived: true },
    { name: 'surface1', color: surf.surface1, derived: true },
    { name: 'surface2', color: surf.surface2, derived: true },
    { name: 'surface3', color: surf.surface3, derived: true },
  ];

  const rows = [
    { label: 'colors.json', sub: 'edited 2m ago', badge: 'file', selected: true },
    { label: 'theme-manager.sh', sub: 'switch dark', badge: 'exec', selected: false },
    { label: 'wallpaper-studio.qml', sub: 'GPU shader editor', badge: 'qml', selected: false },
  ];

  return (
    <div className="p-6" style={{ backgroundColor: b.tertiary, fontFamily: SANS }}>
      {/* Elevation ladder */}
      <div className="flex items-center gap-2 mb-5 flex-wrap">
        <span className="text-xs uppercase tracking-wide mr-1" style={{ color: fg.muted }}>
          Elevation
        </span>
        {ladder.map((s) => (
          <button
            key={s.name}
            onClick={s.editKey ? click('background', s.editKey) : undefined}
            title={s.editKey ? `background.${s.editKey}` : `${s.name} (derived)`}
            className={s.editKey ? 'cursor-pointer' : 'cursor-default'}
            style={{
              display: 'flex',
              alignItems: 'center',
              gap: 8,
              padding: '4px 10px 4px 4px',
              borderRadius: 8,
              backgroundColor: surf.surface0,
              border: `1px solid ${hairline}`,
            }}
          >
            <span
              style={{
                width: 22,
                height: 22,
                borderRadius: 6,
                backgroundColor: s.color,
                border: `1px solid ${hairline}`,
              }}
            />
            <span style={{ color: fg.secondary, fontSize: 12 }}>{s.name}</span>
            <span style={{ color: fg.subtle, fontFamily: MONO, fontSize: 11 }}>{s.color}</span>
          </button>
        ))}
      </div>

      {/* Derivation controls (OKLCH deltas from primary) */}
      <div
        className="mb-5"
        style={{
          borderRadius: 14,
          border: `1px solid ${hairline}`,
          backgroundColor: surf.surface0,
          padding: 16,
        }}
      >
        <div className="flex items-baseline justify-between mb-3">
          <span style={{ color: fg.muted, fontSize: 11, fontWeight: 600, textTransform: 'uppercase', letterSpacing: '1.2px' }}>
            Derivation · OKLCH · {mode}
          </span>
          <span style={{ color: fg.subtle, fontSize: 11 }}>surface = primary shifted</span>
        </div>

        {[0, 1, 2, 3].map((i) => (
          <label key={i} className="flex items-center gap-3 mb-2">
            <span style={{ width: 66, color: fg.secondary, fontSize: 12, fontFamily: MONO }}>surface{i}</span>
            <input
              type="range"
              min={-0.35}
              max={0.35}
              step={0.001}
              value={delta.dL[i]}
              onChange={(e) => onDLChange(i, parseFloat(e.target.value))}
              style={{ flex: 1, accentColor: theme.accent.blue }}
            />
            <span style={{ width: 56, textAlign: 'right', color: fg.muted, fontSize: 11, fontFamily: MONO }}>
              ΔL {delta.dL[i] >= 0 ? '+' : ''}{delta.dL[i].toFixed(3)}
            </span>
            <span style={{ width: 62, textAlign: 'right', color: fg.subtle, fontSize: 11, fontFamily: MONO }}>
              {surf[`surface${i}`]}
            </span>
          </label>
        ))}

        <div className="flex items-center gap-3 mt-3 pt-3" style={{ borderTop: `1px solid ${hairline}` }}>
          <label className="flex items-center gap-2 flex-1">
            <span style={{ width: 66, color: fg.secondary, fontSize: 12, fontFamily: MONO }}>chroma</span>
            <input
              type="range"
              min={0}
              max={0.06}
              step={0.001}
              value={delta.dC}
              onChange={(e) => onDCChange(parseFloat(e.target.value))}
              style={{ flex: 1, accentColor: theme.accent.blue }}
            />
            <span style={{ width: 48, textAlign: 'right', color: fg.muted, fontSize: 11, fontFamily: MONO }}>
              {delta.dC.toFixed(3)}
            </span>
          </label>
          <label className="flex items-center gap-2 flex-1">
            <span style={{ width: 40, color: fg.secondary, fontSize: 12, fontFamily: MONO }}>hue</span>
            <input
              type="range"
              min={-30}
              max={30}
              step={1}
              value={delta.dH}
              onChange={(e) => onDHChange(parseFloat(e.target.value))}
              style={{ flex: 1, accentColor: theme.accent.blue }}
            />
            <span style={{ width: 48, textAlign: 'right', color: fg.muted, fontSize: 11, fontFamily: MONO }}>
              {delta.dH >= 0 ? '+' : ''}{delta.dH.toFixed(0)}°
            </span>
          </label>
        </div>
      </div>

      {/* Quickshell picker mock */}
      <div
        className="mx-auto"
        style={{
          maxWidth: 560,
          backgroundColor: b.primary,
          borderRadius: 24,
          border: `1px solid ${panelBorder}`,
          boxShadow: `0 24px 60px -12px ${rgba('#000000', mode === 'dark' ? 0.6 : 0.25)}`,
          overflow: 'hidden',
          cursor: 'pointer',
        }}
        onClick={click('background', 'primary')}
        title="background.primary (panel)"
      >
        {/* Search field */}
        <div className="px-3.5 pt-3.5 pb-1.5">
          <div
            className="flex items-center gap-2.5"
            style={{
              height: 44,
              padding: '0 12px',
              borderRadius: 15,
              backgroundColor: surf.surface1,
              border: `1px solid ${hairline}`,
            }}
            title="surface1 (field, derived)"
          >
            <span style={{ color: fg.muted, fontFamily: MONO, fontSize: 15 }}>⌕</span>
            <span style={{ color: rgba(fg.primary, 0.5), fontSize: 16, flex: 1 }}>Search…</span>
            <Cap>esc</Cap>
          </div>
        </div>

        {/* Section divider */}
        <div className="flex items-center justify-between px-7 pt-3 pb-1.5">
          <span
            style={{
              color: fg.muted,
              fontSize: 11,
              fontWeight: 600,
              textTransform: 'uppercase',
              letterSpacing: '1.2px',
            }}
          >
            Recent
          </span>
          <span style={{ color: fg.muted, opacity: 0.7, fontSize: 11 }}>{rows.length}</span>
        </div>

        {/* Rows */}
        <div className="px-3.5 pb-2 space-y-0.5">
          {rows.map((r) => (
            <div
              key={r.label}
              className="flex items-center justify-between cursor-pointer"
              style={{
                padding: '0 14px',
                height: 56,
                borderRadius: 13,
                backgroundColor: r.selected ? b.selection : 'transparent',
                border: `1px solid ${r.selected ? hairline : 'transparent'}`,
              }}
              onClick={r.selected ? click('background', 'selection') : undefined}
              title={r.selected ? 'background.selection (active row)' : undefined}
            >
              <div className="flex flex-col gap-0.5">
                <span style={{ color: fg.primary, fontSize: 15, fontWeight: 500 }}>{r.label}</span>
                <div className="flex items-center gap-1.5">
                  <span style={{ color: fg.muted, fontSize: 12 }}>{r.sub}</span>
                  <span
                    style={{
                      padding: '1px 6px',
                      borderRadius: 5,
                      backgroundColor: rgba(theme.accent.blue, 0.16),
                      color: theme.accent.blue,
                      fontSize: 10,
                      fontWeight: 600,
                    }}
                  >
                    {r.badge}
                  </span>
                </div>
              </div>
              {r.selected && (
                <span
                  className="cursor-pointer"
                  style={{ width: 6, height: 6, borderRadius: 3, backgroundColor: theme.semantic.cursor }}
                  onClick={click('semantic', 'cursor')}
                  title="semantic.cursor"
                />
              )}
            </div>
          ))}
        </div>

        {/* Footer */}
        <div
          className="flex items-center gap-1.5 px-3.5"
          style={{
            height: 52,
            backgroundColor: surf.surface0,
            borderTop: `1px solid ${hairline}`,
          }}
        >
          <Cap>j</Cap>
          <Cap>k</Cap>
          <span style={{ color: fg.muted, fontSize: 12, marginRight: 8 }}>move</span>
          <Cap>↵</Cap>
          <span style={{ color: fg.muted, fontSize: 12 }}>open</span>
        </div>
      </div>
    </div>
  );
}
