---
phase: 10-es-query-dsl-builder
plan: 02
subsystem: mcp-codegen
tags: [elasticsearch, opensearch, query-dsl, mcp-tool, code-generator, orkestra-mcp]

# Dependency graph
requires:
  - phase: 10-01
    provides: Orkestra.Projection.ES.Query DSL module (pipe-based accumulator)
provides:
  - gen_es_queries/2 generator function in OrkestraMcp.Generator
  - OrkestraMcp.Tools.GenEsQueries MCP tool (scaffolds ES.Queries modules)
  - Generated ES.Queries modules with search/3, list/3, get_by_id/3 helpers
affects:
  - 11-mcp-integration (scaffolded ES.Queries modules will import this DSL)

# Tech tracking
tech-stack:
  added: []
  patterns:
    - "Generator pattern: gen_es_queries/2 produces Elixir source string with heredoc + escaped quotes for triple-quoted moduledoc"
    - "MCP tool pattern: use Hermes.Server.Component, type: :tool con schema do + @impl execute/2"
    - "Generated module pattern: alias + pipe-based DSL call in search/3, minimal opts in list/3, direct delegate in get_by_id/3"

key-files:
  created:
    - orkestra_mcp/lib/orkestra_mcp/tools/gen_es_queries.ex
    - orkestra_mcp/test/orkestra_mcp/tools/gen_es_queries_test.exs
  modified:
    - orkestra_mcp/lib/orkestra_mcp/generator.ex
    - orkestra_mcp/test/orkestra_mcp/generator_test.exs
    - orkestra_mcp/lib/orkestra_mcp/server.ex

key-decisions:
  - "search/3 usa build_fn/1 (funzione 1-aria) invece di keyword options -- consente composizione DSL arbitraria senza limitare al caller"
  - "list/3 usa :size/:from keyword opts con default 20/0 -- coerente con gen_queries/2 (:page/:page_size)"
  - "get_by_id/3 e' un semplice delegate a Snap.Document.get/3 -- nessuna logica aggiuntiva necessaria"

requirements-completed:
  - QDSL-02

# Metrics
duration: 7min
completed: 2026-06-25
---

# Phase 10 Plan 02: ES Query DSL Builder (Generator + MCP Tool) Summary

**Generator `gen_es_queries/2` e MCP tool `GenEsQueries` per scaffolding di moduli ES.Queries con `search/3`, `list/3`, `get_by_id/3` che usano il DSL `Orkestra.Projection.ES.Query` -- seguendo il pattern identico di `gen_queries/2` e `GenQueries`**

## Performance

- **Duration:** ~7 min
- **Started:** 2026-06-25T12:29:30Z
- **Completed:** 2026-06-25T12:36:44Z
- **Tasks:** 2 (auto)
- **Files modified:** 5 (2 creati, 3 modificati)

## Accomplishments

- Aggiunta funzione `gen_es_queries/2` a `OrkestraMcp.Generator` con @doc, genera sorgente Elixir valido (Code.string_to_quoted/1 passa)
- Il modulo generato aliasa `Orkestra.Projection.ES.Query` e usa il DSL in `search/3` (build_fn pattern) e `list/3` (opts pattern)
- `get_by_id/3` delegato direttamente a `Snap.Document.get/3`
- Tool MCP `OrkestraMcp.Tools.GenEsQueries` creato e registrato in `server.ex` con schema a 2 campi (module_name, projector_module)
- 2 nuovi test generator (describe gen_es_queries/2), 1 nuovo test tool (GenEsQueriesTest)
- Suite completa: 44 test orkestra_mcp, 0 failures; 273 test progetto principale, 0 failures

## Task Commits

1. **Task 1: Add gen_es_queries/2 to Generator and write tests** - `a095136` (feat)
2. **Task 2: Add GenEsQueries MCP tool, register in server, and test** - `32b538d` (feat)

## Files Created/Modified

- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/generator.ex` -- aggiunta funzione gen_es_queries/2 (67 righe) con @doc e sorgente generato con heredoc
- `/data/progetti/orkestra/orkestra_mcp/test/orkestra_mcp/generator_test.exs` -- aggiunto describe "gen_es_queries/2" con 2 test
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/tools/gen_es_queries.ex` -- nuovo modulo GenEsQueries tool MCP (31 righe)
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/server.ex` -- aggiunto component(OrkestraMcp.Tools.GenEsQueries) dopo GenQueries
- `/data/progetti/orkestra/orkestra_mcp/test/orkestra_mcp/tools/gen_es_queries_test.exs` -- nuovo test file GenEsQueriesTest

## Decisions Made

- `search/3` accetta `build_fn` (funzione 1-aria che riceve `Query.new()`) invece di parametri keyword: consente composizione DSL arbitraria dal chiamante senza vincolare il generator a un sottoinsieme di clausole
- `list/3` usa `:size` e `:from` come opzioni (non `:page`/`:page_size`): semantica ES naturale, offset-based, coerente col DSL `Query.size/2` e `Query.from/2`
- `get_by_id/3` e' un semplice delegate a `Snap.Document.get(cluster, index, id)`: nessuna logica aggiuntiva necessaria, Snap gestisce la risposta

## Deviations from Plan

Nessuna -- piano eseguito esattamente come specificato.

## Issues Encountered

Nessuno. Il codice generato produce Elixir sintatticamente valido al primo tentativo; i test compilano e passano senza modifiche.

## Known Stubs

Nessuno -- il codice generato e' completamente implementato. Le funzioni `search/3`, `list/3`, `get_by_id/3` sono operative; il TODO compare solo nei template Aggregate/Projection esistenti.

## Threat Flags

Nessun flag di minaccia aggiuntivo rispetto al threat model del piano (T-10-03, T-10-04, T-10-05 coperti e accettati: `module_name` va in sorgente Elixir validato dal compilatore; path traversal mitigato da `module_to_file_path` che produce sempre `lib/...`).

## User Setup Required

Nessuno -- il tool MCP e' disponibile automaticamente nel server MCP al prossimo avvio.

## Next Phase Readiness

- Il tool `GenEsQueries` e' pronto per essere usato via MCP (fase 11)
- I moduli ES.Queries generati sono compatibili con Snap.Search.search/3 e Snap.Document.get/3
- Il pattern search/3 con build_fn consente composizione DSL arbitraria senza modificare il generator

---
*Phase: 10-es-query-dsl-builder*
*Plan: 02*
*Completed: 2026-06-25*

## Self-Check: PASSED

- [x] `orkestra_mcp/lib/orkestra_mcp/generator.ex` -- FOUND (gen_es_queries/2 presente)
- [x] `orkestra_mcp/lib/orkestra_mcp/tools/gen_es_queries.ex` -- FOUND
- [x] `orkestra_mcp/test/orkestra_mcp/tools/gen_es_queries_test.exs` -- FOUND
- [x] `orkestra_mcp/lib/orkestra_mcp/server.ex` -- FOUND (GenEsQueries registrato)
- [x] `.planning/phases/10-es-query-dsl-builder/10-02-SUMMARY.md` -- FOUND
- [x] Commit `a095136` -- FOUND (feat(10-02): gen_es_queries/2)
- [x] Commit `32b538d` -- FOUND (feat(10-02): GenEsQueries MCP tool)
- [x] `grep -c "GenEsQueries" server.ex` -- restituisce 1
- [x] `mix test` orkestra_mcp -- 44 tests, 0 failures
- [x] `mix test` progetto principale -- 273 tests, 0 failures
