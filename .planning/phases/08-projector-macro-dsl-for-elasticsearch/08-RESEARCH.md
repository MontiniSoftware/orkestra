# Phase 8: Projector Macro DSL for Elasticsearch - Research

**Ricercato:** 2026-06-25
**Dominio:** Elixir macro DSL — estensione di `Orkestra.Projector` per backend Elasticsearch
**Confidenza:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions

- `backend: :elasticsearch` option su `use Orkestra.Projector` — seleziona l'ES adapter
- `project_es/2` macro — analogo al `project/2` esistente ma per handler ES; l'handler restituisce `{:ok, doc, id} | :skip | {:error, reason}` invece di `{:ok, Ecto.Multi.t()}`
- `index_mapping/0` callback — il projector ES definisce il suo index mapping (ADPT-06, già nell'adapter da Phase 6)
- `child_spec/1` wiring — quando `backend: :elasticsearch`, iniettare `storage_adapter: Orkestra.Projection.Storage.Elasticsearch` e `adapter_opts: [cluster: ..., index: ..., handler: &__MODULE__.__handle_es__/3]`
- **Checkpoint ordering (ADPT-07):** ES-first, Postgres-second — già implementato in Phase 7 GenServer; la DSL deve solo cablare correttamente
- **Backward compatibility:** Il macro `project/2` esistente e il `child_spec/1` Postgres devono funzionare identicamente — nessun breaking change

### Handler Function

- ES handler: `__handle_es__/3` prende `(projector_name, event, position)` e restituisce `{:ok, doc, id} | :skip | {:error, reason}`
- Corrisponde al pattern `:handler` dell'adapter Postgres (Phase 6)
- `project_es/2` macro accumula le funzioni handler e genera `__dispatch_es__/3` + `__handle_es__/3` (speculare a `__dispatch__/3` + `__handle__/3`)

### Claude's Discretion

Tutte le scelte implementative sono a discrezione di Claude — fase puramente infrastrutturale.

### Deferred Ideas (OUT OF SCOPE)

Nessuna.
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| ADPT-05 | Projector DSL supports `backend: :elasticsearch` option with `project_es/2` macro | Pattern chiaro in codebase: `project/2` macro esistente nel `__using__/1` + `__before_compile__/1` pipeline; l'ES variant segue lo stesso schema con attributo accumulato separato |
| ADPT-07 | Checkpoint writes follow ES-first, Postgres-second ordering | Già implementato completamente in Phase 7 GenServer (`commit_es_checkpoint/3`); la DSL deve solo iniettare `storage_adapter: Storage.Elasticsearch` e `adapter_opts` corretti |
</phase_requirements>

---

## Summary

Questa fase aggiunge il supporto `backend: :elasticsearch` al macro `Orkestra.Projector` esistente. Il file da modificare è uno solo (`lib/orkestra/projector.ex`) più un file di test nuovo (`test/orkestra/projector/projector_dsl_es_test.exs`). Nessuna modifica al GenServer è necessaria — i percorsi ES-first/Postgres-second sono già implementati in Phase 7.

La struttura del lavoro è diretta: il `__using__/1` deve leggere il nuovo option `backend: :elasticsearch`, registrare un attribute accumulato separato `@es_projection_handlers`, importare il nuovo macro `project_es/2`, e il `__before_compile__/1` deve generare `__dispatch_es__/3`, `__handle_es__/3`, e la branch ES nel `child_spec/1`.

**Critical gap identificato:** `storage_adapter.init/1` non viene chiamato in nessun punto del GenServer attuale (verificato con grep). Il GenServer ES richiede che l'ES adapter esegua engine detection e crei l'index ES prima che arrivino eventi. Questo deve essere cablato in `handle_info(:load_checkpoint, ...)` — o come step separato `handle_info(:init_adapter, ...)`. Phase 8 deve decidere e implementare questo wiring. [VERIFIED: grep su lib/orkestra/projector/gen_server.ex]

**Raccomandazione primaria:** Modificare un file sorgente (`projector.ex`), aggiungere un test file DSL per ES, e cablare la chiamata `storage_adapter.init/1` in `handle_info(:load_checkpoint, ...)` nel GenServer (oppure come messaggio `send(self(), :init_adapter)` prima del `:load_checkpoint`).

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| `project_es/2` macro accumulation | Compile-time DSL (`projector.ex`) | — | I macro Elixir funzionano a compile-time; il DSL accumula definizioni via Module attribute |
| `__dispatch_es__/3` + `__handle_es__/3` generation | Compile-time (`__before_compile__`) | — | Generato da `__before_compile__` identicamente al path Postgres |
| `child_spec/1` ES branch | Compile-time DSL (`projector.ex`) | — | Inietta `storage_adapter:` e `adapter_opts:` corretti nel config del GenServer |
| `storage_adapter.init/1` call | Runtime GenServer (`gen_server.ex`) | — | Engine detection e index creation sono operazioni I/O; appartengono al runtime, non al compile-time |
| ES write + checkpoint commit | Runtime GenServer (già in Phase 7) | — | `commit_es_single_doc`, `flush_es_buffer`, `commit_es_checkpoint` già implementati |
| `index_mapping/0` callback | Projector module (utente) | ES Adapter (`ensure_index`) | Il projector definisce il mapping; l'adapter lo applica via `Snap.Indexes.create` |

---

## Standard Stack

### Core (già presente nel progetto)

| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir | ~> 1.18 | Runtime + macro system | Requisito progetto |
| Snap | ~> 0.16 | ES/OpenSearch HTTP client | Scelto in Phase 6 — unico client Elixir ES mantenuto [VERIFIED: mix.exs] |
| Ecto | ~> 3.12 | Checkpoint Postgres storage | Già dipendenza opzionale progetto [VERIFIED: mix.exs] |
| ExUnit | built-in | Test framework | Standard Elixir |

**Nessuna nuova dipendenza necessaria per questa fase.** [VERIFIED: tutte le dipendenze già presenti in mix.exs]

---

## Architecture Patterns

### System Architecture Diagram

```
use Orkestra.Projector, backend: :elasticsearch, ...
         │
         ▼ compile-time
  __using__/1
  ├── register @es_projection_handlers (accumulate: true)
  ├── import project_es/2 macro
  └── @before_compile Orkestra.Projector
         │
         ▼ compile-time
  __before_compile__/1
  ├── genera __dispatch_es__/3  (una clause per evento ES registrato)
  ├── genera __handle_es__/3    (bridge che chiama __dispatch_es__)
  ├── genera child_spec/1 (branch ES):
  │     storage_adapter: Storage.Elasticsearch
  │     adapter_opts: [cluster:, index:, handler: &__handle_es__/3, projector_module: __MODULE__]
  └── mantiene __projection_config__/0, __dispatch__/3, __handle__/3 invariati
         │
         ▼ runtime (startup)
  Projector.GenServer.init/1
  ├── send(self(), :init_adapter)  ← NUOVO: precede :load_checkpoint
  └── ... (invariato)
         │
         ▼
  handle_info(:init_adapter, state)  ← NUOVO
  ├── storage_adapter.init(adapter_opts)  ← chiama Storage.Elasticsearch.init/1
  ├── {:ok, _} → send(self(), :load_checkpoint)
  └── {:error, reason} → Logger.error + {:stop, reason, state}
         │
         ▼ (identico a Phase 7)
  handle_info(:load_checkpoint, state)
  └── subscribe + avanzamento checkpoint (invariato)
         │
         ▼ runtime (per ogni evento)
  apply_event → Storage.Elasticsearch.write/4 → {action: :index | :skip}
  ├── :live → Snap.Document.index → commit_es_checkpoint (Postgres)
  └── :catching_up → accumula buffer → flush Snap.Bulk.perform → commit_es_checkpoint
```

### Recommended Project Structure

```
lib/orkestra/
├── projector.ex                    # MODIFICARE: aggiungere backend:, project_es/2, __dispatch_es__/3
└── projector/
    └── gen_server.ex               # MODIFICARE: aggiungere handle_info(:init_adapter, ...)

test/orkestra/projector/
├── projector_dsl_test.exs          # ESISTENTE — non toccare, deve passare invariato
├── projector_dsl_es_test.exs       # CREARE: test DSL ES compile-time
└── gen_server_es_test.exs          # ESISTENTE Phase 7 — non toccare
```

### Pattern 1: Accumulate + Before Compile (pattern DSL esistente)

**What:** Il macro `__using__/1` registra Module attributes accumulabili; `__before_compile__/1` li legge e genera funzioni.
**When to use:** Sempre per DSL Elixir che devono raccogliere definizioni multi-elemento prima della generazione del codice.

```elixir
# Source: lib/orkestra/projector.ex (verificato)

# In __using__/1:
Module.register_attribute(__MODULE__, :es_projection_handlers, accumulate: true)
Module.put_attribute(__MODULE__, :_projector_backend, :elasticsearch)

# In project_es/2 macro:
defmacro project_es(event_module, handler_fn) do
  escaped = Macro.escape(handler_fn)
  quote do
    @es_projection_handlers {unquote(event_module), unquote(escaped)}
  end
end

# In __before_compile__/1:
es_handlers = Module.get_attribute(env.module, :es_projection_handlers) |> Enum.reverse()

# Genera una clause per ogni handler ES registrato:
es_dispatch_clauses =
  Enum.map(es_handlers, fn {event_module, handler_fn} ->
    type_string = inspect(event_module)
    quote do
      def __dispatch_es__(unquote(type_string), event, position) do
        unquote(handler_fn).(event.data, position)
      end
    end
  end)
```

### Pattern 2: child_spec/1 Branch per Backend

**What:** Il `child_spec/1` generato biforca su `backend: :elasticsearch` per iniettare l'adapter e le opts corrette.
**When to use:** Quando un modulo deve supportare backend multipli con configurazioni diverse.

```elixir
# Source: lib/orkestra/projector.ex + 08-CONTEXT.md (verified decision)

# Postgres branch (invariato):
def child_spec(opts \\ []) when backend == :postgres do
  config = %{
    repo: @_projector_repo,
    storage_adapter: Orkestra.Projection.Storage.Postgres,
    adapter_opts: [handler: &__MODULE__.__handle__/3],
    ...
  }
  Map.merge(config, Map.new(opts))
  |> then(&%{id: __MODULE__, start: {Orkestra.Projector.GenServer, :start_link, [&1]}})
end

# ES branch (nuovo):
def child_spec(opts \\ []) when backend == :elasticsearch do
  config = %{
    repo: @_projector_repo,            # checkpoint rimane su Postgres
    storage_adapter: Orkestra.Projection.Storage.Elasticsearch,
    adapter_opts: [
      cluster: @_projector_es_cluster,
      index: @_projector_es_index,
      handler: &__MODULE__.__handle_es__/3,
      projector_module: __MODULE__      # richiesto da Storage.Elasticsearch.init/1
    ],
    ...
  }
  Map.merge(config, Map.new(opts))
  |> then(&%{id: __MODULE__, start: {Orkestra.Projector.GenServer, :start_link, [&1]}})
end
```

**Nota implementativa:** In realtà, poiché `backend` è una costante compile-time, il `child_spec/1` generato può usare un `if` normale (non guardie) o generare due funzioni con nomi distinti. L'approccio più pulito è una singola `child_spec/1` con `if backend == :elasticsearch do ... else ... end` in `__before_compile__/1`. [ASSUMED]

### Pattern 3: __handle_es__/3 — Bridge Function

**What:** `__handle_es__/3` è la funzione esposta al GenServer tramite `adapter_opts[:handler]`. Chiama `__dispatch_es__/3` e traduce `:skip` nel return corretto.
**When to use:** Speculare al `__handle__/3` del path Postgres.

```elixir
# Source: lib/orkestra/projector.ex pattern __handle__/3 (verified), adattato per ES

@spec __handle_es__(String.t(), map(), non_neg_integer()) ::
        {:ok, map(), String.t()} | :skip | {:error, term()}
def __handle_es__(projector_name, event, position) do
  case __dispatch_es__(event.type, event, position) do
    {:ok, doc, id} -> {:ok, doc, id}
    :skip -> :skip
    {:error, reason} -> {:error, reason}
  end
end
```

**Contratto con Storage.Elasticsearch.write/4:** L'handler ES restituisce `{:ok, doc, id} | :skip | {:error, reason}` — esattamente il formato atteso da `write/4` riga 131 in `lib/orkestra/projection/storage/elasticsearch.ex`. [VERIFIED: elasticsearch.ex:131]

### Pattern 4: storage_adapter.init/1 wiring nel GenServer

**What:** Il GenServer deve chiamare `storage_adapter.init/1` prima di caricare il checkpoint per gli adapter ES. Questo deve avvenire come step separato per mantenere la finestra di Sandbox.allow già stabilita.

**Analisi del gap:** Attualmente `GenServer.init/1` invia solo `send(self(), :load_checkpoint)`. La chiamata `storage_adapter.init/1` non è invocata da nessuna parte nel GenServer. L'ES adapter `init/1` richiede `cluster`, `index`, e `projector_module` in `adapter_opts`. [VERIFIED: grep "storage_adapter.init" — NONE FOUND in gen_server.ex]

**Implementazione raccomandata:**

```elixir
# In GenServer.init/1 — MODIFICARE:
def init(config) do
  state = %{ ... } # invariato

  # Per ES adapter che richiede init, invia :init_adapter prima di :load_checkpoint
  # Postgres adapter non implementa init/1 (@optional_callbacks init: 1)
  if function_exported?(Map.fetch!(config, :storage_adapter), :init, 1) do
    send(self(), :init_adapter)
  else
    send(self(), :load_checkpoint)
  end

  {:ok, state}
end

# Nuovo handler:
def handle_info(:init_adapter, state) do
  case state.storage_adapter.init(state.adapter_opts) do
    {:ok, _adapter_state} ->
      # adapter_state ignorato per ora (già incluso in adapter_opts via cluster/index/engine)
      send(self(), :load_checkpoint)
      {:noreply, state}

    {:error, reason} ->
      Logger.error("Projector adapter init failed",
        projector: state.projector_name,
        reason: inspect(reason),
        orkestra: :projector
      )
      {:stop, {:adapter_init_failed, reason}, state}
  end
end
```

[ASSUMED]: La decisione esatta su come gestire `adapter_state` (ignorarlo vs memorizzarlo in state) è a discrezione. Dato che il GenServer ES già legge `cluster`, `index`, `engine` direttamente da `adapter_opts`, la forma più semplice è ignorare il `{:ok, map()}` restituito da `init/1` — tutte le info sono già disponibili in `adapter_opts`.

### Pattern 5: Opzioni `use Orkestra.Projector` per backend ES

**What:** Le opzioni aggiuntive richieste quando `backend: :elasticsearch`.

```elixir
# Interfaccia pubblica definita da CONTEXT.md (locked decision):
defmodule MyApp.OrderESProjector do
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: MyApp.OrderProjection.Repo,     # checkpoint Postgres (OBBLIGATORIO)
    cluster: MyApp.ESCluster,             # Snap.Cluster module
    index: "orders",                      # nome index ES
    event_store: Orkestra.EventStore.InMemory

  @impl true
  def index_mapping do
    %{
      "mappings" => %{
        "properties" => %{
          "order_id" => %{"type" => "keyword"},
          "status" => %{"type" => "keyword"}
        }
      }
    }
  end

  project_es MyApp.Events.OrderPlaced, fn event, position ->
    {:ok, %{"order_id" => event.data.order_id, "status" => "placed"}, event.data.order_id}
  end
end
```

**Opzioni aggiuntive da parsare in `__using__/1`:**
- `:cluster` — il modulo `Snap.Cluster` (es. `MyApp.ESCluster`)
- `:index` — nome dell'index ES (stringa)
- `:batch_size` — dimensione batch bulk (default: 500, opzionale)

[ASSUMED]: i nomi esatti delle opzioni (`:cluster`, `:index`, `:batch_size`) sono ragionevoli per coerenza con `adapter_opts` del GenServer, ma non sono stati esplicitamente definiti in CONTEXT.md.

### Anti-Patterns to Avoid

- **Non chiamare `Snap.Document.index` o HTTP direttamente dal macro:** Il DSL è compile-time; tutto l'I/O vive nel GenServer.
- **Non mischiare handler ES e Postgres nello stesso projector:** Un modulo usa un solo backend; avere sia `project/2` che `project_es/2` è un errore da rilevare in `__before_compile__/1` con un `IO.warn` o raise.
- **Non omettere `:projector_module` in `adapter_opts`:** `Storage.Elasticsearch.init/1` fa `Keyword.fetch!(opts, :projector_module)` che lancia se mancante [VERIFIED: elasticsearch.ex:95].
- **Non chiamare `storage_adapter.init/1` dentro `GenServer.init/1` direttamente:** Rompe la finestra `Sandbox.allow/3` — la chiamata deve essere deferita via `send(self(), :init_adapter)`.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Accumulo handler defs a compile-time | Lista di tuples in ETS o agent | `Module.register_attribute(..., accumulate: true)` | Pattern standard Elixir per DSL compile-time [VERIFIED: projector.ex:157] |
| Generazione dispatch functions | Parsing AST manuale | `Macro.escape/1` + `quote do ... unquote_splicing(...) end` | Pattern già usato in `__before_compile__` per `project/2` [VERIFIED: projector.ex:202] |
| Engine detection ES | Codice custom | `Storage.Elasticsearch.init/1` già lo fa | Implementato in Phase 6 [VERIFIED: elasticsearch.ex:92] |
| Index creation | `Snap.post(cluster, "/indices/...", ...)` custom | `Storage.Elasticsearch.init/1` + `ensure_index` private | Già implementato e testato [VERIFIED: elasticsearch.ex:234] |

---

## Runtime State Inventory

Non applicabile — questa è una fase greenfield di estensione macro. Non ci sono rename, refactor, o migration di dati esistenti.

---

## Common Pitfalls

### Pitfall 1: `Keyword.fetch!` in `__using__/1` per opzioni ES obbligatorie

**What goes wrong:** Se `:cluster` o `:index` sono richiesti ma non passati, il compilatore fallisce con `KeyError` a compile-time al `use Orkestra.Projector` — messaggio d'errore confuso.
**Why it happens:** `Keyword.fetch!` lancia immediatamente durante l'espansione del macro.
**How to avoid:** Usare `Keyword.get(opts, :cluster, nil)` in `__using__/1` e rimandare la validazione a `__before_compile__/1`, dove si può emettere un errore più chiaro con `raise CompileError`.
**Warning signs:** Il progetto Postgres esistente usa `Keyword.fetch!(opts, :repo)` — accettabile perché `:repo` è sempre richiesto. Per `:cluster` e `:index`, che sono opzionali per Postgres, usare `Keyword.get`.

### Pitfall 2: `:projector_module` mancante in `adapter_opts`

**What goes wrong:** `Storage.Elasticsearch.init/1` esegue `Keyword.fetch!(opts, :projector_module)` — se `child_spec/1` non inietta `:projector_module`, il GenServer crasha a runtime con un `KeyError` oscuro.
**Why it happens:** L'adapter ES è l'unico che richiede `projector_module` per chiamare `index_mapping/0`.
**How to avoid:** Il `child_spec/1` ES generato deve includere `projector_module: __MODULE__` in `adapter_opts`. Verifica con test che `child_spec([]).start` contenga `projector_module:` in `adapter_opts`.
**Warning signs:** [VERIFIED: elasticsearch.ex:95 — `Keyword.fetch!(opts, :projector_module)`]

### Pitfall 3: `function_exported?/3` check per `init/1` non sufficiente

**What goes wrong:** `function_exported?(Orkestra.Projection.Storage.Postgres, :init, 1)` restituisce `false` (correttamente) perché Postgres non implementa `init/1`. Ma se il check viene fatto a compile-time, non funziona per moduli caricati opzionalmente con `Code.ensure_loaded?`.
**Why it happens:** `Code.ensure_loaded?/1` lavora a runtime; `function_exported?/3` funziona solo se il modulo è caricato.
**How to avoid:** Il check `function_exported?` in GenServer.init deve avvenire a runtime (dentro `handle_info/2` o `init/1` della GenServer), non in una guardia a compile-time.

### Pitfall 4: `@before_compile` ordine e attributi non ancora definiti

**What goes wrong:** Se `project_es/2` viene chiamato prima che `@before_compile Orkestra.Projector` sia registrato, i Module attributes non vengono letti correttamente.
**Why it happens:** L'ordine in `__using__/1` è importante — `@before_compile` deve essere registrato prima che i macro `project_es/2` siano espansi.
**How to avoid:** In `__using__/1`, registrare prima gli attributes e il `@before_compile`, poi importare i macro. Il codice esistente già segue questo ordine [VERIFIED: projector.ex:157-171].

### Pitfall 5: `async: true` nei test DSL ES

**What goes wrong:** I test che usano Mox per HTTP calls ES non possono essere `async: true` — Mox usa ownership del processo Erlang.
**Why it happens:** `Mox.expect/4` e `Mox.stub/2` sono processo-specifici. Test paralleli interferiscono.
**How to avoid:** Usare `use ExUnit.Case, async: false` e `@moduletag :elasticsearch` per i test ES. Il test DSL compile-time puro (senza Mox) può essere `async: true` [VERIFIED: gen_server_es_test.exs:5].

### Pitfall 6: `Macro.escape/1` per handler functions

**What goes wrong:** Se `project_es/2` non usa `Macro.escape/1` sull'handler_fn prima di accumularla, il `__before_compile__/1` non può iniettarla correttamente nelle dispatch clauses generate.
**Why it happens:** Le funzioni anonime in Elixir macro devono essere escaped per poter essere injettate come AST in un `quote do ... end` successivo.
**How to avoid:** Seguire esattamente il pattern di `project/2` esistente [VERIFIED: projector.ex:135-139].

---

## Code Examples

Verified patterns from official sources:

### __dispatch_es__/3 generation in __before_compile__/1

```elixir
# Source: adattato da lib/orkestra/projector.ex:202-210 (VERIFIED)
es_dispatch_clauses =
  Enum.map(es_handlers, fn {event_module, handler_fn} ->
    type_string = inspect(event_module)

    quote do
      def __dispatch_es__(unquote(type_string), event, position) do
        unquote(handler_fn).(event, position)
      end
    end
  end)

es_dispatch_fallback =
  quote do
    def __dispatch_es__(_type, _event, _position), do: :skip
  end
```

### __handle_es__/3 — bridge function generata

```elixir
# Source: adattato da lib/orkestra/projector.ex:226-232 (VERIFIED)
quote do
  @doc false
  @spec __handle_es__(String.t(), map(), non_neg_integer()) ::
          {:ok, map(), String.t()} | :skip | {:error, term()}
  def __handle_es__(projector_name, event, position) do
    case __dispatch_es__(event.type, event, position) do
      {:ok, doc, id} -> {:ok, doc, id}
      :skip -> :skip
      {:error, reason} -> {:error, reason}
    end
  end
end
```

### Storage.Elasticsearch.write/4 handler contract

```elixir
# Source: lib/orkestra/projection/storage/elasticsearch.ex:131-138 (VERIFIED)
# L'handler in adapter_opts deve rispettare questo contratto:
case handler.(projector_name, event, position) do
  {:ok, doc, id} when is_map(doc) and is_binary(id) ->
    {:ok, %{action: :index, id: id, doc: doc}}

  :skip ->
    {:ok, %{action: :skip}}

  {:error, reason} ->
    {:error, reason}
end
```

### Storage.Elasticsearch.init/1 requirements

```elixir
# Source: lib/orkestra/projection/storage/elasticsearch.ex:92-103 (VERIFIED)
# init/1 richiede in opts:
def init(opts) do
  cluster = Keyword.fetch!(opts, :cluster)          # Snap.Cluster module
  index = Keyword.fetch!(opts, :index)              # index name string
  projector_module = Keyword.fetch!(opts, :projector_module)  # per index_mapping/0
  # ...
end
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Singolo backend Postgres | Multi-backend con `backend:` option | Phase 8 | Il DSL rimane backward-compatible; Postgres è il default implicito |
| `storage_adapter.init/1` mai chiamato | Chiamata deferita via `:init_adapter` message | Phase 8 | ES adapter ora crea index e fa engine detection a startup |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | La gestione del `backend: :elasticsearch` default è che se non specificato si usa Postgres (backward compat) | Pattern 2 | Basso — in linea con il codice attuale che hardcoda `Storage.Postgres` |
| A2 | I nomi delle opzioni ES sono `:cluster`, `:index`, `:batch_size` (coerenti con `adapter_opts` del GenServer) | Pattern 5 | Basso — puramente naming, facile da cambiare; corrisponde a `gen_server.ex:369-370` |
| A3 | `adapter_state` da `storage_adapter.init/1` viene ignorato (non salvato in GenServer state) perché GenServer ES legge già cluster/index/engine da `adapter_opts` | Pattern 4 | Medio — se fasi future (es. Phase 9 rebuild) hanno bisogno di adapter_state aggiuntivo, andrà aggiunto |
| A4 | Il child_spec ES non richiede `:repo` per il checkpoint_repo come opt separato — usa il `:repo` esistente | Architectural map | Basso — STATE.md dice "checkpoints always stay in Postgres; ES projectors still require :checkpoint_repo"; "checkpoint_repo" corrisponde al `:repo` già presente nel GenServer config |
| A5 | La validazione "non si può usare sia `project/2` che `project_es/2` sullo stesso modulo" è una scelta di design ma non un requirement esplicito — può essere ignorata silenziosamente o warning | Pattern 5 | Basso — funziona in entrambi i casi; meglio avere un warning esplicito |

---

## Open Questions

1. **Deve `__using__/1` richiedere `:cluster` e `:index` come opzioni compile-time o possono essere passate come runtime override via `child_spec/1`?**
   - What we know: Il design di `child_spec/1` già supporta runtime overrides tramite `Map.merge(config, Map.new(opts))`.
   - What's unclear: Se `:cluster` e `:index` devono essere obbligatoriamente compile-time (come `:repo`) o se possono essere solo runtime.
   - Recommendation: Per semplicità e coerenza con `:repo`, renderli opzioni compile-time in `__using__/1` con possibilità di override in `child_spec/1`. Questo è il pattern che il test `child_spec([repo: OverrideRepo])` già dimostra.

2. **`adapter_state` da `init/1` deve essere salvato in GenServer state?**
   - What we know: `Storage.Elasticsearch.init/1` restituisce `{:ok, %{cluster: cluster, index: index, engine: engine}}`. Il GenServer attualmente legge `cluster` e `index` da `adapter_opts` direttamente (Phase 7). Il campo `engine` è usato in `es_span_attrs` via `Keyword.get(adapter_opts, :engine, :elasticsearch)`.
   - What's unclear: Se il `engine` rilevato da `init/1` dovrebbe essere scritto indietro in `adapter_opts` per garantire che gli span ES usino il valore rilevato invece del default.
   - Recommendation: Dopo `init/1`, aggiornare `adapter_opts` in state con `engine:` rilevato. `new_adapter_opts = Keyword.put(state.adapter_opts, :engine, engine)` e `{:noreply, %{state | adapter_opts: new_adapter_opts}}`.

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Elixir | Runtime | ✓ | 1.18+ | — |
| Snap ~> 0.16 | ES adapter | ✓ | ~0.16 (optional dep) | Guard `Code.ensure_loaded?(Snap.Cluster)` |
| Ecto ~> 3.12 | Checkpoint storage | ✓ | ~3.12 (optional dep) | Guard `Code.ensure_loaded?(Ecto.Multi)` |
| PostgreSQL | Test checkpoint | — | N/A in env | Tag `:postgres` su test che richiedono DB |
| ExUnit | Test framework | ✓ | built-in | — |

[VERIFIED: mix.exs — snap e ecto già presenti come optional deps]

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in Elixir) |
| Config file | `test/test_helper.exs` |
| Quick run command | `mix test test/orkestra/projector/projector_dsl_es_test.exs` |
| Full suite command | `mix test --include elasticsearch` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| ADPT-05 | `project_es/2` accumula handlers; `__dispatch_es__/3` routes per tipo; `__handle_es__/3` bridge | unit (compile-time DSL) | `mix test test/orkestra/projector/projector_dsl_es_test.exs` | ❌ Wave 0 |
| ADPT-05 | `child_spec/1` con `backend: :elasticsearch` inietta `storage_adapter: Storage.Elasticsearch` | unit (compile-time DSL) | `mix test test/orkestra/projector/projector_dsl_es_test.exs` | ❌ Wave 0 |
| ADPT-05 | `child_spec/1` con `backend: :elasticsearch` inietta `projector_module:` in `adapter_opts` | unit (compile-time DSL) | `mix test test/orkestra/projector/projector_dsl_es_test.exs` | ❌ Wave 0 |
| ADPT-05 | Projector Postgres esistente compila e child_spec invariato (backward compat) | regression | `mix test test/orkestra/projector/projector_dsl_test.exs` | ✅ |
| ADPT-07 | GenServer chiama `storage_adapter.init/1` prima di `load_checkpoint` per ES adapter | integration | `mix test test/orkestra/projector/projector_dsl_es_test.exs` (con Mox) | ❌ Wave 0 |
| ADPT-07 | ES-first Postgres-second checkpoint ordering già coperto | regression | `mix test test/orkestra/projector/gen_server_es_test.exs --include elasticsearch` | ✅ |

### Sampling Rate

- **Per task commit:** `mix compile --warnings-as-errors && mix test test/orkestra/projector/projector_dsl_test.exs`
- **Per wave merge:** `mix test` (esclusi i tag DB-dependent)
- **Phase gate:** `mix test && mix test --include elasticsearch` con PostgreSQL disponibile

### Wave 0 Gaps

- [ ] `test/orkestra/projector/projector_dsl_es_test.exs` — copre ADPT-05 (DSL compile-time) e ADPT-07 (init wiring)
- [ ] Wrappare nel guard `if Code.ensure_loaded?(Snap.Cluster)` — pattern da gen_server_es_test.exs
- [ ] `@moduletag :elasticsearch` per i test che richiedono Mox HTTP

---

## Security Domain

`security_enforcement: true` in `.planning/config.json`.

### Applicable ASVS Categories

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | No | ES auth è in Snap.Cluster config (Phase 6) — nessuna nuova auth in questo DSL |
| V3 Session Management | No | Stateless library |
| V4 Access Control | No | Nessun endpoint esposto |
| V5 Input Validation | Parziale | `index_mapping/0` callback: l'adapter già inietta `dynamic: "strict"` via `Map.put` [VERIFIED: elasticsearch.ex:240] |
| V6 Cryptography | No | Nessuna criptografia — credential flow invariato da Phase 6 |

### Known Threat Patterns for Elixir Macro DSL

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Macro injection (unsafe user-provided AST) | Tampering | `Macro.escape/1` su tutte le handler functions prima di accumularle — già pattern in `project/2` [VERIFIED: projector.ex:135] |
| `index_mapping/0` con `dynamic: true` | Tampering | `Storage.Elasticsearch.ensure_index` già sovrascrive con `dynamic: "strict"` via `Map.put` [VERIFIED: elasticsearch.ex:240] |
| Credential leak in Logger | Information Disclosure | Logger calls in GenServer usano solo `projector_name` e `position` — `adapter_opts` (con `cluster`) mai loggato [VERIFIED: gen_server.ex:T-07-03] |

---

## Sources

### Primary (HIGH confidence)

- `lib/orkestra/projector.ex` — codice sorgente verificato direttamente; tutte le pattern `project/2`, `__dispatch__/3`, `__handle__/3`, `child_spec/1` leggibili
- `lib/orkestra/projector/gen_server.ex` (737 linee) — codice sorgente verificato; confermato che `storage_adapter.init/1` NON è chiamato
- `lib/orkestra/projection/storage/elasticsearch.ex` — `init/1` richiede `projector_module` confermato a riga 95
- `test/orkestra/projector/projector_dsl_test.exs` — test pattern esistenti per DSL Postgres, usati come riferimento
- `test/orkestra/projector/gen_server_es_test.exs` — test pattern ES con Mox, `async: false`, `@moduletag :elasticsearch`
- `.planning/phases/08-projector-macro-dsl-for-elasticsearch/08-CONTEXT.md` — decisioni bloccate

### Secondary (MEDIUM confidence)

- `.planning/phases/06-es-storage-adapter-foundation/06-02-SUMMARY.md` — decisioni prese in Phase 6 (pattern Mox, ESHTTPAdapter)
- `.planning/phases/07-genserver-es-commit-path-and-batch-indexing/07-01-SUMMARY.md` — ES commit path implementato

### Tertiary (LOW confidence)

Nessuna — tutte le claim sono VERIFIED o ASSUMED esplicitamente.

---

## Metadata

**Confidence breakdown:**

- Standard Stack: HIGH — tutte le dipendenze già presenti e verificate in mix.exs
- Architecture: HIGH — pattern esistenti in codebase chiaramente identificati; gap `storage_adapter.init/1` verificato con grep
- Pitfalls: HIGH — basati su codice reale verificato e pattern stabiliti nelle fasi precedenti
- Assumptions Log: 5 items, tutti basso-medio rischio

**Research date:** 2026-06-25
**Valid until:** 2026-07-25 (codebase stabile per questa milestone)
