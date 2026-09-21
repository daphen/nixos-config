# Jev context-pruning replay

**Result: pruning can prevent Pi's native rollover without modifying Pi core.**
This is a synthetic-only experiment, not an installed extension or a production
retention policy. No personal session, source file contents, or notes are sent
to Jev.

## Run

From the repository root:

```sh
python3 experiments/jev-context-replay/replay.py
```

To classify the synthetic fixture with one real Jev request before replaying it:

```sh
fish --no-config -c 'source ~/.config/fish/secrets.fish; exec python3 experiments/jev-context-replay/replay.py --jev'
```

The script requires the installed `pi` executable. It reuses the existing RPC
rollover test harness, isolates HOME/XDG/Pi configuration, and registers only a
loopback mock main-model provider plus the explicitly named extensions. The main
model makes no external requests. The optional Jev call uses a 15-second socket
timeout, a 32 KB request-body cap, and only invented fixture excerpts. Its key
is not passed to the child Pi processes. No Nix build, activation, or restart
occurs.

`filter.ts` is loaded only by the replay. It replaces old successful plain-text
`read` outputs with explicit omission markers when the recorded keep score is at
most 0.1. It preserves tool calls, result envelopes, non-tool messages, errors,
non-read tools, images, and the most recent two user turns. Missing or invalid
scores retain the original content. Scores are captured once for this fixed
fixture, not maintained as a live classifier cache.

## Verified path

Base repository: `9f2a611313dbd5e9a98403842238635cfad2f8fd`. Runtime: installed
Pi 0.84.2; full store path and exact tested source SHA-256s are recorded in
`result.json`.

1. Pi's `context` extension event receives a copy of the active messages.
1. The filter changes that copy, leaving the append-only session untouched.
1. The loopback provider receives the filtered request and reports usage
   computed from its actual message payload (characters / 4, rounded up, plus
   output).
1. Pi's real `AgentSession` checks that usage against its normal threshold:
   200,000-token context minus 16,384 reserved tokens = 183,616 tokens.
1. When triggered, the existing `scoped/no-summary-rollover` extension creates
   its deterministic checkpoint. Neither that source nor Pi core was changed.

This tests the public RPC/provider path, not a duplicated threshold formula. The
existing path already has the necessary usage accounting; the missing production
step is selecting and applying pruning before the near-limit request. An
already-over-threshold saved response can trigger compaction before the next
`context` event, so attaching pruning only when compaction starts is too late.

## Recorded result

Latest live run: four tests passed, including continuation and process resume.
The main-model token counts below are **simulated estimates**, not tokenizer or
paid main-model measurements. This deliberately bloat-heavy fixture is not a
prediction of savings in real sessions.

| Same synthetic history            | Estimated first-request tokens | Native rollovers |
| --------------------------------- | -----------------------------: | ---------------: |
| Unfiltered                        |                        195,207 |                1 |
| Deterministic expected selections |                          9,548 |                0 |
| Real Jev selections               |                          9,547 |                0 |
| Missing or invalid classification |                  about 195,207 |                1 |

Jev `jev-1.13.0` classified 20 records in 1,120 ms: 6,477 input tokens and 363
output tokens. It selected all 15 obsolete CSS outputs for omission and retained
the required payment-schema evidence. An earlier exploratory call retained one
extra obsolete output: classification varies, even on this simple fixture.

The assertions also verify original session bytes, session/model identity,
tool-call/result pairing, user/assistant contents, opaque thinking metadata,
result metadata, protected records, and unchanged rollover count after resume.
There is no assertion that smaller requests improve answer quality or latency.

## Limits and next step

- Hard pins are necessary: the live classifier scored the mutation receipt and
  declined deployment approval below 0.5. The filter retained both regardless.
- Hard pins are not sufficient: the deliberately bad-score test removes an
  important old read. That limitation is asserted and visible as
  `required_evidence_kept: false` in the bad-score report. Passing the suite
  does not establish semantic safety for arbitrary reads.
- The fixture explicitly labels obsolete material. Output excerpts can miss
  important information in their omitted middle. Harder fixtures are needed.
- Checkpoint construction still consumes unfiltered history. Selection-aware
  rollover content, repeated growth/rollovers, overflow recovery, cache effects,
  runtime cancellation, and end-to-end latency are not implemented or measured.

Next: design the bounded production integration, including selection-aware
checkpoint input and a non-destructive trial. Do not auto-discover `filter.ts`
in live Pi sessions; it depends on synthetic replay files.
