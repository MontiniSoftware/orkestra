---
phase: 2
slug: projector-genserver-ecto-adapter
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-24
---

# Phase 2 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ExUnit (Elixir 1.18, built-in) |
| **Config file** | `test/test_helper.exs` (extend: start test Repo, configure `Ecto.Adapters.SQL.Sandbox`) |
| **Quick run command** | `mix test --exclude postgres` |
| **Full suite command** | `mix test` (requires Postgres; uses `@tag :postgres`) |
| **Estimated runtime** | ~15 seconds (quick), ~30 seconds (full) |

---

## Sampling Rate

- **After every task commit:** Run `mix test --exclude postgres` (fast, no DB)
- **After every plan wave:** Run `mix test` (full, requires Postgres)
- **Before `/gsd-verify-work`:** Full suite must be green with Postgres available
- **Max feedback latency:** 30 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 2-XX-XX | TBD | TBD | STORE-02/03/04 | — | atomic checkpoint+read-model commit; no double/missed write on crash | integration (`:postgres`) | `mix test --only postgres` | ❌ W0 | ⬜ pending |
| 2-XX-XX | TBD | TBD | PROJ-03/04 | — | sequential in-order processing; resume from checkpoint | integration | `mix test` | ❌ W0 | ⬜ pending |
| 2-XX-XX | TBD | TBD | ERR-04 | — | halted status persisted, projector stays alive idle | unit + integration | `mix test` | ❌ W0 | ⬜ pending |
| 2-XX-XX | TBD | TBD | MIG-01, READ-01 | — | isolated Repo, own migration_source; query read model via Ecto | integration (`:postgres`) | `mix test --only postgres` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky. Exact task IDs assigned by the planner.*

---

## Wave 0 Requirements

- [ ] `test/support/test_repo.ex` — a per-projection-style test Ecto.Repo with isolated `migration_source`
- [ ] `test/support/read_model_schema.ex` — example read-model schema + migration for adapter tests
- [ ] `test/test_helper.exs` — start test Repo, set `Ecto.Adapters.SQL.Sandbox` mode; only when Postgres available
- [ ] ExUnit `@tag :postgres` excluded by default so the existing async suite stays green without a DB

*Existing ExUnit infrastructure exists; Wave 0 adds the Postgres test harness + sandbox setup.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| Real-Postgres atomic-crash behavior under a power-loss style kill | STORE-03 | Simulated in-process via abort; a true OS-level crash mid-fsync is environment-specific | Covered by an automated abort/restart test; true OS crash is out of automated scope |

*Nearly all phase behaviors have automated verification; the crash-safety invariant is proven by an in-process simulated-crash + restart test.*

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 30s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
