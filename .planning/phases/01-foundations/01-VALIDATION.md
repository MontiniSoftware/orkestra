---
phase: 1
slug: foundations
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-24
---

# Phase 1 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ExUnit (Elixir built-in) |
| **Config file** | `test/test_helper.exs` |
| **Quick run command** | `mix test test/orkestra/projector/lifecycle_test.exs` |
| **Full suite command** | `mix test` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `mix test <touched test file>`
- **After every plan wave:** Run `mix test`
- **Before `/gsd-verify-work`:** Full suite must be green
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 1-xx-xx | TBD | TBD | STORE-01 | — | Storage behaviour contract enforced (callbacks defined) | unit | `mix test test/orkestra/projection/storage_test.exs` | ❌ W0 | ⬜ pending |
| 1-xx-xx | TBD | TBD | ERR-01/ERR-02/ERR-03 | — | Lifecycle classifies retry/park/halt; backoff bounded by cap | unit | `mix test test/orkestra/projector/lifecycle_test.exs` | ❌ W0 | ⬜ pending |
| 1-xx-xx | TBD | TBD | PROJ-02 | — | subscribe_from_position/3 delivers in order from a position (InMemory) | unit | `mix test test/orkestra/event_store/in_memory_test.exs` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky. Plan/Wave/Task IDs finalized by the planner.*

---

## Wave 0 Requirements

- [ ] `test/orkestra/projector/lifecycle_test.exs` — pure-function unit tests for ERR-01/02/03 (classification, backoff cap, halt decision)
- [ ] `test/orkestra/projection/storage_test.exs` — behaviour-contract test for STORE-01 (a stub adapter implements `write/4` + `reset/2`)
- [ ] `test/orkestra/event_store/in_memory_test.exs` — extend for `subscribe_from_position/3` in-order push delivery (PROJ-02)
- [ ] ExUnit already present — no framework install needed

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| EventStoreDB `subscribe_from_position/3` against a live `$all` | PROJ-02 | Requires a running EventStoreDB instance (optional dep, not in CI) | Start EventStoreDB, subscribe from a known commit position, assert ordered delivery |

*The InMemory path is fully automated; the EventStoreDB adapter path is manual (optional infra).*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
