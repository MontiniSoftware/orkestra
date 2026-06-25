---
phase: 09-zero-downtime-rebuild-and-mix-task
plan: 01
subsystem: projector-macro-genserver
tags:
  - projector
  - elasticsearch
  - rebuild
  - zero-downtime
  - RBLD-03
dependency_graph:
  requires:
    - 08-01 (Orkestra.Projector macro con backend ES, __handle_es__/3, __projection_config__/0 base)
    - 07-01 (GenServer ES con es_mode, es_buffer, bulk flush)
  provides:
    - __projection_config__/0 estesa con :backend, :cluster, :index, :projector_module
    - GenServer handle_call(:pause_writes) per bloccare event processing
    - GenServer handle_call(:resume_writes) per riabbonamento post-rebuild
  affects:
    - 09-02 (Mix task orchestra.projection.es.rebuild usa __projection_config__/0 e pause/resume)
tech_stack:
  added: []
  patterns:
    - GenServer pause/resume via handle_call sincrono (RBLD-03)
    - __projection_config__/0 come API discovery per Mix tasks ES
key_files:
  created: []
  modified:
    - lib/orkestra/projector.ex
    - lib/orkestra/projector/gen_server.ex
    - test/orkestra/projector/projector_dsl_es_test.exs
    - test/orkestra/projector/gen_server_es_test.exs
decisions:
  - "pause_writes via handle_call sincrono: il GenServer rimane nella mailbox loop durante la pausa, eventi si accumulano naturalmente — no lock attivo necessario"
  - "resume_writes: unsubscribe + send(:load_checkpoint) — il Mix task resetta il checkpoint Postgres prima di chiamare :resume_writes, garantendo replay da 0"
  - "__projection_config__/0 estesa con backend-agnostic nil per Postgres — nessuna breaking change per Mix task Postgres esistenti"
metrics:
  duration: ~15 minuti
  completed: "2026-06-25"
  tasks_completed: 2
  tasks_total: 2
  files_modified: 4
---

# Phase 09 Plan 01: Zero-Downtime Rebuild Foundation Summary

**One-liner:** Foundation per rebuild zero-downtime ES: `__projection_config__/0` estesa con campi ES e GenServer pause/resume via `handle_call` sincrono per bloccare event writes durante l'alias swap window.

## Tasks Completed

| Task | Name | Commit | Files |
|------|------|--------|-------|
| 1 | Extend __projection_config__/0 with ES fields | ce7dccf | lib/orkestra/projector.ex, test/orkestra/projector/projector_dsl_es_test.exs |
| 2 | Add :pause_writes / :resume_writes to GenServer | 602d04b | lib/orkestra/projector/gen_server.ex, test/orkestra/projector/gen_server_es_test.exs |

## What Was Built

### Task 1: __projection_config__/0 estesa

La funzione `__projection_config__/0` generata dal macro `Orkestra.Projector.__before_compile__/1`
ora espone 4 nuovi campi:

- `:backend` — `:elasticsearch` o `:postgres` (mai `nil`)
- `:cluster` — modulo `Snap.Cluster` per ES projector; `nil` per Postgres
- `:index` — nome stringa dell'indice ES; `nil` per Postgres
- `:projector_module` — `__MODULE__` del projector che definisce `index_mapping/0` e `__handle_es__/3`

I campi pre-esistenti (`:repo`, `:projector_name`, `:migrations_path`, `:migration_source`) sono
invariati — nessuna breaking change per i Mix task Postgres esistenti.

Il `@spec` è stato aggiornato per documentare la nuova shape; il `@moduledoc` include un esempio
ES e Postgres.

**9 nuovi test** in `projector_dsl_es_test.exs` coprono:
- ES projector: tutti e 4 i nuovi campi con valori corretti
- ES projector: retrocompatibilità dei campi legacy
- Postgres projector: `backend: :postgres`, `cluster: nil`, `index: nil`, `projector_module: self`

### Task 2: GenServer pause/resume (RBLD-03)

Tre modifiche al `Orkestra.Projector.GenServer`:

1. **Campo `writes_paused: boolean`** — aggiunto al `@type state` e al map in `init/1` (default `false`).

2. **`handle_call(:pause_writes, ...)`** — imposta `writes_paused: true`, logga a livello `:info`
   con `projector:` e `orkestra: :projector` (pattern T-09-03: nessun `adapter_opts` loggato).
   Il chiamante riceve `:ok` in modo sincrono, dopodiché il GenServer rimane nel loop normale
   ma scarta tutti gli eventi con matching pattern.

3. **`handle_call(:resume_writes, ...)`** — unsubscribe dalla `subscription_ref` corrente se
   l'event store esporta `unsubscribe/1`, poi invia `send(self(), :load_checkpoint)` per
   riabbonamento asincrono, e restituisce `{:reply, :ok, %{state | writes_paused: false, ...}}`.
   Resetta anche `subscription_ref: nil`, `es_buffer: []`, `es_mode: :live`.

4. **Nuova clausola `handle_info/2` con guard `writes_paused: true`** — inserita DOPO la clausola
   `halted: true` e PRIMA della normale elaborazione degli eventi. Gli eventi vengono scartati
   silenziosamente (`:noreply, state` senza aggiornare il checkpoint).

**2 nuovi test** in `gen_server_es_test.exs`:
- `pause_writes blocks event processing` — verifica che il checkpoint non avanzi dopo la pausa
- `resume_writes resubscribes and processes events` — verifica che il GenServer si riabboni e
  processi eventi dopo il resume

## Deviations from Plan

### Auto-fixed Issues

**1. [Rule 1 - Bug] Warning di compilazione: handle_info clauses non raggruppate**

- **Trovato durante:** Task 2
- **Problema:** L'inserimento dei `handle_call` DOPO `handle_info(:load_checkpoint, ...)` ma PRIMA
  di `handle_info(%{global_position:...})` causava un warning Elixir:
  `"clauses with the same name and arity should be grouped together"`.
  Con `--warnings-as-errors` la compilazione falliva.
- **Fix:** Spostato entrambi i `handle_call` PRIMA della prima clausola `handle_info`, dopo `init/1`.
  Questo è il pattern idiomatico Elixir: tutti i callback dello stesso tipo devono essere contigui.
- **File modificati:** `lib/orkestra/projector/gen_server.ex`
- **Commit:** 602d04b (incluso nella fix)

## Known Stubs

Nessuno — tutte le funzionalità sono completamente implementate con handler reali.

## Threat Flags

Nessuna nuova superficie di attacco introdotta da questo piano.

Le minacce T-09-01, T-09-02, T-09-03 del threat model sono mitigate:

- **T-09-01 (Tampering):** `handle_call(:pause_writes)` è chiamabile solo dall'interno del nodo BEAM.
  Il Mix task (Plan 02) girerà nello stesso nodo via `app.start` — nessuna superficie esterna.
- **T-09-02 (DoS — never resumed):** Il log a livello `:info` al momento della pausa avvisa gli
  operatori. Il Mix task (Plan 02) chiamerà `resume_writes` in un blocco `ensure` (RBLD-03).
- **T-09-03 (Info Disclosure):** Solo `projector_name` è loggato — mai `adapter_opts`
  (che contiene credenziali ES). Pattern identico alle fasi 07-08.

## Self-Check: PASSED

| Item | Status |
|------|--------|
| lib/orkestra/projector.ex | FOUND |
| lib/orkestra/projector/gen_server.ex | FOUND |
| test/orkestra/projector/projector_dsl_es_test.exs | FOUND |
| test/orkestra/projector/gen_server_es_test.exs | FOUND |
| Commit ce7dccf (Task 1) | FOUND |
| Commit 602d04b (Task 2) | FOUND |
| mix compile --warnings-as-errors | PASSED |
| 25 tests projector_dsl_es_test.exs | ALL PASSED |
