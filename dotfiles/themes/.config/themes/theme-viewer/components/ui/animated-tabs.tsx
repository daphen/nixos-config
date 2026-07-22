'use client';

import { useId } from 'react';
import { LayoutGroup, motion } from 'framer-motion';

// Segmented control: a rounded track with a sliding filled pill behind the
// active tab (motion layoutId). Colors come from the live-theme tokens.
export function AnimatedTabs({
  tabs,
  value,
  onValueChange,
}: {
  tabs: { value: string; label: string }[];
  value: string;
  onValueChange: (value: string) => void;
}) {
  const uid = useId();
  return (
    <LayoutGroup id={uid}>
      <div className="bg-secondary border-input inline-flex items-center gap-1 rounded-xl border p-1">
        {tabs.map((t) => {
          const active = t.value === value;
          return (
            <button
              key={t.value}
              onClick={() => onValueChange(t.value)}
              className="relative cursor-pointer rounded-lg px-4 py-1.5 text-sm font-medium transition-colors"
              style={{ color: active ? 'var(--foreground)' : 'var(--muted-foreground)' }}
            >
              {active && (
                <motion.span
                  layoutId={`${uid}-segment`}
                  className="bg-accent border-input absolute inset-0 rounded-lg border shadow-sm"
                  transition={{ type: 'spring', stiffness: 400, damping: 32 }}
                />
              )}
              <span className="relative z-10">{t.label}</span>
            </button>
          );
        })}
      </div>
    </LayoutGroup>
  );
}
