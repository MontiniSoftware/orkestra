---
phase: 09-zero-downtime-rebuild-and-mix-task
plan: 02
subsystem: mix-task-es-rebuild
tags:
  - elasticsearch
  - rebuild
  - zero-downtime
  - RBLD-01
  - RBLD-02
  - RBLD-03
  - mix-task
  - hotswap
dependency_graph:
  requires:
    - 09-01 (__projection_config__/0 con :backend, :cluster, :index, :projector_module)
    - 09-01 (GenServer pause/resume via handle_call sincrono)
  provides:
    - mix orkestra.projection.es.rebuild Mix task (RBLD-02)
    - Zero-downtime alias swap via Snap.Indexes.hotswap/5 (RBLD-01)
    - GenServer pause prima dell'hotswap, resume in try/after (RBLD-03)
    - Reset checkpoint Postgres solo dopo hotswap :ok (T-09-07)
  affects:
    - Nessuna dipendenza downstream in questo milestone
tech_stack:
  added: []
  patterns:
    - Mix task con try/after per garantire resume_writes anche su failure
    - Event collection via subscribe_from_position + receive loop con 2-sec timeout
    - Application.put_env in test setup per configurare event store nel Mix task
    - inspect(Module) come type_string per dispatch ES in test projector inline
key_files:
  created:
    - lib/mix/tasks/orkestra.projection.es.rebuild.ex
    - test/mix/tasks/orkestra.projection.es.rebuild_test.exs
  modified: []
decisions:
  - "Event collection eagera: stream built PRIMA di chiamare hotswap — InMemory deliver sincrono, hotswap consuma Enumerable in un pass"
  - "GenServer pausa PRIMA dell'hotswap (non solo durante alias swap): garantisce zero race chance tra live writes e swap window"
  - "try/after garantisce resume_writes sempre chiamato, anche su hotswap failure (T-09-08)"
  - "Checkpoint reset SOLO dopo hotswap :ok — mai prima (T-09-07)"
  - "event_store risolto via Application.get_env(:orkestra, Orkestra.EventStore) con default InMemory — compatibile con test setup"
  - "project_es/2 in test usa modulo reale RebuildOrderPlaced e inspect(module) come event.type per dispatch corretto"
metrics:
  duration: ~11 minuti (648 secondi)
  completed: "2026-06-25"
  tasks_completed: 2
  tasks_total: 2
  files_created: 2
  files_modified: 0
---

# Phase 09 Plan 02: Mix Task ES Rebuild Summary

**One-liner:** Mix task `mix orkestra.projection.es.rebuild` con zero-downtime alias swap via `Snap.Indexes.hotswap/5`, pausa sincrona del GenServer live, reset checkpoint Postgres post-swap, e 5 test di integrazione che coprono RBLD-01, RBLD-02, RBLD-03.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Implement mix orkestra.projection.es.rebuild Mix task | 9b3c0c9 | lib/mix/tasks/orkestra.projection.es.rebuild.ex |
| 2 | Integration tests for mix orkestra.projection.es.rebuild | 1b5ba34 | test/mix/tasks/orkestra.projection.es.rebuild_test.exs |

## What Was Built

### Task 1: Mix Task `mix orkestra.projection.es.rebuild`

Il file `lib/mix/tasks/orkestra.projection.es.rebuild.ex` implementa la sequenza completa di rebuild zero-downtime:

1. **Validazione backend** (T-09-04): `config.backend == :elasticsearch` — `Mix.raise` con messaggio chiaro per projector Postgres.
2. **Conferma interattiva**: prompt `"Continue?"` a meno che `--yes` sia passato (T-09-06).
3. **Event collection eagera**: `subscribe_from_position(:all, -1, self())` + receive loop con 2-sec timeout. InMemory deliver sincrono (eventi già nel mailbox prima del timeout).
4. **Stream building**: `Enum.flat_map` chiama `projector_module.__handle_es__/3` per ogni evento, emette `Snap.Bulk.Action.Index` o `:skip`.
5. **Pausa GenServer** (RBLD-03): `GenServer.call(pid, :pause_writes, 10_000)` — pausa avviene PRIMA dell'hotswap, non solo durante l'alias swap.
6. **`Snap.Indexes.hotswap/5`** (RBLD-01): `page_size: 500, page_wait: 0`. Internamente: crea indice versionato, bulk load, refresh, alias swap atomico, cleanup (keep: 2).
7. **Reset checkpoint** (T-09-07): `Ecto.Migrator.with_repo` con `delete_all` SOLO dopo hotswap `:ok`. Su failure, checkpoint invariato.
8. **Resume GenServer** (T-09-08): `GenServer.call(pid, :resume_writes, 10_000)` in blocco `after` — garantito anche su hotswap failure. `Process.alive?` check prima della call.

Sicurezza: solo `projector_name` e `index` vengono loggati — mai credenziali/`adapter_opts` (T-09-05).

Il modulo è wrappato in `if Code.ensure_loaded?(Snap.Cluster) and Code.ensure_loaded?(Ecto.Migrator)`, consistent con il pattern del progetto.

### Task 2: Integration Tests (5 test — tutti PASSING)

**Test RBLD-01**: Verifica la sequenza hotswap completa via message tracking. Appende 3 eventi, esegue il rebuild, controlla che la sequenza HTTP sia nell'ordine corretto: PUT versioned index → POST /_bulk → POST /_refresh → GET /_cat/indices → POST /_aliases. Verifica che il checkpoint sia eliminato dopo.

**Test RBLD-02 (missing arg)**: `assert_raise Mix.Error, ~r/requires a projector module name/` quando `run([])`.

**Test RBLD-02 (wrong backend)**: `assert_raise Mix.Error, ~r/not an Elasticsearch projector/` per un projector Postgres inline (`TestPostgresProjector`).

**Test RBLD-03 (pause/resume)**: Avvia il GenServer via `start_supervised!`, attende il processing del primo evento (checkpoint avanza), poi esegue il rebuild. Verifica che il GenServer sia vivo dopo (`Process.alive?/1`) e che il checkpoint sia eliminato.

**Test RBLD-03 (empty hotswap)**: Rebuild senza eventi in EventStore — verifica che il GenServer rimanga vivo anche con bulk load vuoto.

#### Soluzione per il dispatch ES nei test

Il macro `project_es/2` prende un modulo come primo argomento e chiama `inspect(module)` per ottenere il type_string. Usare una stringa letterale in `project_es` avrebbe generato `inspect("MyString")` = `"\"MyString\""` (con virgolette), mai matchante con `event.type`. La soluzione: definire un modulo stub `RebuildOrderPlaced` e appendere eventi con `type: inspect(RebuildOrderPlaced)`.

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Syntax error in test — `@projector_module_str` multilinea**

- **Trovato durante:** Task 2, prima esecuzione
- **Problema:** La definizione `@projector_module_str\n  "..."` su due righe veniva interpretata come un blocco do...end vuoto seguito da un literal non usato. Warning: `"code block contains unused literal"` e `"undefined module attribute @projector_module_str"`.
- **Fix:** Portato il valore sulla stessa riga dell'attributo.
- **File modificati:** `test/mix/tasks/orkestra.projection.es.rebuild_test.exs`

**2. [Rule 1 - Bug] `@impl true` per `index_mapping/0` su projector senza @behaviour**

- **Trovato durante:** Task 2, prima compilazione
- **Problema:** Il macro `Orkestra.Projector` non dichiara un `@behaviour` per `index_mapping/0`, quindi `@impl true` generava warning `"got @impl true for function index_mapping/0 but no behaviour was declared"`.
- **Fix:** Rimosso `@impl true` dalla definizione di `index_mapping/0` nel test projector.
- **File modificati:** `test/mix/tasks/orkestra.projection.es.rebuild_test.exs`

**3. [Rule 1 - Bug] Dispatch ES non matchante — stringa passata a `project_es` invece di modulo**

- **Trovato durante:** Task 2, primo run test (RBLD-01: "Built 0 ES documents for indexing" nonostante 3 eventi)
- **Problema:** `project_es("Elixir.RebuildTestOrderPlaced", ...)` → `inspect("Elixir.RebuildTestOrderPlaced")` = `"\"Elixir.RebuildTestOrderPlaced\""` (con virgolette). Il dispatch faceva match su questa stringa con virgolette, mai uguale a `event.type` che è `"Elixir.RebuildTestOrderPlaced"` senza virgolette.
- **Fix:** Definito modulo stub `RebuildOrderPlaced` e usato come primo argomento di `project_es`. Gli eventi appended usano `type: inspect(RebuildOrderPlaced)` = `"Mix.Tasks.Orkestra.Projection.Es.RebuildTest.RebuildOrderPlaced"` che matcha esattamente.
- **File modificati:** `test/mix/tasks/orkestra.projection.es.rebuild_test.exs`

**4. [Rule 1 - Bug] `TestPostgresProjector` referenced module non caricato in RBLD-02**

- **Trovato durante:** Task 2, primo run test
- **Problema:** Il test usava `"Mix.Tasks.Orkestra.Projection.TasksTest.TestProjector"` come projector Postgres per il test di validazione, ma questo modulo è definito in un altro file (`projection_tasks_test.exs`) che non è necessariamente caricato quando il test ES rebuild viene eseguito in isolamento.
- **Fix:** Definito `TestPostgresProjector` inline nel test file con `backend: :postgres` (default), eliminando la dipendenza da un file esterno.
- **File modificati:** `test/mix/tasks/orkestra.projection.es.rebuild_test.exs`

## Known Stubs

Nessuno — tutte le funzionalità sono completamente implementate. Il Mix task usa Snap.Indexes.hotswap reale, GenServer pause/resume reale, e reset checkpoint reale.

## Threat Flags

Nessuna nuova superficie di attacco. Le mitigazioni del threat model sono implementate:

| Threat | Mitigation | Implementata in |
|--------|-----------|-----------------|
| T-09-04 (Tampering — CLI arg) | `config.backend == :elasticsearch` check + Mix.raise | `run/1` linea 57-64 |
| T-09-05 (Info Disclosure — credential logging) | Solo `projector_name` e `index` negli OTel span attrs e nei log | `Tracer.with_span` linea 104-109 |
| T-09-06 (DoS — rebuild su wrong index) | Confirmation prompt prima dell'hotswap | `run/1` linea 65-73 |
| T-09-07 (Tampering — checkpoint reset pre-hotswap) | `delete_all` solo dentro `case :ok ->` dopo hotswap | `run/1` linea 115-123 |
| T-09-08 (DoS — GenServer mai resumed) | `try/after` con `Process.alive?` check | `run/1` linee 100 e 126-131 |

## Self-Check: PASSED

| Item | Status |
|------|--------|
| lib/mix/tasks/orkestra.projection.es.rebuild.ex | FOUND |
| test/mix/tasks/orkestra.projection.es.rebuild_test.exs | FOUND |
| Commit 9b3c0c9 (Task 1) | FOUND |
| Commit 1b5ba34 (Task 2) | FOUND |
| mix compile --warnings-as-errors | PASSED |
| 5 tests (RBLD-01, RBLD-02 x2, RBLD-03 x2) | ALL PASSED |
