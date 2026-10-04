# Normal-view resize pacing experiment — 2026-09-22

**Result: fewer configure requests, but no meaningful redraw-latency improvement in the tested GTK client. Not retained in the production patch or staged binary.**

## Implemented boundary

`candidate.patch` adds a size-request admission check in `CWaylandBackend::configure` and retries the current layout goal from `CWindow::commitWindow`. It uses existing pending/committed size state and existing target geometry; it adds no request queue or protocol. The gate is restricted to mapped, visible, non-floating, non-fullscreen Canvas windows at normal zoom; forced requests bypass it.

This implements the small request-pacing candidate, **not** Niri's commit-triggered old/new-content transition or translation-correct occlusion. The existing snapshot helper renders screen-sized images; it was not treated as a ready-made window-local capture API. Pointer dragging, fullscreen transitions, constraints, X11, and overview regression coverage were not established for this rejected prototype.

## Executed comparison

Public entry points: actual nested Hyprland processes, the existing GTK Wayland resize fixture, layout dispatches, server-side Wayland protocol logging, and the client's completed drawing callback. Three runs per workload per binary; each run sends 22 alternating size changes and ends at a distinct final size.

Both valid comparison instances used a **visible, non-focus-stealing 900×600, 1×, 60 Hz nested display**, with user approval. The busy-client case delays only its first resized drawing callback by 300 ms. All twelve trials delivered the final requested 536×548 client size and passed the isolated config-loader check.

| Median of 3 runs | Control | Candidate |
| --- | ---: | ---: |
| Normal client: configure events | 22 | 16 |
| Normal client: first input → last client draw | 118 ms | 126 ms |
| Busy client: configure events | 22 | 2 |
| Busy client: first input → last client draw | 313 ms | 309 ms |

Times above use the client-size file's write timestamp, not the runner's 50 ms polling timestamps. They measure completion of client drawing, **not** monitor presentation, visual smoothness, compositor FPS, or physical-desktop performance. GTK already batches incoming resize requests; reducing configure traffic did not establish a worthwhile benefit here. The busy-client timing difference is small relative to observed variation.

Earlier hidden-window timings are excluded: the parent's background rendering path caps hidden windows at 15 FPS. The initial visible attempt is also invalid: an overlong Unix-socket path prevented the test app from launching, leaving the nested window black. Its fixed-size fractional-scale setup could produce a startup scale warning. The corrected runner uses a short runtime path and the nested output's preferred mode at 1×; both subsequent visible runs completed without loader errors.

## Exact tested state

- Hyprland base: `12f3780fae50a2edf8c50587bd052e95b8bfe652`.
- Control complete dirty patch: `a4546b59e69522a530dfab4f74f6f4bfd056ea273f593fd613414edc0b49ba9b`.
- Candidate complete dirty patch: `726f9351bba0ee999084b75e1376cb049fd25cf0a0d62fc8be4e990ebd3c2b17`.
- Control binary: `c0a395955d988eaac8a31a6de11330a4aa29080ac12547fd82c3879191a1d7ad`.
- Candidate binary: `06b6595ee32d177a6111712a14eeaf6c91c0c7e5063173258db257f841db9838`.
- Running compositor, unchanged throughout: `061582a337794680b9ea0b02cfea6e769fb9e9f0b899e7a16813f83e0ae07648`.

Machine-readable successful results are retained beside this document. Full protocol logs, fixture files, complete candidate source patch, and runnable binaries remain under `/home/daphen/.cache/canvas-resize-pacing-20260922/{control-visible-fixed,candidate-visible-fixed,Hyprland-candidate,source.patch}`.

Builds used the existing warm Ninja cache, changing only two existing C++ translation units and linking; no cold bootstrap or header-wide invalidation. All builds used `dev build --no-publish`. After the comparison, only this experiment's source edits were removed and the warm build repeated: both source patch hash and stripped binary hash exactly match the original control. The live compositor and staged pixel-snapping binary were never replaced or restarted.

## Reproduction

`../../test-resize-pacing.py` takes `--binary`, `--parent-instance`, and a new `--output` directory. `--visible` requires permission to show the temporary window; without it, functional results remain useful but hidden-window timings must not be used for desktop-performance claims. Apply `candidate.patch` to the exact control source above before building a candidate; `git apply --check` passed against the restored control. The runner records binary, fixture, config, and runner hashes in each result.
