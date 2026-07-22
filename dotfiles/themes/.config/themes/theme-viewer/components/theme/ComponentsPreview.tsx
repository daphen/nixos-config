import { ColorTheme } from './types';

interface ComponentsPreviewProps {
  theme: ColorTheme;
  mode: 'light' | 'dark';
  onColorClick: (category: string, name: string, color: string) => void;
}

const SANS = "'Geist', ui-sans-serif, system-ui, sans-serif";
const MONO = "'BerkeleyMono Nerd Font', 'Berkeley Mono', ui-monospace, monospace";

function rgba(hex: string, a: number): string {
  const n = parseInt(hex.slice(1), 16);
  return `rgba(${(n >> 16) & 255}, ${(n >> 8) & 255}, ${n & 255}, ${a})`;
}

export function ComponentsPreview({ theme, mode, onColorClick }: ComponentsPreviewProps) {
  const b = theme.background;
  const fg = theme.foreground;
  // Theme.qml: hairline = fg @ semantic.hairpin_alpha (not a hardcode).
  const hairlineAlpha =
    parseFloat(String(theme.semantic.hairpin_alpha)) || (mode === 'dark' ? 0.15 : 0.12);
  const hairline = rgba(fg.primary, hairlineAlpha);
  const capBg = mode === 'light' ? b.primary : b.surface2 || b.selection;
  const capText = fg.muted;

  const click =
    (category: string, name: string) =>
    (e: React.MouseEvent) => {
      e.stopPropagation();
      const color = (theme[category as keyof ColorTheme] as Record<string, string>)[name];
      if (color) onColorClick(category, name, color);
    };

  const KeyCap = ({
    children,
    small,
    ghost,
  }: {
    children: React.ReactNode;
    small?: boolean;
    ghost?: boolean;
  }) => (
    <span
      style={{
        display: 'inline-flex',
        alignItems: 'center',
        justifyContent: 'center',
        minWidth: small ? 18 : 22,
        height: small ? 18 : 22,
        padding: small ? '0 4px' : '0 6px',
        borderRadius: small ? 5 : 7,
        backgroundColor: ghost ? 'transparent' : capBg,
        border: `1px solid ${hairline}`,
        color: capText,
        fontFamily: MONO,
        fontSize: small ? 10 : 11,
        fontWeight: 500,
      }}
    >
      {children}
    </span>
  );

  // A titled specimen cell.
  const Spec = ({ name, note, children }: { name: string; note: string; children: React.ReactNode }) => (
    <div
      style={{
        borderRadius: 14,
        border: `1px solid ${hairline}`,
        backgroundColor: b.surface0,
        padding: 18,
      }}
    >
      <div className="flex items-baseline justify-between mb-3">
        <span style={{ color: fg.primary, fontSize: 13, fontWeight: 600, fontFamily: MONO }}>{name}</span>
        <span style={{ color: fg.subtle, fontSize: 11 }}>{note}</span>
      </div>
      <div className="flex items-center gap-3 flex-wrap">{children}</div>
    </div>
  );

  const badges: [string, string][] = [
    ['blue', theme.accent.blue],
    ['green', theme.accent.green],
    ['orange', theme.accent.orange],
    ['red', theme.accent.red],
  ];

  return (
    <div className="p-6" style={{ backgroundColor: b.tertiary, fontFamily: SANS }}>
      <div className="grid gap-4 md:grid-cols-2">
        {/* Card */}
        <Spec name="Card" note="radiusCard 24 · bg">
          <div
            className="cursor-pointer"
            style={{
              width: '100%',
              borderRadius: 24,
              backgroundColor: b.primary,
              border: `1px solid ${hairline}`,
              padding: 16,
            }}
            onClick={click('background', 'primary')}
            title="background.primary"
          >
            <div style={{ color: fg.primary, fontSize: 14, fontWeight: 500 }}>Floating surface</div>
            <div style={{ color: fg.muted, fontSize: 12, marginTop: 4 }}>
              nested boxes inset 14, radiusInner 10
            </div>
            <div
              className="mt-3"
              style={{
                borderRadius: 10,
                backgroundColor: b.surface,
                border: `1px solid ${hairline}`,
                padding: '8px 12px',
                color: fg.secondary,
                fontSize: 12,
              }}
            >
              inner card · surface
            </div>
          </div>
        </Spec>

        {/* KeyCap */}
        <Spec name="KeyCap" note="raised · hairline ring">
          <KeyCap>esc</KeyCap>
          <KeyCap>↵</KeyCap>
          <KeyCap>⇥</KeyCap>
          <KeyCap>ctrl</KeyCap>
          <KeyCap small>j</KeyCap>
          <KeyCap small>k</KeyCap>
          <KeyCap ghost>ghost</KeyCap>
        </Spec>

        {/* CapLabel */}
        <Spec name="CapLabel" note="muted action-ink">
          <div className="flex items-center gap-2">
            <KeyCap>↵</KeyCap>
            <span style={{ color: fg.muted, fontFamily: MONO, fontSize: 11 }}>open</span>
          </div>
          <div className="flex items-center gap-2">
            <KeyCap>ctrl</KeyCap>
            <KeyCap>w</KeyCap>
            <span style={{ color: fg.muted, fontFamily: MONO, fontSize: 11 }}>delete</span>
          </div>
        </Spec>

        {/* FeedbackPill */}
        <Spec name="FeedbackPill" note="inverted ink · pulsing dot">
          <div
            style={{
              display: 'inline-flex',
              alignItems: 'center',
              gap: 8,
              height: 32,
              padding: '0 14px',
              borderRadius: 8,
              backgroundColor: fg.primary,
              border: `1px solid ${hairline}`,
            }}
          >
            <span
              className="qs-pulse cursor-pointer"
              style={{ width: 8, height: 8, borderRadius: 4, backgroundColor: theme.semantic.cursor }}
              onClick={click('semantic', 'cursor')}
              title="semantic.cursor"
            />
            <span style={{ color: b.primary, fontFamily: MONO, fontSize: 13 }}>trashed — u undoes</span>
          </div>
        </Spec>

        {/* Badges */}
        <Spec name="Badge" note="tint @ 0.16 · pill">
          {badges.map(([name, color]) => (
            <button
              key={name}
              onClick={click('accent', name)}
              title={`accent.${name}`}
              className="cursor-pointer"
              style={{
                padding: '2px 10px',
                borderRadius: 5,
                backgroundColor: rgba(color, 0.16),
                color,
                fontSize: 11,
                fontWeight: 600,
              }}
            >
              {name}
            </button>
          ))}
        </Spec>

        {/* Section header + loading dots */}
        <Spec name="Section / Loading" note="divider · dots">
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
          <span style={{ width: 1, height: 16, backgroundColor: hairline, display: 'inline-block' }} />
          <span className="flex items-center gap-1.5">
            {[0, 1, 2].map((i) => (
              <span
                key={i}
                className="qs-dot"
                style={{
                  width: 7,
                  height: 7,
                  borderRadius: 3.5,
                  backgroundColor: fg.muted,
                  animationDelay: `${i * 0.15}s`,
                }}
              />
            ))}
          </span>
        </Spec>
      </div>

      <style>{`
        @keyframes qs-pulse-kf { 0%,100% { opacity: 1 } 50% { opacity: .25 } }
        .qs-pulse { animation: qs-pulse-kf 1.1s ease-in-out infinite; }
        @keyframes qs-dot-kf { 0%,100% { opacity: .25 } 50% { opacity: 1 } }
        .qs-dot { animation: qs-dot-kf .9s ease-in-out infinite; }
      `}</style>
    </div>
  );
}
