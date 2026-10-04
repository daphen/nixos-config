---
name: hubspot-hygiene
description: >
  Governs how Claude (especially reps' Coworker automations) WRITES to HubSpot, to protect sensitive
  deal and reporting data. Load before ANY HubSpot deal write — updating a deal, changing a stage,
  editing amount/ACV/close date/ARR fields, deleting or merging records, or any write that could
  affect reporting, ownership, routing, or deal status. Hard rule: never edit a closed-won deal's
  locked reporting fields and never hard-delete a real record; warn-and-confirm before any other risky
  write. Company/contact hygiene, dedup, enrichment, and parent-child updates are allowed (see
  hubspot-audit). Closed-lost deals stay flexible. When unsure whether a field feeds reporting, do not
  write it.
---

# HubSpot Hygiene Skill

Protects HubSpot **deals and reporting fields** from being overwritten by Claude writes — above all by
reps' **Coworker automations**, which change deals directly. The reverse-ETL pipeline only touches
companies/contacts, so deals are the exposed surface and the focus of this skill.

**Scope — this skill is about DEALS.** Company/contact writes (hygiene, dedup, enrichment, parent-child)
are *allowed* and governed by the separate `hubspot-audit` contract — defer to it for *how* to write
those. This skill's only job is keeping deal + finance data from drifting.

**Enforcement reality (read once).** An admin (Alex) can push this skill to every workspace, but a
skill only works while a user has it **enabled and loaded** — it **cannot be silently enforced**, and
it won't stop a write that bypasses Claude. For the closed-won fields that truly must never move, back
this up with HubSpot **field-level permissions** or a **scoped proxy** on the deal-write path. Skill =
warning + good behavior; permissions = the actual lock.

---

## Tier 1 — HARD: refuse by default

### Closed-won deals are protected
Do not modify a deal that is **closed-won**. Detect it reliably *before* writing by checking the
deal's `hs_is_closed_won` property (true = closed-won) — not by matching stage names, since stage IDs
differ per pipeline and labels get renamed. If a write targets a closed-won deal, refuse and explain.

### Locked reporting fields (on closed-won)
On any closed-won deal these are **read-only** — never overwrite or "correct" them; they feed Mic's
ARR/finance reporting and must not drift:
- `amount` / ACV
- `closedate` (close date)
- ARR / MRR / contract-value fields
- **[MAINTAINED LIST — owner: Mic]** fill in the exact internal property names of every field used in
  ARR or finance reporting. Treat everything on this list as untouchable on closed-won.

If you are unsure whether a field is ARR/reporting-related, **do not update it.**

### Never hard-delete a real record
Never hard-delete a real HubSpot record (deal, company, or contact). If cleanup is needed, suggest
**merge, archive, mark inactive, or escalate for review** instead.

> Tier 1 is "refuse," not "warn." Proceed only if an **admin** gives an explicit, unambiguous override
> for a specific record/field — and even then, confirm the exact change first.

## Tier 2 — WARN + CONFIRM: risky writes that need an explicit yes

Before any write that could affect **reporting, ownership, routing, or deal status**, stop and get
explicit confirmation. Do not bury it in a generic "are you sure?" — state:
1. **What** changes — record + field + `old value -> new value`
2. **Why it's risky** — e.g. "this changes deal stage / reassigns owner / feeds routing"
3. ask for an explicit **yes** before proceeding.

Covers: deal-stage changes, owner changes, routing-related fields, **reopening a closed-lost deal**
(it's a status change — allowed, but confirm), and any bulk write.

## Tier 3 — ALLOWED

- **Closed-lost deals** may be updated or reopened when needed (confirm the reopen per Tier 2).
- **Company & contact** updates that improve hygiene, dedup, enrichment, or parent-child associations —
  follow `hubspot-audit` for how to write them.
- Reading anything; logging activity and notes.

## Source-owned fields (applies across all tiers)

If a field is owned by another pipeline or reporting workflow — ARR/finance fields (Mic), or
`canonical_domain` / `ultimate_parent_domain` / enrichment fields (the ETL) — **do not overwrite it
unless explicitly instructed** by its owner or an admin. Default to leaving source-owned fields alone.

## Pre-write check (deals)

1. Is the target deal **closed-won** (`hs_is_closed_won`)? -> refuse the write (Tier 1).
2. Is the field on the **locked reporting list**? -> refuse on closed-won; leave alone if unsure.
3. Am I **hard-deleting**? -> stop; merge / archive / mark inactive / escalate instead.
4. Does the write touch **reporting / ownership / routing / deal status**? -> warn + confirm (Tier 2).
5. Is the field **source-owned** by another pipeline? -> don't overwrite without explicit instruction.
6. Otherwise (closed-lost edits, company/contact hygiene) -> allowed; follow `hubspot-audit`.
