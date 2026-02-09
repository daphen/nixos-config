---
description: View my last 3 screenshots
---

Please read and analyze these screenshots:
$(ls -t /tmp/screenshot-*.png 2>/dev/null | head -3 | while read f; do echo "$f"; done)
