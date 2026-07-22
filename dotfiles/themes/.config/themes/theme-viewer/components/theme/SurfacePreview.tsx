import { useState, useRef, useEffect } from 'react';
import { ColorTheme } from './types';
import { deriveSurfaces, SurfaceDelta, SURFACE_DELTA_FALLBACK } from './color-utils';
import { Button } from '@/components/ui/button';

type Channel = 'dL' | 'dC' | 'dH' | 'dBorder';

// Slider whose value eases toward the pointer instead of snapping to it, so
// dragging feels soft — you pull a little past and it glides in. Module-scope
// (stable identity) so parent re-renders on each eased frame never remount it.
function DampedSlider({
  value, min, max, step, onChange, label, fmt, defaultValue,
  accent, track, ring, thumbBg, grip, tick, labelColor, valueColor, mono,
}: {
  value: number; min: number; max: number; step: number;
  onChange: (v: number) => void; label: string; fmt: (v: number) => string;
  defaultValue: number;
  accent: string; track: string; ring: string; thumbBg: string; grip: string; tick: string;
  labelColor: string; valueColor: string; mono: string;
}) {
  const trackRef = useRef<HTMLDivElement>(null);
  const dragging = useRef(false);
  const target = useRef(value);
  const disp = useRef(value);
  const raf = useRef<number | null>(null);
  const [display, setDisplay] = useState(value);
  const [pressed, setPressed] = useState(false);

  // Adopt external changes (reset, mode switch) only when idle.
  useEffect(() => {
    if (!dragging.current && raf.current == null) {
      disp.current = value;
      target.current = value;
      setDisplay(value);
    }
  }, [value]);
  useEffect(() => () => { if (raf.current != null) cancelAnimationFrame(raf.current); }, []);

  const clamp = (v: number) => Math.max(min, Math.min(max, v));
  const snap = (v: number) =>
    clamp(parseFloat((Math.round((v - min) / step) * step + min).toFixed(6)));
  const posToVal = (clientX: number) => {
    const r = trackRef.current!.getBoundingClientRect();
    const t = Math.max(0, Math.min(1, (clientX - r.left) / r.width));
    return min + t * (max - min);
  };

  const loop = () => {
    const k = 0.11; // damping: lower = softer / more trailing
    const cur = disp.current;
    const next = cur + (target.current - cur) * k;
    const settled = Math.abs(target.current - next) < (max - min) * 0.0004;
    const v = settled ? target.current : next;
    disp.current = v;
    setDisplay(v);
    onChange(snap(v));
    if (settled && !dragging.current) { raf.current = null; return; }
    raf.current = requestAnimationFrame(loop);
  };
  const ensureLoop = () => { if (raf.current == null) raf.current = requestAnimationFrame(loop); };

  const down = (e: React.PointerEvent) => {
    dragging.current = true;
    setPressed(true);
    e.currentTarget.setPointerCapture(e.pointerId);
    target.current = clamp(posToVal(e.clientX));
    ensureLoop();
  };
  const move = (e: React.PointerEvent) => {
    if (!dragging.current) return;
    target.current = clamp(posToVal(e.clientX));
    ensureLoop();
  };
  const up = (e: React.PointerEvent) => {
    dragging.current = false;
    setPressed(false);
    try { e.currentTarget.releasePointerCapture(e.pointerId); } catch {}
    ensureLoop();
  };

  const pct = ((display - min) / (max - min)) * 100;
  const defPct = ((defaultValue - min) / (max - min)) * 100;
  return (
    <label className="flex items-center gap-3 mb-2.5" style={{ userSelect: 'none' }}>
      <span style={{ width: 64, color: labelColor, fontSize: 12, fontFamily: mono }}>{label}</span>
      <div
        ref={trackRef}
        onPointerDown={down}
        onPointerMove={move}
        onPointerUp={up}
        style={{
          position: 'relative',
          flex: 1,
          height: 24,
          display: 'flex',
          alignItems: 'center',
          cursor: pressed ? 'grabbing' : 'grab',
          touchAction: 'none',
        }}
      >
        {/* recessed track */}
        <div
          style={{
            position: 'absolute',
            left: 0,
            right: 0,
            height: 6,
            borderRadius: 999,
            background: track,
            boxShadow: 'inset 0 1px 2px rgba(0,0,0,.28)',
          }}
        />
        {/* filled portion */}
        <div
          style={{
            position: 'absolute',
            left: 0,
            width: `${pct}%`,
            height: 6,
            borderRadius: 999,
            background: accent,
          }}
        />
        {/* default marker */}
        <div
          title="default"
          style={{
            position: 'absolute',
            left: `${defPct}%`,
            transform: 'translateX(-50%)',
            width: 2,
            height: 12,
            borderRadius: 1,
            background: tick,
          }}
        />
        {/* fader-grip thumb */}
        <div
          style={{
            position: 'absolute',
            left: `${pct}%`,
            transform: `translateX(-50%) scale(${pressed ? 1.12 : 1})`,
            transition: 'transform 120ms ease',
            width: 18,
            height: 24,
            borderRadius: 8,
            background: thumbBg,
            border: `1px solid ${ring}`,
            boxShadow: '0 2px 6px rgba(0,0,0,.4)',
            cursor: pressed ? 'grabbing' : 'grab',
            display: 'flex',
            alignItems: 'center',
            justifyContent: 'center',
            gap: 3,
          }}
        >
          <span style={{ width: 1.5, height: 10, borderRadius: 1, background: grip }} />
          <span style={{ width: 1.5, height: 10, borderRadius: 1, background: grip }} />
        </div>
      </div>
      <span style={{ width: 62, textAlign: 'right', color: valueColor, fontSize: 11, fontFamily: mono }}>
        {fmt(display)}
      </span>
    </label>
  );
}

interface SurfacePreviewProps {
  theme: ColorTheme;
  mode: 'light' | 'dark';
  delta: SurfaceDelta;
  onDeltaChange: (channel: Channel, index: number, value: number) => void;
  onResetSurface: (index: number) => void;
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
  onDeltaChange,
  onResetSurface,
  onColorClick,
}: SurfacePreviewProps) {
  const [openSurface, setOpenSurface] = useState<number | null>(null);
  const [showBorder, setShowBorder] = useState(true);

  const b = theme.background;
  const fg = theme.foreground;
  const surf = deriveSurfaces(b.primary, delta);
  const hairlineAlpha =
    parseFloat(String(theme.semantic.hairpin_alpha)) || (mode === 'dark' ? 0.15 : 0.12);
  const hairline = rgba(fg.primary, hairlineAlpha);
  const panelBorder = rgba(fg.primary, mode === 'dark' ? 0.1 : 0.15);
  const capBg = mode === 'light' ? b.primary : surf.surface2;
  const trackCol = rgba(fg.primary, mode === 'dark' ? 0.22 : 0.16);

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

  // index 0 = primary anchor (opens the color picker); 1..4 = surface0..3
  // (open the derivation modal, si = index - 1).
  const ladder = [
    { name: 'primary', color: b.primary, si: -1 },
    { name: 'surface0', color: surf.surface0, si: 0 },
    { name: 'surface1', color: surf.surface1, si: 1 },
    { name: 'surface2', color: surf.surface2, si: 2 },
    { name: 'surface3', color: surf.surface3, si: 3 },
  ];

  const rows = [
    { label: 'colors.json', sub: 'edited 2m ago', badge: 'file', selected: true },
    { label: 'theme-manager.sh', sub: 'switch dark', badge: 'exec', selected: false },
    { label: 'wallpaper-studio.qml', sub: 'GPU shader editor', badge: 'qml', selected: false },
  ];

  const renderSlider = ({
    label,
    channel,
    si,
    min,
    max,
    step,
    fmt,
  }: {
    label: string;
    channel: Channel;
    si: number;
    min: number;
    max: number;
    step: number;
    fmt: (v: number) => string;
  }) => (
    <DampedSlider
      key={`${channel}-${si}`}
      value={delta[channel][si]}
      defaultValue={SURFACE_DELTA_FALLBACK[mode][channel][si]}
      min={min}
      max={max}
      step={step}
      onChange={(v) => onDeltaChange(channel, si, v)}
      label={label}
      fmt={fmt}
      accent={theme.accent.blue}
      track={trackCol}
      ring={hairline}
      thumbBg={capBg}
      grip={theme.accent.blue}
      tick={rgba(fg.primary, 0.35)}
      labelColor={fg.secondary}
      valueColor={fg.muted}
      mono={MONO}
    />
  );

  return (
    <div className="p-6" style={{ backgroundColor: b.tertiary, fontFamily: SANS, paddingBottom: 96 }}>
      {/* Elevation ladder — click a surface to tune its derivation */}
      <div className="flex items-center gap-2 mb-5 flex-wrap">
        <span className="text-xs uppercase tracking-wide mr-1" style={{ color: fg.muted }}>
          Elevation
        </span>
        {ladder.map((s) => {
          const isSurface = s.si >= 0;
          return (
            <button
              key={s.name}
              onClick={
                isSurface ? () => setOpenSurface(s.si) : click('background', 'primary')
              }
              title={isSurface ? `tune ${s.name}` : 'background.primary'}
              className="cursor-pointer"
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
                  border: `1px solid ${isSurface ? rgba(fg.primary, delta.dBorder[s.si]) : hairline}`,
                }}
              />
              <span style={{ color: fg.secondary, fontSize: 12 }}>{s.name}</span>
              <span style={{ color: fg.subtle, fontFamily: MONO, fontSize: 11 }}>{s.color}</span>
            </button>
          );
        })}
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

        <div
          className="flex items-center gap-1.5 px-3.5"
          style={{ height: 52, backgroundColor: surf.surface0, borderTop: `1px solid ${hairline}` }}
        >
          <Cap>j</Cap>
          <Cap>k</Cap>
          <span style={{ color: fg.muted, fontSize: 12, marginRight: 8 }}>move</span>
          <Cap>↵</Cap>
          <span style={{ color: fg.muted, fontSize: 12 }}>open</span>
        </div>
      </div>

      {/* Per-surface derivation modal */}
      {openSurface !== null &&
        (() => {
          const si = openSurface;
          const current = surf[`surface${si}`];
          const prevName = si === 0 ? 'primary' : `surface${si - 1}`;
          const prevColor = si === 0 ? b.primary : surf[`surface${si - 1}`];
          const borderCol = rgba(fg.primary, delta.dBorder[si]);
          return (
            <div
              onClick={() => setOpenSurface(null)}
              style={{
                position: 'fixed',
                inset: 0,
                zIndex: 100,
                display: 'flex',
                alignItems: 'center',
                justifyContent: 'center',
                backgroundColor: 'rgba(0,0,0,0.45)',
                fontFamily: SANS,
              }}
            >
              <div
                onClick={(e) => e.stopPropagation()}
                style={{
                  width: 620,
                  maxWidth: '94vw',
                  borderRadius: 20,
                  backgroundColor: b.primary,
                  border: `1px solid ${panelBorder}`,
                  boxShadow: `0 30px 80px -20px rgba(0,0,0,0.6)`,
                  overflow: 'hidden',
                }}
              >
                {/* Header */}
                <div
                  className="flex items-center justify-between px-5 py-4"
                  style={{ borderBottom: `1px solid ${hairline}` }}
                >
                  <span style={{ color: fg.primary, fontSize: 15, fontWeight: 600, fontFamily: MONO }}>
                    surface{si}
                  </span>
                  <span style={{ color: fg.subtle, fontSize: 12 }}>
                    on {prevName}
                  </span>
                </div>

                {/* Preview: current surface sitting on the previous surface */}
                <div style={{ backgroundColor: prevColor, padding: 48 }}>
                  <div
                    style={{
                      borderRadius: 16,
                      backgroundColor: current,
                      border: showBorder ? `1px solid ${borderCol}` : '1px solid transparent',
                      padding: '32px 26px',
                      minHeight: 220,
                      display: 'flex',
                      flexDirection: 'column',
                      justifyContent: 'center',
                      gap: 4,
                    }}
                  >
                    <span style={{ color: fg.primary, fontSize: 14, fontWeight: 500 }}>
                      surface{si}
                    </span>
                    <span style={{ color: fg.muted, fontSize: 12, fontFamily: MONO }}>
                      {current} · on {prevName} {prevColor}
                    </span>
                  </div>
                </div>

                {/* Border toggle */}
                <div
                  className="flex items-center justify-between px-5 py-3"
                  style={{ borderTop: `1px solid ${hairline}`, borderBottom: `1px solid ${hairline}` }}
                >
                  <span style={{ color: fg.secondary, fontSize: 13 }}>Hairline border</span>
                  <button
                    onClick={() => setShowBorder((v) => !v)}
                    style={{
                      width: 44,
                      height: 24,
                      borderRadius: 12,
                      border: `1px solid ${hairline}`,
                      backgroundColor: showBorder ? theme.accent.blue : surf.surface2,
                      position: 'relative',
                      cursor: 'pointer',
                      transition: 'background-color 120ms',
                    }}
                    title={showBorder ? 'border shown' : 'border hidden'}
                  >
                    <span
                      style={{
                        position: 'absolute',
                        top: 2,
                        left: showBorder ? 22 : 2,
                        width: 18,
                        height: 18,
                        borderRadius: 9,
                        backgroundColor: b.primary,
                        transition: 'left 120ms',
                      }}
                    />
                  </button>
                </div>

                {/* Controls */}
                <div className="px-5 py-4">
                  {renderSlider({
                    label: 'lightness',
                    channel: 'dL',
                    si,
                    min: -0.35,
                    max: 0.35,
                    step: 0.001,
                    fmt: (v) => `${v >= 0 ? '+' : ''}${v.toFixed(3)}`,
                  })}
                  {renderSlider({
                    label: 'chroma',
                    channel: 'dC',
                    si,
                    min: 0,
                    max: 0.06,
                    step: 0.001,
                    fmt: (v) => v.toFixed(3),
                  })}
                  {renderSlider({
                    label: 'hue',
                    channel: 'dH',
                    si,
                    min: -30,
                    max: 30,
                    step: 1,
                    fmt: (v) => `${v >= 0 ? '+' : ''}${v.toFixed(0)}°`,
                  })}
                  {renderSlider({
                    label: 'border',
                    channel: 'dBorder',
                    si,
                    min: 0,
                    max: 0.4,
                    step: 0.005,
                    fmt: (v) => v.toFixed(3),
                  })}

                  <div className="flex items-center justify-between mt-4">
                    <Button variant="ghost" size="sm" onClick={() => onResetSurface(si)}>
                      Reset to default
                    </Button>
                    <Button size="sm" onClick={() => setOpenSurface(null)}>
                      Done
                    </Button>
                  </div>
                </div>
              </div>
            </div>
          );
        })()}
    </div>
  );
}
