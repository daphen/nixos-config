#!/usr/bin/env bash
# Preview helper for claude session picker
# Args: $1 = line number, $2 = meta_file path

line_num="$1"
meta_file="$2"

meta=$(sed -n "${line_num}p" "$meta_file")

# Reads only the tail of the jsonl (big sessions are 15MB+; a full parse
# took ~2s, which made fzf show the previous row's preview under the new
# highlight while scrolling).
META_LINE="$meta" python3 <<'PY' | glow -s dark -w 0 - 2>/dev/null
import json, os
from datetime import datetime, timezone

session_id, cwd, jsonl = os.environ['META_LINE'].split('\t')[:3]
short_cwd = cwd.replace(os.path.expanduser('~'), '~', 1)
TAIL = 400_000
SHOW = 25

def fmt_time(ts):
    if not ts:
        return ''
    try:
        dt = datetime.fromisoformat(ts.replace('Z', '+00:00'))
        secs = int((datetime.now(timezone.utc) - dt).total_seconds())
        if secs < 60: return f'{secs}s ago'
        if secs < 3600: return f'{secs // 60}m ago'
        if secs < 86400: return f'{secs // 3600}h ago'
        if secs < 604800: return f'{secs // 86400}d ago'
        return dt.strftime('%b %d')
    except Exception:
        return ''

size = os.path.getsize(jsonl)
truncated = size > TAIL
with open(jsonl, 'rb') as f:
    if truncated:
        f.seek(size - TAIL)
        f.readline()  # drop partial line
    data = f.read()

messages = []
for raw in data.splitlines():
    try:
        d = json.loads(raw)
    except Exception:
        continue
    ts = d.get('timestamp', '')
    if d.get('type') == 'user':
        content = d.get('message', {}).get('content', '')
        if isinstance(content, list):
            content = next((c.get('text', '') for c in content
                            if isinstance(c, dict) and c.get('type') == 'text'), '')
        content = (content or '').strip()
        if content and not content.startswith('<'):
            messages.append(('you', content, ts))
    elif d.get('type') == 'assistant':
        for c in d.get('message', {}).get('content', []) or []:
            if isinstance(c, dict) and c.get('type') == 'text':
                text = c.get('text', '').strip()
                if text:
                    messages.append(('claude', text, ts))
                    break

messages = messages[-SHOW:]
latest_ts = messages[-1][2] if messages else ''

print(f'# {short_cwd}')
print(f'`{session_id[:8]}…` · {fmt_time(latest_ts)}'
      + (' · _older history omitted_' if truncated else ''))
print()
print('---')
print()

if not messages:
    print('_(no messages)_')
else:
    for role, text, ts in messages:
        label = 'You' if role == 'you' else 'Claude'
        snippet = text[:400]
        print(f'**{label}** · {fmt_time(ts)}')
        print()
        if role == 'you':
            for ln in snippet.split('\n'):
                print(f'> {ln}' if ln else '>')
        else:
            print(snippet)
        print()
PY
