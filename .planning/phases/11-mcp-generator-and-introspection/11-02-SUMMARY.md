---
phase: 11-mcp-generator-and-introspection
plan: "02"
subsystem: mcp-introspection
tags: [introspection, elasticsearch, multi-backend, projectors, mcp]
dependency_graph:
  requires: [11-01]
  provides: [MCP-02]
  affects: [orkestra_mcp/lib/orkestra_mcp/introspection.ex, orkestra_mcp/resources/list_projections.ex]
tech_stack:
  added: []
  patterns: [multi-backend-regex-detection, tdd-red-green, formatter-aware-regex]
key_files:
  created:
    - orkestra_mcp/test/fixtures/sample_project/lib/my_app/orders/projectors/order_es_projector.ex
  modified:
    - orkestra_mcp/lib/orkestra_mcp/introspection.ex
    - orkestra_mcp/test/orkestra_mcp/introspection_test.exs
decisions:
  - "Regex aggiornato a project[\s(]+ e project_es[\s(]+ per gestire entrambe le forme prodotte da mix format"
  - "detect_projectors/2 usa if-match a due fasi: prima rileva qualsiasi Orkestra.Projector, poi estrae le opzioni indipendentemente dall'ordine"
  - "Postgres projector riceve backend: :postgres, cluster: nil, index: nil per backward-compatibility strutturale"
metrics:
  duration: "148s"
  completed: "2026-06-25"
  tasks: 2
  files_changed: 3
---

# Phase 11 Plan 02: ES Projector Introspection Multi-Backend Summary

**One-liner:** Introspection estesa con rilevamento multi-backend (`:postgres`/`:elasticsearch`) via regex a due fasi, con annotazione backend nel domain map e test TDD completi.

## Objective

Estendere `OrkestraMcp.Introspection` per rilevare projector ES (`backend: :elasticsearch`) accanto ai Postgres, estrarre i campi `backend`, `cluster`, `index` e annotare `build_domain_map/1` con queste informazioni. `ListProjections` riceve automaticamente i dati arricchiti senza modifiche.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Add ES projector fixture and extend detect_projectors | 80b55c6 | introspection.ex, order_es_projector.ex |
| 2 | Update introspection tests for ES projector discovery | dda6fba | introspection_test.exs, introspection.ex (regex fix) |

## What Was Built

### Task 1: Fixture ES projector e rilevamento multi-backend

Creata la fixture `order_es_projector.ex` con `use Orkestra.Projector, backend: :elasticsearch, cluster: MyApp.ESCluster, index: "orders"` e un handler `project_es`.

Riscritto `detect_projectors/2` con approccio a due fasi:
1. Test `content =~ ~r/use\s+Orkestra\.Projector/` per rilevare qualsiasi projector (indipendentemente dall'ordine delle opzioni)
2. Estrazione separata di `repo`, `backend`, `cluster`, `index` con helper dedicati

Aggiunte funzioni private: `extract_option/2`, `extract_backend/1`, `extract_string_option/2`, `extract_projected_events_all/1`.

Aggiornato `build_domain_map/1` con annotazione backend:
- Postgres: `"MyApp.OrderProjector (projector, backend: postgres)"`
- ES: `"MyApp.ESProjector (projector, backend: elasticsearch, index: orders)"`

### Task 2: Test TDD per introspezione multi-backend

Seguendo il ciclo TDD:

**RED:** I test esistenti fallivano: `"includes projectors in domain map"` cercava `(projector)` che era diventato `(projector, backend: postgres)`.

**GREEN:** Aggiornati e aggiunti test:
- `"discovers projectors"`: aggiunto `backend: :postgres`, `cluster: nil`, `index: nil`
- `"discovers ES projectors"` (nuovo): verifica `backend: :elasticsearch`, `cluster`, `index`, eventi
- `"includes projectors in domain map"`: aggiornato formato a `(projector, backend: postgres)`
- `"includes ES projectors in domain map"` (nuovo): verifica annotazione ES nel domain map

**53 test, 0 fallimenti** (da 44 baseline + 9 nuovi da Fase 11).

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Regex `project_es` non catturava forma con parentesi prodotta da `mix format`**
- **Trovato durante:** Task 2 (dopo formattazione con `mix format`)
- **Problema:** Il formatter Elixir trasforma `project_es MyApp.Events.OrderPlaced,` in `project_es(MyApp.Events.OrderPlaced,` — la parentesi sostituisce lo spazio. Il regex originale `project_es\s+([\w.]+),` richiedeva whitespace, quindi non faceva match sulla forma formattata.
- **Fix:** Aggiornato entrambi i regex a `project[\s(]+([\w.]+),` e `project_es[\s(]+([\w.]+),` per catturare entrambe le forme.
- **File modificati:** `orkestra_mcp/lib/orkestra_mcp/introspection.ex`
- **Commit:** dda6fba

## Known Stubs

Nessuno. Tutte le funzioni rilevano e restituiscono dati reali dai file sorgente.

## Threat Flags

Nessun nuovo threat surface rilevato. Il rilevamento ES projector segue lo stesso trust model di tutti gli altri `detect_*` (regex su file del progetto locale, nessun segreto coinvolto).

## TDD Gate Compliance

- RED commit: 80b55c6 (i test esistenti fallivano per il cambio di formato)
- GREEN commit: dda6fba (tutti i test passano, 53/53)
- REFACTOR: non necessario

## Self-Check: PASSED

File verificati:
- `orkestra_mcp/lib/orkestra_mcp/introspection.ex` — FOUND
- `orkestra_mcp/test/fixtures/sample_project/lib/my_app/orders/projectors/order_es_projector.ex` — FOUND
- `orkestra_mcp/test/orkestra_mcp/introspection_test.exs` — FOUND

Commit verificati:
- `80b55c6` — FOUND (feat(11-02): extend detect_projectors for multi-backend ES support)
- `dda6fba` — FOUND (test(11-02): add ES projector introspection tests and fix event regex)

Test: 53/53 PASS, 0 failures.
