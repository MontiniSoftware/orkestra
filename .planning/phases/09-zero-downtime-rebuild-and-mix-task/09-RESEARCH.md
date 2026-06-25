# Phase 9: Zero-Downtime Rebuild and Mix Task — Research

**Researched:** 2026-06-25
**Domain:** Elasticsearch index alias swap, Mix task, GenServer rebuild coordination
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
- Zero-downtime via ES/OpenSearch index alias pattern: scrivere su indice versioned, swap alias atomica
- `Snap.Indexes.hotswap/5` come meccanismo di alias swap atomico (verificato nel codice Snap)
- Versioned index naming gestito internamente da Snap: `{alias}-{unix_microseconds}` (generato da `generate_index_name/1`)
- Live writes devono essere messe in pausa durante l'alias swap per prevenire race (RBLD-03)
- Event replay: EventStore catch-up subscription da position 0 con `rebuild_total` impostato
- Cleanup: Snap.Indexes.hotswap chiama internamente `cleanup/4` preservando i 2 indici più recenti

### Claude's Discretion
- Tutte le scelte implementative sono a discrezione di Claude — fase puramente infrastrutturale

### Deferred Ideas (OUT OF SCOPE)
- Rebuild crash recovery (persisted state) — RRES-01, deferred to future
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| RBLD-01 | Zero-downtime rebuild: crea nuovo indice, replay eventi, swap alias atomica, cleanup vecchio indice | `Snap.Indexes.hotswap/5` verificato nel codice sorgente Snap 0.16.0; esegue create → bulk → refresh → alias → cleanup in sequenza |
| RBLD-02 | `mix orkestra.projection.es.rebuild` Mix task: trigger rebuild completo con alias swap | Pattern Mix task verificato nel codebase esistente (`orkestra.projection.rebuild`); Mix.Task + `app.start` + `__projection_config__/0` |
| RBLD-03 | Live writes pausate durante alias swap per prevenire race conditions | GenServer pause via `GenServer.call/2` con messaggio `:pause_writes` o Postgres advisory lock; tradeoff analizzato sotto |
</phase_requirements>

---

## Summary

La Phase 9 implementa il pattern rebuild zero-downtime per proiettori Elasticsearch: il Mix task `mix orkestra.projection.es.rebuild` costruisce uno **stream** di `Snap.Bulk.Action.Index` a partire dagli eventi dell'EventStore, lo passa a `Snap.Indexes.hotswap/5` che internamente crea un indice versioned (`{alias}-{unix_microseconds}`), esegue il bulk loading, fa un `_refresh`, swappa l'alias atomicamente via `POST /_aliases`, e poi chiama `cleanup/4` preservando i 2 indici più recenti.

Il punto critico di design è che `Snap.Indexes.hotswap/5` consuma uno **stream Elixir** (qualsiasi `Enumerable`) di azioni Bulk, non coordina con il GenServer esistente. Il Mix task deve quindi agire come un produttore indipendente: leggere tutti gli eventi dall'EventStore, invocare l'handler del projector per ogni evento, costruire le `Snap.Bulk.Action.Index`, e fornire questo stream a `hotswap`. Il GenServer live continua a girare durante il rebuild e scrive sull'alias corrente; solo durante la finestra dell'alias swap (milliseconds) le writes vengono temporaneamente bloccate tramite un `GenServer.call/3` sincrono.

Il design non usa il GenServer esistente per il rebuild — questo sarebbe incompatibile con l'interfaccia stream di `hotswap`. Il rebuild avviene in-process nel Mix task, il GenServer live viene solo pausato per la swap finale.

**Primary recommendation:** Il Mix task costruisce il stream ES in-process usando l'handler `__handle_es__/3` del projector, passa lo stream a `Snap.Indexes.hotswap/5`, poi invia un messaggio sincrono al GenServer live per bloccare le writes durante la swap. Checkpoint ES viene resettato nel Postgres repo dopo il rebuild per far ripartire il GenServer live dal nuovo indice.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Rebuild orchestration | Mix Task | — | Mix task coordina l'intera sequenza; il GenServer è consumer, non orchestratore |
| Event replay per rebuild | Mix Task (in-process) | EventStore | Il task legge direttamente dall'EventStore per costruire lo stream Bulk |
| Versioned index creation | Snap.Indexes (library) | — | `hotswap/5` genera il nome e chiama `create/3` internamente |
| Bulk indexing nel rebuild | Snap.Bulk (library) | — | `hotswap/5` chiama `Snap.Bulk.perform/4` internamente |
| Alias swap atomica | Snap.Indexes (library) | — | `hotswap/5` → `alias/4` → `POST /_aliases` con add+remove atomici |
| Old index cleanup | Snap.Indexes (library) | — | `hotswap/5` → `cleanup/4` preserva i 2 più recenti |
| Live write pause (RBLD-03) | Mix Task → GenServer | — | Mix task invia `:pause_writes` via `GenServer.call/3` sincrono |
| Checkpoint reset post-rebuild | Mix Task → Postgres Repo | — | Cancella checkpoint Postgres per far ripartire il GenServer live da 0 |

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Snap | 0.16.0 | Elasticsearch client con hotswap, bulk, aliases | Già in uso, unico client Elixir ES mantenuto [VERIFIED: mix.lock] |
| Ecto | ~> 3.12 | Checkpoint Postgres management | Già in uso per tutti i projector |
| Mix.Task | built-in | Task DSL per mix task | Pattern già in uso: `orkestra.projection.rebuild` [VERIFIED: codebase] |

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Snap.Indexes | 0.16.0 submodule | `hotswap/5`, `create/3`, `delete/3`, `cleanup/4`, `alias/4` | Rebuild e index management |
| Snap.Bulk | 0.16.0 submodule | `perform/4` con stream Enumerable | Bulk indexing durante rebuild |
| OpenTelemetry.Tracer | 1.5.0 | OTel span per rebuild operation | Span `"orkestra.es.rebuild"` |

**Version verification:** [VERIFIED: mix.lock `snap` → `"0.16.0"`]

**Installation:** Nessuna dipendenza aggiuntiva — tutto già in mix.exs.

---

## Architecture Patterns

### System Architecture Diagram

```
mix orkestra.projection.es.rebuild MyApp.OrderESProjector
        │
        ▼
   [Mix Task]
   1. app.start
   2. module.__projection_config__() → repo, projector_name, cluster, index, handler_fn
   3. count_total_events(event_store)
        │
        ▼
   [build Stream of Snap.Bulk.Action.Index]
   event_store.subscribe_from_position(:all, -1, self())
   receive events → projector_module.__handle_es__/3 → {:ok, doc, id} | :skip
   Enum.map → %Snap.Bulk.Action.Index{id: id, doc: doc}
        │
        ▼
   Snap.Indexes.hotswap(stream, cluster, alias, mapping, opts)
   ├─ create(cluster, "{alias}-{ts}", mapping)       [NEW versioned index]
   ├─ Snap.Bulk.perform(stream, cluster, "{alias}-{ts}", [page_size: 500, page_wait: 0])
   ├─ refresh(cluster, "{alias}-{ts}")
   ├─ alias(cluster, "{alias}-{ts}", alias)          ◄── RACE WINDOW STARTS
   │   POST /_aliases { remove: [old], add: [new] }  ◄── RACE WINDOW ENDS
   └─ cleanup(cluster, alias, 2)                     [delete indexes older than 2]
        │
        ▼
   [Mix Task: post-swap]
   4. reset Postgres checkpoint (DELETE FROM projection_checkpoints WHERE projector_name=...)
   5. signal GenServer live to resume: GenServer.call(pid, :resume_writes)
        │
        ▼
   [GenServer live: riparte replay da position 0]
   (RBLD-03: pause durante la finestra hotswap alias swap)
```

### Live Write Pause — Finestra di Race (RBLD-03)

La race condition: durante il bulk loading del rebuild, il GenServer live scrive sull'alias corrente (che punta all'indice vecchio). Quando `hotswap` swappa l'alias, il GenServer live punta al nuovo indice. Gli eventi scritti sull'indice vecchio (dopo il punto di checkpoint) sono persi.

**Strategia scelta: pausa del GenServer via messaggio sincrono**

```
Mix Task:
  1. GenServer.call(pid, :pause_writes, 10_000)    # blocca mailbox processing
  2. Snap.Indexes.hotswap(...)                      # finestra critica < 1s
  3. reset Postgres checkpoint                      # Gen Server riparte da 0
  4. GenServer.call(pid, :resume_writes)            # sblocca
```

Il GenServer riceve `:pause_writes` e rimane bloccato in `handle_call` finché il Mix task non chiama `:resume_writes`. Gli eventi in arrivo durante la pausa si accumulano nella mailbox OTP (buffer naturale) e vengono processati dopo il resume — ma poiché il checkpoint è stato resettato, il GenServer si riabbona da position 0 e rilegge tutto dal nuovo indice.

**Alternativa considerata: Postgres advisory lock** — più robusta per deployment distribuiti ma richiede un lock ID statico per projector, introduce dipendenza dal Repo nel Mix task per la pausa, e non aggiunge benefici nel caso single-node (che è il tipico caso d'uso del Mix task).

**Alternativa considerata: Supervisor.terminate_child + restart** — downtime completo durante il rebuild; non soddisfa RBLD-01 (zero-downtime).

**Alternativa considerata: dual-write durante rebuild** — complessità estrema, non necessaria per un Mix task sincrono.

### Gestione dello stream per hotswap

`Snap.Indexes.hotswap/5` accetta qualsiasi `Enumerable.t()` di action structs. Il Mix task costruisce il stream in modo **eager** (non lazy, poiché l'EventStore InMemory è sincrono):

```elixir
# [VERIFIED: Snap.Indexes source - deps/snap/lib/snap/indexes.ex]
def hotswap(stream, cluster, alias, mapping, opts \\ []) do
  index = generate_index_name(alias)           # "{alias}-{unix_microseconds}"
  bulk_opts = Keyword.take(opts, [:page_size, :page_wait, :max_errors, :request_opts])
  with {:ok, _} <- create(cluster, index, mapping),
       :ok <- Bulk.perform(stream, cluster, index, bulk_opts),
       :ok <- refresh(cluster, index, request_opts),
       :ok <- alias(cluster, index, alias, request_opts) do
    cleanup(cluster, alias, 2, request_opts)
  end
end
```

Il nome dell'indice versioned è generato internamente da Snap: `"#{alias}-#{DateTime.to_unix(DateTime.utc_now(), :microsecond)}"` [VERIFIED: codice Snap 0.16.0].

### Estensione di `__projection_config__/0`

Il Mix task ES ha bisogno di `:backend`, `:cluster`, `:index`, e l'handler function — informazioni non esposte dall'attuale `__projection_config__/0`. Due opzioni:

**Opzione A (preferita):** Estendere `__projection_config__/0` nel macro `Orkestra.Projector` per includere i campi ES:

```elixir
# Aggiunta in Projector.__before_compile__:
def __projection_config__ do
  %{
    repo: repo,
    projector_name: projector_name,
    migrations_path: migrations_path,
    migration_source: migration_source,
    backend: :elasticsearch,           # nuovo
    cluster: MyApp.ESCluster,          # nuovo (nil per Postgres)
    index: "orders",                   # nuovo (nil per Postgres)
    projector_module: __MODULE__       # nuovo (per recuperare index_mapping/0)
  }
end
```

**Opzione B:** Costruire il `child_spec` e ispezionare `adapter_opts` — fragile, non è un'API pubblica.

**Scelta: Opzione A** perché è l'API già usata da tutti i Mix task esistenti.

### Mix Task Pattern

```elixir
# lib/mix/tasks/orkestra.projection.es.rebuild.ex
if Code.ensure_loaded?(Snap.Cluster) and Code.ensure_loaded?(Ecto.Migrator) do
  defmodule Mix.Tasks.Orkestra.Projection.Es.Rebuild do
    use Mix.Task

    @impl Mix.Task
    def run(args) do
      # ... same pattern as orkestra.projection.rebuild
      Mix.Task.run("app.start")
      module = Module.concat([projector_module_str])
      config = module.__projection_config__()

      # config.backend must be :elasticsearch
      # config.cluster, config.index, config.projector_module available
    end
  end
end
```

### Recommended Project Structure

```
lib/
├── mix/tasks/
│   └── orkestra.projection.es.rebuild.ex    # nuovo Mix task (RBLD-02)
├── orkestra/projector/gen_server.ex          # aggiungere :pause_writes / :resume_writes
└── orkestra/projector.ex                     # estendere __projection_config__/0
test/
└── mix/tasks/
    └── orkestra.projection.es.rebuild_test.exs  # test del Mix task
```

### Anti-Patterns to Avoid

- **Usare il GenServer esistente come producer per hotswap**: il GenServer è event-driven (mailbox), non stream-compatible con `Enumerable`. Costruire lo stream nel Mix task direttamente.
- **Fare `Supervisor.terminate_child` durante il rebuild**: causa downtime, viola RBLD-01. Il GenServer deve rimanere vivo durante il rebuild, solo pausato durante la finestra di swap.
- **Resettare il checkpoint prima del hotswap**: se il hotswap fallisce, il GenServer live ripartirebbe da 0 scrivendo sull'indice vecchio. Reset checkpoint solo dopo hotswap riuscito.
- **Ignorare `Snap.BulkError` nel hotswap**: `hotswap/5` può restituire `{:error, %Snap.BulkError{}}` — il Mix task deve propagare questo errore e NON swappare l'alias.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Alias swap atomica | Logica custom `POST /_aliases` | `Snap.Indexes.hotswap/5` | Gestisce create, bulk, refresh, alias, cleanup in sequenza |
| Versioned index naming | Schema timestamp custom | Snap interno (`generate_index_name/1`) | Già implementato: `"{alias}-{unix_microseconds}"` |
| Bulk loading durante rebuild | Loop `Snap.Document.index` singolo | `Snap.Bulk.perform/4` via `hotswap` | Chunking, page_wait, errori parziali gestiti |
| Index cleanup post-swap | `Snap.Indexes.delete` manuale | `hotswap` → `cleanup/4` interno | Preserva 2 indici più recenti automaticamente |

**Key insight:** `Snap.Indexes.hotswap/5` è progettato esattamente per questo caso d'uso — zero-downtime rebuild con alias swap. Il docstring Snap recita: "Creates and loads a new index, switching the alias to it with zero-downtime." [VERIFIED: deps/snap/lib/snap/indexes.ex riga 186].

---

## Common Pitfalls

### Pitfall 1: `hotswap` richiede stream, non chiamata GenServer
**What goes wrong:** Si prova a usare il GenServer esistente per alimentare `hotswap` — ma il GenServer è event-driven (receive loop) e non espone un `Enumerable`.
**Why it happens:** Confusione tra il GenServer catch-up mode (che accumula un buffer interno) e l'interfaccia stream di `hotswap`.
**How to avoid:** Costruire lo stream ES nel Mix task stesso: leggere eventi dall'EventStore, invocare `projector_module.__handle_es__/3`, filtrare `:skip`, trasformare in `%Snap.Bulk.Action.Index{}`.
**Warning signs:** Se si prova a passare il buffer `state.es_buffer` di un GenServer a `hotswap`, si ha il segnale.

### Pitfall 2: Race tra rebuild bulk write e GenServer live sull'indice vecchio
**What goes wrong:** Il GenServer live continua a scrivere sull'alias durante il rebuild. Quando l'alias viene swappato, quegli eventi sono scritti sull'indice vecchio (ora non più puntato dall'alias). Dopo il reset del checkpoint, il GenServer rilegge quegli eventi e li scrive correttamente sul nuovo indice — quindi in realtà questo non è un problema di perdita dati, ma è un'inefficienza.
**Why it happens:** La vera race è: il GenServer scrive evento X sull'alias (vecchio indice) DOPO che il checkpoint è stato resettato, ma PRIMA che il GenServer si riabboni. L'evento X viene quindi scritto sul nuovo indice quando il GenServer riparte — no perdita dati.
**How to avoid:** La pausa durante la finestra di swap (`:pause_writes`) è sufficiente. Il reset del checkpoint dopo la swap garantisce che il GenServer rilegga tutto da 0 sul nuovo indice.

### Pitfall 3: Checkpoint reset prima del hotswap riuscito
**What goes wrong:** Si resetta il checkpoint Postgres PRIMA di chiamare `hotswap`. Se `hotswap` fallisce (es. BulkError), il GenServer live si riabbona da 0 ma scrive sull'indice vecchio (l'alias non è cambiato). Il rebuild è in uno stato inconsistente.
**Why it happens:** Ordine sbagliato delle operazioni.
**How to avoid:** Sequenza corretta: (1) hotswap COMPLETO con successo → (2) reset checkpoint → (3) resume GenServer.

### Pitfall 4: `__projection_config__/0` non espone info ES
**What goes wrong:** Il Mix task chiama `module.__projection_config__()` ma non trova `:cluster`, `:index`, `:backend`.
**Why it happens:** La shape corrente di `__projection_config__/0` espone solo `%{repo, projector_name, migrations_path, migration_source}`.
**How to avoid:** Estendere `__before_compile__` in `Orkestra.Projector` per includere `:backend`, `:cluster`, `:index`, `:projector_module` nella mappa restituita.
**Warning signs:** `KeyError` su `config.cluster` nel Mix task.

### Pitfall 5: Mix task usa `app.config` invece di `app.start`
**What goes wrong:** Con `app.config` (come in `orkestra.projection.migrate`) il GenServer live non è avviato — la pausa non funziona.
**Why it happens:** I task che non hanno bisogno di processi usano `app.config` per velocità.
**How to avoid:** Usare `Mix.Task.run("app.start")` come fa `orkestra.projection.rebuild`.

### Pitfall 6: `Snap.Indexes.cleanup` del hotswap preserva 2 indici
**What goes wrong:** Dopo molti rebuild, ci sono molti indici versioned. Si crede di dover pulire manualmente.
**Why it happens:** Non si legge il codice Snap.
**How to avoid:** `hotswap/5` chiama `cleanup(cluster, alias, 2, request_opts)` internamente — preserva i 2 più recenti, cancella i più vecchi. Non serve cleanup manuale. [VERIFIED: deps/snap/lib/snap/indexes.ex riga 206].

---

## Code Examples

### hotswap/5 — signature verificata

```elixir
# [VERIFIED: deps/snap/lib/snap/indexes.ex]
@spec hotswap(Enumerable.t(), module(), String.t(), map(), Keyword.t()) ::
        :ok | Cluster.error() | {:error, BulkError.t()}
def hotswap(stream, cluster, alias, mapping, opts \\ []) do
  index = generate_index_name(alias)   # "{alias}-{unix_microseconds}"
  bulk_opts = Keyword.take(opts, [:page_size, :page_wait, :max_errors, :request_opts])
  request_opts = Keyword.get(opts, :request_opts, [])
  with {:ok, _} <- create(cluster, index, mapping),
       :ok <- Bulk.perform(stream, cluster, index, bulk_opts),
       :ok <- refresh(cluster, index, request_opts),
       :ok <- alias(cluster, index, alias, request_opts) do
    cleanup(cluster, alias, 2, request_opts)
  end
end
```

### Costruzione dello stream ES nel Mix task

```elixir
# [ASSUMED — pattern da costruire]
defp build_rebuild_stream(event_store, projector_module, projector_name) do
  # 1. Recupera snapshot degli eventi (sincrono per InMemory; per EventStoreDB
  #    serve il subscribe_from_position o load_events paginato)
  # 2. Invoca __handle_es__/3 per ogni evento
  # 3. Filtra :skip, trasforma in Snap.Bulk.Action.Index

  # Nota: subscribe_from_position è asincrono (push model) —
  # per il rebuild si usa un approccio diverso:
  # raccogliere tutti gli eventi prima di costruire lo stream
  all_events = collect_all_events(event_store)

  all_events
  |> Enum.flat_map(fn event ->
    case projector_module.__handle_es__(projector_name, event, event.global_position) do
      {:ok, doc, id} -> [%Snap.Bulk.Action.Index{id: id, doc: doc}]
      :skip           -> []
      {:error, _}     -> []   # oppure raise se errori fatali
    end
  end)
end
```

### Pausa GenServer durante alias swap (RBLD-03)

```elixir
# [ASSUMED — da aggiungere a GenServer]
def handle_call(:pause_writes, _from, state) do
  # Rimane bloccato qui finché il caller non chiama :resume_writes
  # Le write in arrivo nella mailbox si accumulano ma non vengono processate
  # perché handle_info non viene invocato mentre siamo in handle_call.
  {:reply, :ok, %{state | writes_paused: true}}
end

def handle_call(:resume_writes, _from, state) do
  {:reply, :ok, %{state | writes_paused: false}}
end

# In apply_event: se writes_paused, mettere in un buffer di "pending"
# oppure semplicemente: la pausa è abbastanza breve (< 1s) che la mailbox
# OTP accumula i messaggi senza problemi.
```

**Nota importante:** La pausa non deve essere implementata con un loop attivo — è sufficiente che il GenServer rimanga in `handle_call` finché la swap è completata. Durante questo tempo, i messaggi si accumulano nella mailbox OTP e vengono processati dopo il resume. Dopo il resume, il checkpoint viene resettato e il GenServer si riabbona da 0, processando di nuovo tutti gli eventi sull'indice nuovo (quelli accumulati in mailbox verranno ignorati se il checkpoint globale li supera, oppure processati idempotentemente grazie agli `_id` deterministici).

### Errore di ritorno atteso

```elixir
# [VERIFIED: Snap.Indexes source]
# hotswap può restituire:
:ok                                   # successo
{:error, %Snap.ResponseError{}}       # ES API error (es. create fallito)
{:error, %Snap.BulkError{errors: _}}  # bulk partial failure
{:error, %Snap.HTTPError{}}           # connessione fallita
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Delete + re-create indice con downtime | Alias swap zero-downtime | Pattern ES standard | Nessun downtime durante rebuild |
| Rebuild tramite GenServer restart | Mix task con stream in-process | Phase 9 | Nessuna dipendenza dal GenServer supervisor |

---

## Runtime State Inventory

Non applicabile — questa è una fase greenfield (nuovo Mix task + estensioni). Non ci sono rename/refactor che interessano state runtime esistente.

---

## Open Questions

1. **Strategia per EventStoreDB in rebuild**
   - Cosa sappiamo: `subscribe_from_position` è asincrono (push model). Per il rebuild abbiamo bisogno di un approccio sincrono / eager per costruire l'Enumerable.
   - Cosa è incerto: `Orkestra.EventStore.EventStoreDB` non espone un `load_all_events/0` sincrono. `subscribe_from_position(:all, -1, self())` poi raccogliere via `receive` in loop è fattibile ma fragile per grandi volumi.
   - Recommendation: Per Phase 9 usare il pattern di raccolta via `receive` con timeout come meccanismo di "fine stream"; documentare che per produzioni con EventStoreDB si può implementare un helper `stream_all_events/1` paginato in una fase futura. Il Mix task può ricevere un `--timeout` option.

2. **GenServer live può non essere avviato**
   - Cosa sappiamo: Il Mix task dovrebbe girare con `app.start`, ma se il GenServer non è sotto `Orkestra.Projection.Supervisor` la pausa non può essere fatta.
   - Cosa è incerto: Come il Mix task scopre il PID del GenServer live.
   - Recommendation: Usare `GenServer.whereis(module)` o `Process.whereis(module)` (se il GenServer ha un nome registrato). Se `nil`, procedere senza pausa (il GenServer non è live — nessuna race).

3. **`__projection_config__/0` estesa non è breaking change?**
   - Cosa sappiamo: I Mix task esistenti usano `config.repo`, `config.projector_name`, `config.migrations_path`, `config.migration_source` — tutti campi che restano.
   - Cosa è incerto: Se qualche consumatore esterno dipende dalla esatta shape della mappa.
   - Recommendation: L'aggiunta di nuovi campi è backward-compatible. I campi `:cluster`, `:index`, `:backend` saranno `nil` per projector Postgres — il Mix task ES deve verificare che `config.backend == :elasticsearch` e fallire con errore chiaro altrimenti.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Snap ~> 0.16 | Rebuild + Mix task | ✓ | 0.16.0 | — |
| Ecto / Ecto.SQL | Checkpoint reset | ✓ | ~> 3.12 | — |
| Elixir Mix | Mix task | ✓ | ~> 1.18 | — |
| Elasticsearch / OpenSearch | hotswap (test) | Via Mox in test | — | Mox.stub per unit test |

Il Mix task è wrappato in `if Code.ensure_loaded?(Snap.Cluster) and Code.ensure_loaded?(Ecto.Migrator)` — coerente con il pattern degli altri task.

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in Elixir) |
| Config file | `test/test_helper.exs` |
| Quick run command | `mix test test/mix/tasks/orkestra.projection.es.rebuild_test.exs --include elasticsearch` |
| Full suite command | `mix test --include elasticsearch` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| RBLD-01 | hotswap crea indice versioned, swappa alias, cleanup | unit (Mox) | `mix test test/mix/tasks/orkestra.projection.es.rebuild_test.exs -k "hotswap"` | ❌ Wave 0 |
| RBLD-02 | Mix task accetta modulo projector ES, esegue rebuild completo | integration (Mox) | `mix test test/mix/tasks/orkestra.projection.es.rebuild_test.exs` | ❌ Wave 0 |
| RBLD-03 | GenServer live viene pausato durante alias swap | unit | `mix test test/mix/tasks/orkestra.projection.es.rebuild_test.exs -k "pause"` | ❌ Wave 0 |
| (supporto) | `__projection_config__/0` espone backend/cluster/index | unit | `mix test test/orkestra/projector/projector_dsl_es_test.exs -k "projection_config"` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `mix compile --warnings-as-errors`
- **Per wave merge:** `mix test --include elasticsearch`
- **Phase gate:** Full suite green incluso `--include elasticsearch`

### Wave 0 Gaps
- [ ] `test/mix/tasks/orkestra.projection.es.rebuild_test.exs` — covers RBLD-01, RBLD-02, RBLD-03
- [ ] Directory `test/mix/tasks/` da creare
- [ ] Mock Snap HTTP per hotswap: stub `PUT /{index}` (create), `POST /_bulk`, `POST /{index}/_refresh`, `POST /_aliases`, `DELETE /{old-index}`

---

## Security Domain

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | no | — |
| V5 Input Validation | yes | Validare che il modulo passato al task sia un ES projector (`config.backend == :elasticsearch`) |
| V6 Cryptography | no | — |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Module injection via CLI args | Tampering | `Module.concat([projector_module_str])` + verifica `config.backend == :elasticsearch` |
| Credential logging durante rebuild | Info Disclosure | Non loggare `adapter_opts` (pattern già stabilito nelle fasi precedenti) |
| Rebuild su indice produzione errato | Tampering | Conferma interattiva (`--yes` skip) come in `orkestra.projection.rebuild` |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | Il GenServer live ha un nome registrato (o è trovabile via `Process.whereis`) per la pausa RBLD-03 | Architecture Patterns — Live Write Pause | Se il GenServer non ha nome registrato, la pausa richiede un registro separato o si salta |
| A2 | Lo stream per `hotswap` può essere costruito raccogliendo eventi via `receive` loop dal subscribe_from_position | Code Examples — build_rebuild_stream | Se EventStoreDB non segnala "fine stream", il rebuild si blocca |
| A3 | L'aggiunta di campi a `__projection_config__/0` è backward-compatible con i consumatori esistenti | Open Questions 3 | Se esistono consumatori che pattern-match esattamente sulla mappa, potrebbe rompere |

---

## Sources

### Primary (HIGH confidence)
- `/data/progetti/orkestra/deps/snap/lib/snap/indexes.ex` — `hotswap/5`, `alias/4`, `cleanup/4`, `generate_index_name/1` signature e implementazione complete [VERIFIED]
- `/data/progetti/orkestra/deps/snap/lib/snap/bulk/bulk.ex` — `perform/4` signature e comportamento [VERIFIED]
- `/data/progetti/orkestra/deps/snap/lib/snap/bulk/action.ex` — `Snap.Bulk.Action.Index` struct [VERIFIED]
- `/data/progetti/orkestra/lib/orkestra/projector/gen_server.ex` — state machine GenServer, `es_mode`, `rebuild_total` [VERIFIED]
- `/data/progetti/orkestra/lib/orkestra/projector.ex` — `__projection_config__/0` shape attuale, `__handle_es__/3` [VERIFIED]
- `/data/progetti/orkestra/lib/mix/tasks/orkestra.projection.rebuild.ex` — pattern Mix task da seguire [VERIFIED]
- `/data/progetti/orkestra/lib/orkestra/projection/storage/elasticsearch.ex` — `reset/2`, `init/1` [VERIFIED]
- `/data/progetti/orkestra/mix.lock` — versione Snap 0.16.0 [VERIFIED]

### Secondary (MEDIUM confidence)
- `/data/progetti/orkestra/.planning/phases/08-projector-macro-dsl-for-elasticsearch/08-01-SUMMARY.md` — conferma `__handle_es__/3`, `__projection_config__` shape [VERIFIED via summary]
- `/data/progetti/orkestra/.planning/phases/07-genserver-es-commit-path-and-batch-indexing/07-01-SUMMARY.md` — conferma `es_mode`, bulk path, `rebuild_total` [VERIFIED via summary]

---

## Metadata

**Confidence breakdown:**
- Standard stack: HIGH — Snap 0.16.0 verificato nel mix.lock e nel codice sorgente locale
- Architecture (hotswap stream): HIGH — `Snap.Indexes.hotswap/5` letto direttamente dal source
- Live write pause (RBLD-03): MEDIUM — strategia `GenServer.call` analizzata ma non ancora implementata; dipende da come il GenServer è registrato
- Pitfalls: HIGH — basati su analisi del codice esistente

**Research date:** 2026-06-25
**Valid until:** 2026-07-25 (Snap 0.16 stabile; architettura interna stabile)
