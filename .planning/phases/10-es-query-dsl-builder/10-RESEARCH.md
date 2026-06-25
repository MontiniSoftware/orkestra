# Phase 10: ES Query DSL Builder - Research

**Researched:** 2026-06-25
**Domain:** Elixir DSL design, Elasticsearch Query Language, Snap library, codegen
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
Nessuna decisione bloccata — fase infrastrutturale pura.

### Claude's Discretion
Tutte le scelte implementative sono a discrezione di Claude. Linee guida chiave:

- **Pipe-based DSL:** `Query.new() |> Query.must(match: %{"field" => "value"}) |> Query.filter(range: %{"date" => %{"gte" => "2024-01-01"}}) |> Query.build()` → produce la mappa JSON della query ES
- **Composabile:** ogni funzione restituisce la struct della query per il piping
- **Output:** `build/1` restituisce la mappa finale `%{"query" => %{"bool" => ...}}` pronta per `Snap.Search.search/4`
- **Aggregazioni:** supporto a `aggs/2` per aggiungere clausole di aggregazione
- **Modulo Queries generato:** template `Orkestra.Projection.ES.Queries` simile al `gen_queries` Postgres — helper list/get_by/search che avvolgono il DSL

### Deferred Ideas (OUT OF SCOPE)
- Search/count/get_by_id helpers (QHLP-01) — rinviati al futuro
</user_constraints>

---

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| QDSL-01 | Elixir query DSL module composes ES queries (bool, match, filter, range, aggs) con pipe syntax | Patterns Elixir struct + pipe, mapping query ES bool/must/filter/should; vedi sezione Architecture Patterns |
| QDSL-02 | Optional generated ES.Queries module scaffolded per projection (like gen_queries for Postgres) | Pattern `gen_queries` già esistente in `OrkestraMcp.Generator`; vedi sezione Code Examples |
</phase_requirements>

---

## Summary

Phase 10 introduce `Orkestra.Projection.ES.Query` — un modulo DSL pipe-based in puro Elixir per comporre query Elasticsearch — e `Orkestra.Projection.ES.Queries` come template generabile per projector ES (analogo al `gen_queries` Postgres già esistente in `OrkestraMcp.Generator`).

Il DSL non ha dipendenze runtime oltre a quelle già presenti: non chiama direttamente la rete, produce solo una mappa Elixir che `Snap.Search.search/4` accetta come terzo argomento. L'unico consumer HTTP è il chiamante. Questo rende il modulo testabile in isolamento totale con semplici asserzioni su mappe Elixir.

Il pattern `gen_queries` Postgres in `OrkestraMcp.Generator.gen_queries/2` è il riferimento diretto per QDSL-02: genera codice Elixir come stringa, lo scrive via `OrkestraMcp.Generator.write!/3`. Il corrispettivo ES seguirà la stessa struttura (funzione `gen_es_queries/2` in `OrkestraMcp.Generator`, tool `GenEsQueries` in `orkestra_mcp/lib/orkestra_mcp/tools/`).

**Raccomandazione principale:** Implementare `Orkestra.Projection.ES.Query` come modulo con struct interna e funzioni pubbliche pure; aggiungere `gen_es_queries/2` in `OrkestraMcp.Generator`; aggiungere il tool MCP `GenEsQueries` in `orkestra_mcp`.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Composizione query ES | Libreria core (`lib/`) | — | Modulo puro Elixir, zero I/O, nessuna dipendenza Snap a runtime |
| Esecuzione ricerca ES | Caller (applicazione host) | — | Il DSL produce la mappa; il caller chiama `Snap.Search.search/4` |
| Generazione codice `ES.Queries` | MCP tool (`orkestra_mcp/`) | `OrkestraMcp.Generator` | Segue pattern codegen esistente |
| Test del DSL | ExUnit puro | — | Nessun mock HTTP necessario — output è mappa Elixir |

---

## Standard Stack

### Core
| Library | Version | Purpose | Why Standard |
|---------|---------|---------|--------------|
| Elixir built-ins | 1.18.2 | Struct, Map, Kernel.pipe | Il DSL è puro Elixir, zero deps aggiuntive |
| Snap | ~> 0.16 (già in `mix.exs`) | Consumer finale via `Snap.Search.search/4` | Già dipendenza opzionale del progetto |
| ExUnit | OTP 27 built-in | Test del DSL | Zero config aggiuntiva |

[VERIFIED: codebase grep — `mix.exs` line `{:snap, "~> 0.16", optional: true}`]
[VERIFIED: codebase grep — `Snap.Search.search/4` in `deps/snap/lib/snap/search.ex`]

### Supporting
| Library | Version | Purpose | When to Use |
|---------|---------|---------|-------------|
| Jason | ~> 1.2 (già in `mix.exs`) | JSON nei test (confronto payload) | Solo nei test di integrazione; il DSL opera su mappe Elixir |

[VERIFIED: codebase grep — `mix.exs` line `{:jason, "~> 1.2"}`]

### Alternatives Considered
| Instead of | Could Use | Tradeoff |
|------------|-----------|----------|
| Struct interna `%Query{}` | Map nuda `%{}` | Struct garantisce pattern match e `@type` chiari; Map è più semplice ma perde leggibilità nel piping |
| Funzioni pubbliche pipe-based | Macro DSL | Funzioni pure sono più semplici da testare e documentare; macro non aggiungono valore qui |

**Installation:** Nessuna nuova dipendenza da installare. Snap già presente.

---

## Architecture Patterns

### System Architecture Diagram

```
Caller (host app)
      │
      │  Query.new()
      │  |> Query.must(...)
      │  |> Query.filter(...)
      │  |> Query.aggs(...)
      │  |> Query.build()
      │         │
      │         ▼
      │   %{"query" => %{"bool" => ...}, "aggs" => ...}
      │         │
      ▼         ▼
Snap.Search.search(cluster, index, query_map)
      │
      ▼
%Snap.SearchResponse{hits: %Snap.Hits{...}, aggregations: map()}
```

```
MCP Tool (gen_es_queries)
      │
      ▼
OrkestraMcp.Generator.gen_es_queries(module_name, projector_module)
      │
      ▼
{source_code, file_path}  →  OrkestraMcp.Generator.write!(source, dir, path)
```

### Recommended Project Structure
```
lib/orkestra/projection/es/
├── query.ex            # QDSL-01: DSL pipe-based per query ES
└── queries.ex          # Opzionale: modulo base (template usato da gen_es_queries)

orkestra_mcp/lib/orkestra_mcp/tools/
└── gen_es_queries.ex   # QDSL-02: MCP tool per scaffolding ES.Queries

# gen_es_queries aggiunto in:
orkestra_mcp/lib/orkestra_mcp/generator.ex

# Test:
test/orkestra/projection/es/
├── query_test.exs      # Unit test del DSL (no mock HTTP)
└── queries_test.exs    # Test del modulo Queries generato (opzionale)
```

### Pattern 1: Struct Accumulatrice con Funzioni Pure

Il DSL accumula clausole `must`, `should`, `filter`, `must_not` in una struct interna.
`build/1` serializza la struct nella mappa ES finale.

```elixir
# Source: pattern codebase (lib/orkestra/projection/storage/elasticsearch.ex — stesso stile)
defmodule Orkestra.Projection.ES.Query do
  @moduledoc """
  Pipe-based DSL for composing Elasticsearch bool queries.

  Produces a query map compatible with `Snap.Search.search/4`.

  ## Example

      import Orkestra.Projection.ES.Query

      query =
        new()
        |> must(match: %{"status" => "placed"})
        |> filter(range: %{"created_at" => %{"gte" => "2024-01-01"}})
        |> aggs("by_status", terms: %{"field" => "status"})
        |> build()

      {:ok, results} = Snap.Search.search(MyApp.ESCluster, "orders", query)
  """

  @type clause :: {atom(), map()}
  @type t :: %__MODULE__{
          must: [map()],
          should: [map()],
          filter: [map()],
          must_not: [map()],
          aggs: map(),
          size: non_neg_integer() | nil,
          from: non_neg_integer() | nil,
          sort: [map()]
        }

  defstruct must: [], should: [], filter: [], must_not: [], aggs: %{}, size: nil, from: nil, sort: []

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec must(t(), clause()) :: t()
  def must(%__MODULE__{} = q, [{type, value}]),
    do: %{q | must: q.must ++ [%{Atom.to_string(type) => value}]}

  @spec should(t(), clause()) :: t()
  def should(%__MODULE__{} = q, [{type, value}]),
    do: %{q | should: q.should ++ [%{Atom.to_string(type) => value}]}

  @spec filter(t(), clause()) :: t()
  def filter(%__MODULE__{} = q, [{type, value}]),
    do: %{q | filter: q.filter ++ [%{Atom.to_string(type) => value}]}

  @spec must_not(t(), clause()) :: t()
  def must_not(%__MODULE__{} = q, [{type, value}]),
    do: %{q | must_not: q.must_not ++ [%{Atom.to_string(type) => value}]}

  @spec aggs(t(), String.t(), clause()) :: t()
  def aggs(%__MODULE__{} = q, name, [{type, value}]),
    do: %{q | aggs: Map.put(q.aggs, name, %{Atom.to_string(type) => value})}

  @spec size(t(), non_neg_integer()) :: t()
  def size(%__MODULE__{} = q, n), do: %{q | size: n}

  @spec from(t(), non_neg_integer()) :: t()
  def from(%__MODULE__{} = q, n), do: %{q | from: n}

  @spec sort(t(), map()) :: t()
  def sort(%__MODULE__{} = q, clause), do: %{q | sort: q.sort ++ [clause]}

  @spec build(t()) :: map()
  def build(%__MODULE__{} = q) do
    bool =
      %{}
      |> put_if_nonempty("must", q.must)
      |> put_if_nonempty("should", q.should)
      |> put_if_nonempty("filter", q.filter)
      |> put_if_nonempty("must_not", q.must_not)

    result = %{"query" => %{"bool" => bool}}
    result = if map_size(q.aggs) > 0, do: Map.put(result, "aggs", q.aggs), else: result
    result = if q.size, do: Map.put(result, "size", q.size), else: result
    result = if q.from, do: Map.put(result, "from", q.from), else: result
    result = if q.sort != [], do: Map.put(result, "sort", q.sort), else: result
    result
  end

  defp put_if_nonempty(map, _key, []), do: map
  defp put_if_nonempty(map, key, val), do: Map.put(map, key, val)
end
```

[ASSUMED] — Pattern derivato dal design ES bool query standard e dallo stile codice esistente nel progetto. Non verificato contro documentazione ES ufficiale in questa sessione (ma la struttura `bool: {must, should, filter, must_not}` è ES Query DSL fondamentale).

### Pattern 2: Modulo ES.Queries Generato (QDSL-02)

Analoga a `gen_queries/2` per Postgres, la funzione `gen_es_queries/2` produce un modulo
con helper `search/3`, `list/3`, `get_by_id/3` che incapsulano il DSL ES.

```elixir
# Source: pattern derivato da OrkestraMcp.Generator.gen_queries/2 (codebase verificato)
def gen_es_queries(module_name, projector_module) do
  source = """
  defmodule #{module_name} do
    @moduledoc \"\"\"
    Query helpers for `#{projector_module}`.

    Provides composable search operations wrapping `Orkestra.Projection.ES.Query`
    so callers do not need to build bool queries manually.
    \"\"\"

    alias Orkestra.Projection.ES.Query

    @doc \"\"\"
    Runs a bool query against the projection index.

    `build_fn` is a 1-arity function receiving `Query.new()` and returning
    the result of `Query.build/1`.

    ## Example

        search(cluster, "orders", fn q ->
          q
          |> Query.must(match: %{"status" => "placed"})
          |> Query.build()
        end)
    \"\"\"
    def search(cluster, index, build_fn) do
      query = build_fn.(Query.new())
      Snap.Search.search(cluster, index, query)
    end

    @doc \"\"\"
    Returns a paged list of all documents in the index.

    Options:
      * `:size` - number of documents per page (default: 20)
      * `:from` - offset (default: 0)
    \"\"\"
    def list(cluster, index, opts \\\\ []) do
      size = Keyword.get(opts, :size, 20)
      from = Keyword.get(opts, :from, 0)
      query = Query.new() |> Query.size(size) |> Query.from(from) |> Query.build()
      Snap.Search.search(cluster, index, query)
    end

    @doc \"\"\"
    Fetches a document by its `_id`.
    \"\"\"
    def get_by_id(cluster, index, id) do
      Snap.Document.get(cluster, index, id)
    end
  end
  """

  {String.trim(source), Naming.module_to_file_path(module_name)}
end
```

[VERIFIED: `OrkestraMcp.Generator.gen_queries/2` in `orkestra_mcp/lib/orkestra_mcp/generator.ex` — struttura identica seguita]
[VERIFIED: `Snap.Search.search/4` firma in `deps/snap/lib/snap/search.ex`]
[ASSUMED] — `Snap.Document.get/3` non verificato nella versione Snap 0.16 — potrebbe richiedere verifica prima di includerlo nel template generato.

### Pattern 3: Tool MCP GenEsQueries

```elixir
# Source: pattern derivato da OrkestraMcp.Tools.GenQueries (codebase verificato)
defmodule OrkestraMcp.Tools.GenEsQueries do
  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full ES Queries module name, e.g. MyApp.Orders.ESQueries"
    )

    field(:projector_module, :string,
      required: true,
      description: "The ES projector module, e.g. MyApp.Orders.OrderESProjector"
    )
  end

  @impl true
  def execute(%{module_name: module_name, projector_module: projector_module}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    {source, file_path} = OrkestraMcp.Generator.gen_es_queries(module_name, projector_module)
    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)
    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
```

[VERIFIED: `OrkestraMcp.Tools.GenQueries` in `orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex`]

### Anti-Patterns to Avoid

- **Chiamate HTTP dentro il DSL:** `Orkestra.Projection.ES.Query` non deve mai chiamare `Snap.*` — è puro, zero I/O. Il caller esegue la ricerca.
- **Atom dinamici non-esistenti:** usare `Atom.to_string/1` sui tipi di clause anziché assumere che le chiavi ES siano atom Elixir noti a compile time.
- **Bool query vuota:** `build/1` con una `%Query{}` vuota produrrà `%{"query" => %{"bool" => %{}}}` — ES accetta questo come `match_all` implicito, comportamento corretto ma da documentare.
- **Naming collision nel MCP server:** il nuovo tool `gen_es_queries` deve essere registrato in `OrkestraMcp.Server` come gli altri tool esistenti.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Esecuzione HTTP verso ES | Client HTTP custom | `Snap.Search.search/4` | Già integrato, gestisce namespace, auth, parsing risposta |
| Serializzazione JSON | Encoder custom | Jason (già dep) | Snap usa già Jason internamente |
| Parsing hits | Logica custom | `Snap.SearchResponse`, `Snap.Hit` | Struct tipizzate con `Enumerable` già implementato |
| Naming convenzioni moduli MCP | Logica custom | `OrkestraMcp.Naming.module_to_file_path/1` | Già esistente, usato da tutti i generator |

**Key insight:** Il DSL produce solo mappe Elixir standard. Tutta la complessità di rete e parsing è già gestita da Snap.

---

## Runtime State Inventory

> Fase greenfield (nuovo modulo puro + codegen). Nessuna rinomina o migrazione.

Non applicabile — fase di nuova implementazione senza stato da migrare.

---

## Common Pitfalls

### Pitfall 1: `match_all` vs bool query vuota
**What goes wrong:** Un `Query.new() |> Query.build()` produce `%{"query" => %{"bool" => %{}}}`. ES interpreta un bool vuoto come `match_all` — comportamento corretto ma non ovvio.
**Why it happens:** ES bool query spec: clausole vuote non sono un errore.
**How to avoid:** Documentare il comportamento nel `@moduledoc`. Aggiungere `Query.match_all/1` come alias conveniente.
**Warning signs:** Test che si aspettano `%{"match_all" => %{}}` e trovano invece `%{"bool" => %{}}` — entrambi equivalenti in ES ma la forma è diversa.

### Pitfall 2: Clausole duplicate nel piping
**What goes wrong:** `must(q, match: ...)` chiamato due volte aggiunge due clause `must`. Non è un errore ES ma può sorprendere.
**Why it happens:** Design accumulativo — ogni chiamata aggiunge, non sostituisce.
**How to avoid:** Documentare chiaramente il comportamento additivo. Non introdurre semantica "replace".
**Warning signs:** Query con `must` duplicati nella stessa field — ES restituisce risultati ma il ranking può variare.

### Pitfall 3: Atom clause sconosciuti
**What goes wrong:** `must(q, fuzzy: %{...})` funziona (Atom.to_string produce `"fuzzy"`), ma un typo come `must(q, mach: ...)` genera una chiave ES non valida che ES rifiuta al runtime.
**Why it happens:** Il DSL accetta qualsiasi keyword list — non valida i tipi di clause.
**How to avoid:** Documentare i tipi supportati. Non aggiungere validazione compile-time (over-engineering) — ES darà un errore chiaro al runtime.
**Warning signs:** ES risponde con `400 parsing_exception` — verificare il nome della clause.

### Pitfall 4: Tool MCP non registrato nel server
**What goes wrong:** `GenEsQueries` definito ma non aggiunto a `OrkestraMcp.Server` — il tool non appare nell'elenco MCP.
**Why it happens:** `OrkestraMcp.Server` ha una lista esplicita di tool.
**How to avoid:** Verificare `orkestra_mcp/lib/orkestra_mcp/server.ex` e aggiungere `OrkestraMcp.Tools.GenEsQueries` alla lista.
**Warning signs:** `mix run` non elenca il tool nella directory MCP.

---

## Code Examples

Verified patterns from official sources:

### Query Match
```elixir
# Source: pattern derivato da Snap.Search.search/4 in deps/snap/lib/snap/search.ex
alias Orkestra.Projection.ES.Query

query =
  Query.new()
  |> Query.must(match: %{"status" => "placed"})
  |> Query.build()

# query == %{"query" => %{"bool" => %{"must" => [%{"match" => %{"status" => "placed"}}]}}}

{:ok, %Snap.SearchResponse{hits: hits}} = Snap.Search.search(cluster, "orders", query)
Enum.each(hits, fn hit -> IO.inspect(hit.source) end)
```

### Query Bool Composta con Filtro e Range
```elixir
alias Orkestra.Projection.ES.Query

query =
  Query.new()
  |> Query.must(match: %{"status" => "placed"})
  |> Query.filter(range: %{"created_at" => %{"gte" => "2024-01-01", "lte" => "2024-12-31"}})
  |> Query.must_not(term: %{"cancelled" => true})
  |> Query.size(50)
  |> Query.build()

# Output:
# %{
#   "query" => %{
#     "bool" => %{
#       "must"     => [%{"match" => %{"status" => "placed"}}],
#       "filter"   => [%{"range" => %{"created_at" => %{"gte" => ..., "lte" => ...}}}],
#       "must_not" => [%{"term" => %{"cancelled" => true}}]
#     }
#   },
#   "size" => 50
# }
```

### Query con Aggregazioni
```elixir
alias Orkestra.Projection.ES.Query

query =
  Query.new()
  |> Query.filter(term: %{"merchant_id" => "m-123"})
  |> Query.aggs("by_status", terms: %{"field" => "status", "size" => 10})
  |> Query.size(0)  # solo aggregazioni, no hits
  |> Query.build()

{:ok, %Snap.SearchResponse{aggregations: aggs}} = Snap.Search.search(cluster, "orders", query)
buckets = get_in(aggs, ["by_status", "buckets"])
```

### Uso del Modulo Queries Generato
```elixir
# Dopo gen_es_queries("MyApp.Orders.ESQueries", "MyApp.OrderESProjector"):
{:ok, response} = MyApp.Orders.ESQueries.search(MyApp.ESCluster, "orders", fn q ->
  q
  |> Query.must(match: %{"status" => "placed"})
  |> Query.build()
end)

{:ok, response} = MyApp.Orders.ESQueries.list(MyApp.ESCluster, "orders", size: 10)
```

### Test del DSL (pattern progetto)
```elixir
# Source: pattern test esistenti in test/orkestra/projection/storage/elasticsearch_test.exs
# (nessun Mox/HTTP necessario — output è mappa Elixir pura)
defmodule Orkestra.Projection.ES.QueryTest do
  use ExUnit.Case, async: true

  alias Orkestra.Projection.ES.Query

  test "must clause aggiunge a bool.must" do
    result = Query.new() |> Query.must(match: %{"field" => "val"}) |> Query.build()
    assert result == %{"query" => %{"bool" => %{"must" => [%{"match" => %{"field" => "val"}}]}}}
  end
end
```

---

## Environment Availability

| Dependency | Required By | Available | Version | Fallback |
|------------|------------|-----------|---------|----------|
| Elixir | Core | si | 1.18.2 | — |
| Erlang/OTP | Runtime | si | 27 | — |
| Snap ~> 0.16 | Consumer del DSL (test integrazione) | si (in deps/) | 0.16.x | Test unitari non richiedono Snap |
| ExUnit | Test DSL | si (built-in) | 1.18.2 | — |

[VERIFIED: `elixir --version` e `mix --version` — Elixir 1.18.2 / OTP 27]
[VERIFIED: `deps/snap/` presente in codebase]

**Nessuna dipendenza mancante.** Tutto il necessario è già disponibile.

---

## Validation Architecture

### Test Framework
| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in Elixir 1.18) |
| Config file | `test/test_helper.exs` (esistente) |
| Quick run command | `mix test test/orkestra/projection/es/` |
| Full suite command | `mix test` |

### Phase Requirements → Test Map
| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| QDSL-01 | `Query.new/0` restituisce struct vuota | unit | `mix test test/orkestra/projection/es/query_test.exs -x` | ❌ Wave 0 |
| QDSL-01 | `must/2` aggiunge clausola a bool.must | unit | `mix test test/orkestra/projection/es/query_test.exs -x` | ❌ Wave 0 |
| QDSL-01 | `should/2` aggiunge clausola a bool.should | unit | `mix test test/orkestra/projection/es/query_test.exs -x` | ❌ Wave 0 |
| QDSL-01 | `filter/2` aggiunge clausola a bool.filter | unit | `mix test test/orkestra/projection/es/query_test.exs -x` | ❌ Wave 0 |
| QDSL-01 | `must_not/2` aggiunge clausola a bool.must_not | unit | `mix test test/orkestra/projection/es/query_test.exs -x` | ❌ Wave 0 |
| QDSL-01 | `aggs/3` aggiunge aggregazione alla mappa aggs | unit | `mix test test/orkestra/projection/es/query_test.exs -x` | ❌ Wave 0 |
| QDSL-01 | `size/2` e `from/2` aggiungono parametri pagination | unit | `mix test test/orkestra/projection/es/query_test.exs -x` | ❌ Wave 0 |
| QDSL-01 | `build/1` omette chiavi bool vuote | unit | `mix test test/orkestra/projection/es/query_test.exs -x` | ❌ Wave 0 |
| QDSL-01 | pipe chain composto produce output corretto | unit | `mix test test/orkestra/projection/es/query_test.exs -x` | ❌ Wave 0 |
| QDSL-02 | `gen_es_queries/2` produce codice Elixir valido | unit | `mix test test/orkestra_mcp/ -x` | ❌ Wave 0 |
| QDSL-02 | tool MCP `gen_es_queries` scrive file in project_dir | unit | `mix test test/orkestra_mcp/ -x` | ❌ Wave 0 |

### Sampling Rate
- **Per task commit:** `mix test test/orkestra/projection/es/query_test.exs`
- **Per wave merge:** `mix test`
- **Phase gate:** Full suite green prima di `/gsd-verify-work`

### Wave 0 Gaps
- [ ] `test/orkestra/projection/es/query_test.exs` — covers QDSL-01
- [ ] `test/orkestra_mcp/tools/gen_es_queries_test.exs` — covers QDSL-02

---

## Security Domain

### Applicable ASVS Categories (Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — modulo puro, nessun endpoint |
| V3 Session Management | no | — |
| V4 Access Control | no | — |
| V5 Input Validation | parziale | Clausole sono keyword list Elixir: tipi verificati dal type system, valori inoltrati as-is a ES |
| V6 Cryptography | no | — |

### Known Threat Patterns

| Pattern | STRIDE | Standard Mitigation |
|---------|--------|---------------------|
| Injection ES query (valori non sanitizzati da input utente) | Tampering | Il DSL accetta mappe Elixir opache — la sanitizzazione è responsabilità del caller. Documentare chiaramente che i valori nei field-value dovranno essere validati prima di passarli al DSL se provengono da input utente. Non è necessario sanitizzare dentro il DSL stesso (sarebbe over-engineering). |

**Nota:** Il DSL opera su dati interni all'applicazione (non su input utente diretto). Il rischio di injection è sul caller, non sul DSL. Documentare nel `@moduledoc` che i valori delle clausole non vengono sanificati dal DSL.

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| Query ES come stringhe JSON hard-coded | Mappa Elixir composta programmaticamente | Sempre stato così | Maggiore composabilità e testabilità |
| Query ES costruite a mano nei projector | DSL pipe-based riusabile | Phase 10 (questa fase) | Riduzione boilerplate |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | `Snap.Document.get/3` esiste in Snap ~> 0.16 | Code Examples (gen_es_queries template) | Il helper `get_by_id` nel template generato chiama una funzione non esistente — rimuovere o sostituire con `Snap.get/4` |
| A2 | La struttura bool ES (`must`, `should`, `filter`, `must_not`) è identica tra ES 8.x e OpenSearch 2.x | Architecture Patterns | Se diverge, il DSL potrebbe produrre query incompatibili con uno dei due engine — aggiungere engine-specific overrides |
| A3 | Un bool ES vuoto (`%{"bool" => %{}}`) è accettato da ES/OpenSearch come equivalente di `match_all` | Common Pitfalls | ES potrebbe rifiutarlo con `parsing_exception` — aggiungere `match_all` esplicito quando tutte le liste sono vuote |

---

## Open Questions

1. **`Snap.Document.get/3` — firma esatta in Snap 0.16**
   - What we know: `Snap.Document` esiste in `deps/snap/lib/snap/document.ex`
   - What's unclear: firma esatta della funzione `get` — argomenti e valori di ritorno
   - Recommendation: verificare `deps/snap/lib/snap/document.ex` durante planning prima di includere `get_by_id` nel template `gen_es_queries`

2. **Dove registrare il tool MCP `GenEsQueries` in `OrkestraMcp.Server`**
   - What we know: `orkestra_mcp/lib/orkestra_mcp/server.ex` ha lista esplicita di tool
   - What's unclear: esatta sintassi/posizione di registrazione (non letta in questa sessione)
   - Recommendation: leggere `server.ex` durante planning per aggiungere il tool correttamente

---

## Sources

### Primary (HIGH confidence)
- Codebase: `deps/snap/lib/snap/search.ex` — firma `Snap.Search.search/4` verificata
- Codebase: `deps/snap/lib/snap/responses/search_response.ex` — struttura `SearchResponse`
- Codebase: `deps/snap/lib/snap/responses/hit.ex` — struttura `Hit`
- Codebase: `orkestra_mcp/lib/orkestra_mcp/generator.ex` — pattern `gen_queries/2` verificato
- Codebase: `orkestra_mcp/lib/orkestra_mcp/tools/gen_queries.ex` — pattern tool MCP verificato
- Codebase: `lib/orkestra/projection/storage/elasticsearch.ex` — stile codice e convenzioni

### Secondary (MEDIUM confidence)
- Codebase: pattern test da `test/orkestra/projection/storage/elasticsearch_test.exs`
- Codebase: `test/test_helper.exs` — configurazione ExUnit e tag `@moduletag :elasticsearch`

### Tertiary (LOW confidence)
- [ASSUMED] Struttura bool ES (must/should/filter/must_not) basata su conoscenza di training — non verificata con docs ES ufficiali in questa sessione

---

## Metadata

**Confidence breakdown:**
- Standard Stack: HIGH — librerie verificate in codebase (mix.exs, deps/)
- Architecture: HIGH — pattern derivati direttamente da codice esistente nel progetto
- Code Examples: HIGH per struttura DSL, MEDIUM per `gen_es_queries` (A1 aperto su `Snap.Document.get`)
- Pitfalls: MEDIUM — basati su esperienza ES standard e analisi codice progetto
- Security: HIGH — ASVS Level 1, nessun endpoint esposto, solo DSL puro

**Research date:** 2026-06-25
**Valid until:** 2026-07-25 (API Snap stabile, ES Query DSL stabile)
