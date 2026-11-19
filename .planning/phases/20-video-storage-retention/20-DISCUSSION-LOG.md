# Phase 20: Video Storage & Retention - Discussion Log

> **Audit trail only.** Do not use as input to planning, research, or execution agents.
> Decisions are captured in CONTEXT.md — this log preserves the alternatives considered.

**Date:** 2026-11-19
**Phase:** 20-video-storage-retention
**Areas discussed:** none. The user answered "No preference" and accepted Claude's recommended defaults.

---

## Gray areas presented

| Option | Description | Selected |
|--------|-------------|----------|
| Low disk + video on | Block the whole recording (literal STOR-03), or fall back to audio-only with a warning? Threshold? | |
| Partial/failed videos | Which `.mov` outcomes get linked vs discarded? | |
| Leftover orphan videos | Auto-clean at launch, add to the Settings button, or leave? | |

**User's choice:** No preference. The defaults apply.
**Notes:** Phase 19 precedent: reinterpretations of locked requirements are surfaced to the user. D-01 (audio-only fallback instead of blocking) must be flagged at plan approval.

## Claude's Discretion

- D-01/D-02: two-tier disk guard, audio-only fallback, preset-aware ~2 h video headroom
- D-05–D-07: link any playable `.mov` (partials included); delete unplayable/zero-duration files
- D-10: launch-time orphan `.mov` cleanup, skipped if the DB query fails
- Migration/column shape, playability check, Settings relabel/button coverage

## Deferred Ideas

- RES-03 mid-recording disk monitoring; RES-04 drain-timer hardening; auto-retention / video-only delete; storage breakdown UI
