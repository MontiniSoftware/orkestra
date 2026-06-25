---
phase: 10-es-query-dsl-builder
plan: 01
subsystem: database
tags: [elasticsearch, opensearch, query-dsl, pipe-based, pure-elixir, tdd]

# Dependency graph
requires:
  - phase: 06-es-storage-adapter-foundation
    provides: Elasticsearch storage adapter and Snap integration
  - phase: 08-projector-macro-dsl-for-elasticsearch
    provides: ES projector macro and index_mapping/0 callback
provides:
  - Pipe-based ES Query DSL module (Orkestra.Projection.ES.Query)
  - Pure Elixir struct accumulator with zero I/O dependencies
  - build/1 producing valid ES Query DSL map for Snap.Search.search/4
affects:
  - 10-02 (gen_es_queries MCP tool will use this DSL as output template)
  - 11-mcp-integration (scaffolded ES.Queries modules will import this DSL)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Accumulator struct pattern: defstruct with empty lists/nil, each DSL function appends and returns modified struct"
    - "put_if_nonempty/3 private helper: suppress empty bool clause keys from build/1 output"
    - "Atom.to_string/1 for clause type keys: converts :match, :term, :range atoms to ES string keys"

key-files:
  created:
    - lib/orkestra/projection/es/query.ex
    - test/orkestra/projection/es/query_test.exs
  modified: []

key-decisions:
  - "Struct-based accumulator chosen over plain map — enforces @type, pattern-matchable, cleaner pipe API"
  - "Clause values not sanitised by DSL — sanitisation is caller's responsibility; documented in @moduledoc"
  - "from/2 with value 0 is included in build/1 output (unlike nil) — enables explicit 0-offset pagination"
  - "size/2 with value 0 is included in build/1 output — enables aggregations-only queries (no hits)"

patterns-established:
  - "Pattern: ES DSL accumulator — new/0 -> clause functions -> build/1; each clause function uses ++ to append"
  - "Pattern: put_if_nonempty/3 — private two-clause function that suppresses empty-list keys from maps"

requirements-completed:
  - QDSL-01

# Metrics
duration: 4min
completed: 2026-06-25
---

# Phase 10 Plan 01: ES Query DSL Builder Summary

**Pipe-based Elasticsearch Query DSL in pure Elixir — `Query.new() |> must() |> filter() |> build()` produces ES bool query map with accumulative clause semantics and zero I/O dependencies**

## Performance

- **Duration:** ~4 min
- **Started:** 2026-06-25T12:29:00Z
- **Completed:** 2026-06-25T12:32:42Z
- **Tasks:** 2 (TDD: RED + GREEN)
- **Files modified:** 2 (created)

## Accomplishments

- Implemented `Orkestra.Projection.ES.Query` con struct accumulatrice, 9 funzioni pubbliche (new, must, should, filter, must_not, aggs, size, from, sort, build) tutte con @doc e @spec
- 20 test unitari coprono tutti i comportamenti: accumulo clause, omissione chiavi vuote, pipeline completa, anti-regressione "due must non perdono il primo"
- build/1 produce mappa ES corretta passabile direttamente a `Snap.Search.search/4` come terzo argomento
- Suite completa: 273 test, 0 failures (nessuna regressione)

## Task Commits

1. **Task 1: RED -- Write failing tests for ES Query DSL** - `f8d4843` (test)
2. **Task 2: GREEN+REFACTOR -- Implement Query DSL module** - `3c06b27` (feat)

## TDD Gate Compliance

- RED gate: commit `f8d4843` — `test(10-01): add failing tests for ES Query DSL (QDSL-01)`
- GREEN gate: commit `3c06b27` — `feat(10-01): implement ES Query DSL module (QDSL-01)`
- REFACTOR gate: non necessario — implementazione pulita al primo tentativo

## Files Created/Modified

- `/data/progetti/orkestra/lib/orkestra/projection/es/query.ex` — modulo DSL puro Elixir, 271 righe, @moduledoc con esempi pipe, @type t(), @type clause(), 9 funzioni pubbliche, helper privato put_if_nonempty/3
- `/data/progetti/orkestra/test/orkestra/projection/es/query_test.exs` — 20 test in 7 describe block: new/0, bool clauses, aggs/3, pagination, sort/2, build/1, composition

## Decisions Made

- `size/2` con valore `0` viene incluso in build/1 (non omesso come nil) — necessario per query aggregations-only (nessun hit, solo aggregazioni)
- `from/2` con valore `0` viene incluso in build/1 — consente paginazione esplicita da offset zero (uso `not is_nil(q.from)` invece di `if q.from`)
- Valori delle clausole non sanitizzati nel DSL — responsabilità del chiamante; documentato in @moduledoc per STRIDE T-10-01

## Deviations from Plan

Nessuna — piano eseguito esattamente come specificato.

## Issues Encountered

Nessuno. Il modulo e' puro Elixir senza dipendenze runtime aggiuntive; tutti i test compilano e passano in 0.07s.

## Known Stubs

Nessuno — il DSL e' completamente implementato. `build/1` produce mappe ES valide senza placeholder o dati hardcoded.

## Threat Flags

Nessun flag di minaccia aggiuntivo rispetto al threat model del piano (T-10-01, T-10-02 gia' coperti e accettati con documentazione nel @moduledoc).

## User Setup Required

Nessuno — modulo puro, zero configurazione richiesta.

## Next Phase Readiness

- `Orkestra.Projection.ES.Query` e' pronto per essere usato nella fase 10-02 (gen_es_queries MCP tool)
- Il DSL produce mappe ES compatibili con `Snap.Search.search/4` — nessun adattamento necessario
- Fase 11 (MCP code generation) puo' importare il modulo come riferimento nei template generati

---
*Phase: 10-es-query-dsl-builder*
*Plan: 01*
*Completed: 2026-06-25*

## Self-Check: PASSED

- [x] `lib/orkestra/projection/es/query.ex` -- FOUND (271 righe)
- [x] `test/orkestra/projection/es/query_test.exs` -- FOUND (286 righe, 20 test)
- [x] Commit `f8d4843` -- FOUND (test RED)
- [x] Commit `3c06b27` -- FOUND (feat GREEN)
- [x] `mix test test/orkestra/projection/es/query_test.exs` -- 20 tests, 0 failures
- [x] `mix format --check-formatted lib/orkestra/projection/es/query.ex` -- clean
