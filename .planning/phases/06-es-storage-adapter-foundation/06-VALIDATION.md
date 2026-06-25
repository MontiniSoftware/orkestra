---
phase: 6
slug: es-storage-adapter-foundation
status: draft
nyquist_compliant: false
wave_0_complete: false
created: 2026-06-25
---

# Phase 6 — Validation Strategy

> Per-phase validation contract for feedback sampling during execution.

---

## Test Infrastructure

| Property | Value |
|----------|-------|
| **Framework** | ExUnit (Elixir builtin) |
| **Config file** | `test/test_helper.exs` |
| **Quick run command** | `mix test test/orkestra/projection/storage/elasticsearch_test.exs` |
| **Full suite command** | `mix test` |
| **Estimated runtime** | ~15 seconds |

---

## Sampling Rate

- **After every task commit:** Run `mix test test/orkestra/projection/storage/elasticsearch_test.exs`
- **After every plan wave:** Run `mix test`
- **Before `/gsd:verify-work`:** Full suite must be green
- **Max feedback latency:** 15 seconds

---

## Per-Task Verification Map

| Task ID | Plan | Wave | Requirement | Threat Ref | Secure Behavior | Test Type | Automated Command | File Exists | Status |
|---------|------|------|-------------|------------|-----------------|-----------|-------------------|-------------|--------|
| 06-01-01 | 01 | 1 | — | — | N/A | build | `mix deps.get && mix deps.compile snap finch mox --force` | ✅ | ⬜ pending |
| 06-01-02 | 01 | 1 | ADPT-03 | T-06-01 | API key in header | unit | `mix test test/orkestra/auth/api_key_test.exs` | ❌ W0 | ⬜ pending |
| 06-01-03 | 01 | 1 | — | — | N/A | build | `mix compile --warnings-as-errors && mix test --max-failures 1` | ✅ | ⬜ pending |
| 06-02-01 | 02 | 2 | ADPT-01, ADPT-02, ADPT-04, ADPT-06 | T-06-03, T-06-05 | dynamic:strict, graceful detection | unit | `mix format --check-formatted lib/orkestra/projection/storage/elasticsearch.ex && mix test test/orkestra/projection/storage/elasticsearch_test.exs` | ❌ W0 | ⬜ pending |

*Status: ⬜ pending · ✅ green · ❌ red · ⚠️ flaky*

---

## Wave 0 Requirements

- [ ] `test/orkestra/projection/storage/elasticsearch_test.exs` — stubs for ADPT-01, ADPT-02, ADPT-03, ADPT-04, ADPT-06
- [ ] Test fixtures for mock Snap HTTP responses (ES 8.x and OpenSearch 2.x cluster info)

*Existing ExUnit infrastructure covers framework needs.*

---

## Manual-Only Verifications

| Behavior | Requirement | Why Manual | Test Instructions |
|----------|-------------|------------|-------------------|
| ES 8.x cluster auth | ADPT-03 | Requires real ES cluster | Start ES 8.x Docker, configure Basic Auth, run `@moduletag :integration` tests |
| OpenSearch 2.x cluster auth | ADPT-03 | Requires real OpenSearch cluster | Start OpenSearch 2.x Docker, configure API key, run `@moduletag :integration` tests |

---

## Validation Sign-Off

- [ ] All tasks have `<automated>` verify or Wave 0 dependencies
- [ ] Sampling continuity: no 3 consecutive tasks without automated verify
- [ ] Wave 0 covers all MISSING references
- [ ] No watch-mode flags
- [ ] Feedback latency < 15s
- [ ] `nyquist_compliant: true` set in frontmatter

**Approval:** pending
