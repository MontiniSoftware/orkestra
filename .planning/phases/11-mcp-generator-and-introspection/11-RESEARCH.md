# Phase 11: MCP Generator and Introspection - Research

**Researched:** 2026-06-25
**Domain:** OrkestraMcp code generation tools e risorse di introspezione (Elixir MCP server)
**Confidence:** HIGH

---

<user_constraints>
## User Constraints (from CONTEXT.md)

### Locked Decisions
Nessuna decisione bloccata dall'utente — fase infrastrutturale.

### Claude's Discretion
Tutte le scelte implementative sono a discrezione di Claude. Linee guida chiave:

- **Tool `gen_es_projection`:** Seguire il pattern esistente `gen_projection` in orkestra_mcp — stessa struttura, adattata per le opzioni del backend ES (cluster, index, events)
- **Risorsa `domain_map`:** Aggiornare per rilevare e mostrare i projector ES accanto a quelli Postgres
- **Risorsa `ListProjections`:** Aggiornare per includere le proiezioni ES con tipo backend, cluster e info sull'indice
- **Pattern di rilevamento:** Usare `__projection_config__/0` che ora include i campi `:backend`, `:cluster`, `:index` (aggiunti nella Fase 8)

### Deferred Ideas (OUT OF SCOPE)
Nessuna.
</user_constraints>

<phase_requirements>
## Phase Requirements

| ID | Description | Research Support |
|----|-------------|------------------|
| MCP-01 | `gen_es_projection` MCP tool scaffolds new ES projection modules | Il pattern `gen_projection` / `GenProjection` è completamente analizzato; il DSL ES projector (`use Orkestra.Projector, backend: :elasticsearch`) è documentato in dettaglio in `projector.ex` |
| MCP-02 | ES projections surfaced in `domain_map` and `ListProjections` introspection resources | Il meccanismo `detect_projectors/2` in `introspection.ex` è analizzato; il campo `backend:` nei risultati è assente nell'attuale implementazione e deve essere aggiunto |
</phase_requirements>

---

## Summary

Questa fase completa il supporto MCP per le proiezioni Elasticsearch aggiungendo: (1) un nuovo tool `gen_es_projection` che genera il modulo projector ES con `use Orkestra.Projector, backend: :elasticsearch`, handlers `project_es/2` e la callback `index_mapping/0`; (2) aggiornamenti a `OrkestraMcp.Introspection` per rilevare i projector ES nei file sorgente (tramite regex su `backend: :elasticsearch`), arricchendo la struttura `projectors` con i campi `backend`, `cluster`, `index`; (3) aggiornamento della risorsa `DomainMap` per includere il tipo backend nel testo di output; (4) aggiornamento di `ListProjections` che già legge da `Introspection.discover/1`.

Il lavoro è puramente additivo: nessuna funzione pubblica esistente viene rimossa; i Postgres projector rimangono invariati. La suite di test attuale (44 test, 0 failure) costituisce la baseline; questa fase aggiunge test unitari per il generatore e test di introspezione per i projector ES.

**Primary recommendation:** Aggiungere `gen_es_projection` come nuovo modulo tool, aggiungere `gen_es_projection/4` (o simile) in `Generator`, estendere `detect_projectors/2` in `Introspection` per gestire entrambi i backend, aggiornare `build_domain_map/1` per annotare il backend, aggiungere una fixture ES projector nei test.

---

## Architectural Responsibility Map

| Capability | Primary Tier | Secondary Tier | Rationale |
|------------|-------------|----------------|-----------|
| Scaffold ES projector module | MCP Tool (`OrkestraMcp.Tools.GenEsProjection`) | Generator (`OrkestraMcp.Generator`) | Il tool gestisce input/output MCP; il Generator produce il sorgente Elixir |
| Rilevamento ES projector da file sorgente | Introspection (`detect_projectors/2` esteso) | — | Già responsabile della scansione di tutti i tipi di projector |
| Render domain map con annotazioni backend | Introspection (`build_domain_map/1`) | Resource (`DomainMap`) | La logica di aggregazione vive in Introspection; la Resource è solo un adapter MCP |
| Esposizione lista proiezioni ES | Resource (`ListProjections`) | Introspection | La Resource legge da `discover/1` già aggiornato |

---

## Standard Stack

### Core (già installato — nessuna dipendenza nuova)

| Library | Version | Purpose | Note |
|---------|---------|---------|------|
| `hermes_mcp` | `~> 0.14` | Framework MCP server; fornisce `Hermes.Server.Component` e macro `schema/field` | [VERIFIED: orkestra_mcp/mix.exs] |
| `jason` | `~> 1.2` | JSON encode/decode per i parametri JSON del tool (es. `events_json`) | [VERIFIED: orkestra_mcp/mix.exs] |

**Nessuna dipendenza nuova da installare.** [VERIFIED: codebase scan]

### Pattern di registrazione tool/resource

Ogni nuovo componente richiede:
1. Un modulo in `orkestra_mcp/lib/orkestra_mcp/tools/` o `resources/`
2. Una riga `component(Module)` in `OrkestraMcp.Server` [VERIFIED: server.ex]

---

## Architecture Patterns

### System Architecture Diagram

```
Chiamata MCP (AI client)
        |
        v
OrkestraMcp.Server          (registrazione di tool e resource)
        |
   [tool]              [resource]              [resource]
gen_es_projection      ListProjections          DomainMap
        |                    |                      |
        v                    v                      v
OrkestraMcp.Generator   OrkestraMcp.Introspection.discover/1
gen_es_projection/4     detect_projectors/2 (esteso)
        |                    |
        v                    v
file system (write!)    struttura %{projectors: [...]}
                          con campo backend: :postgres | :elasticsearch
```

### Recommended Project Structure (file nuovi / modificati)

```
orkestra_mcp/
├── lib/orkestra_mcp/
│   ├── tools/
│   │   └── gen_es_projection.ex          # NUOVO
│   ├── generator.ex                       # MODIFICA: aggiungere gen_es_projection/4
│   ├── introspection.ex                   # MODIFICA: detect_projectors esteso + build_domain_map
│   └── server.ex                          # MODIFICA: aggiungere component(GenEsProjection)
└── test/
    ├── fixtures/sample_project/lib/my_app/orders/projectors/
    │   └── order_es_projector.ex          # NUOVO (fixture)
    ├── orkestra_mcp/
    │   ├── tools/
    │   │   └── gen_es_projection_test.exs # NUOVO
    │   ├── introspection_test.exs         # MODIFICA: aggiungere test ES projector
    │   └── generator_test.exs             # MODIFICA: aggiungere describe gen_es_projection
```

### Pattern 1: Tool MCP — seguire GenProjection / GenEsQueries

**What:** Ogni tool `use Hermes.Server.Component, type: :tool`, definisce schema con `schema do / field` e implementa `execute/2` che delega al Generator. [VERIFIED: gen_projection.ex, gen_es_queries.ex]

**Struttura del nuovo tool `GenEsProjection`:**
```elixir
# Source: orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex (pattern)
defmodule OrkestraMcp.Tools.GenEsProjection do
  @moduledoc "Generate an Orkestra ES Projector module with project_es/2 clauses and index_mapping/0"

  use Hermes.Server.Component, type: :tool

  schema do
    field(:module_name, :string,
      required: true,
      description: "Full ES projector module name, e.g. MyApp.Orders.OrderESProjector"
    )

    field(:repo_module, :string,
      required: true,
      description: "The Ecto.Repo module for checkpoint storage, e.g. MyApp.OrderProjection.Repo"
    )

    field(:cluster_module, :string,
      required: true,
      description: "The Snap.Cluster module, e.g. MyApp.ESCluster"
    )

    field(:index, :string,
      required: true,
      description: "The Elasticsearch index name, e.g. \"orders\""
    )

    field(:events, :string,
      required: true,
      description: ~s(JSON array of event module names: ["MyApp.Events.OrderPlaced"])
    )
  end

  @impl true
  def execute(%{module_name: module_name, repo_module: repo_module,
                cluster_module: cluster_module, index: index, events: events_json}, _frame) do
    project_dir = Application.get_env(:orkestra_mcp, :project_dir)
    events = Jason.decode!(events_json)

    {source, file_path} =
      OrkestraMcp.Generator.gen_es_projection(module_name, repo_module, cluster_module, index, events)

    written = OrkestraMcp.Generator.write!(source, project_dir, file_path)

    {:ok, "Created #{written}\n\n```elixir\n#{source}\n```"}
  end
end
```

### Pattern 2: Generator — seguire gen_projection/3

**What:** Funzione pura `{source_string, file_path}`. La firma è `gen_es_projection(module_name, repo_module, cluster_module, index, events)`. [VERIFIED: generator.ex]

**Template sorgente ES projector (da `Orkestra.Projector` docstring verificata):**
```elixir
# Source: lib/orkestra/projector.ex (esempio canonico ES)
defmodule #{module_name} do
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: #{repo_module},
    cluster: #{cluster_module},
    index: "#{index}",
    event_store: Orkestra.EventStore.InMemory

  @impl true
  def index_mapping do
    %{
      "mappings" => %{
        "properties" => %{
          # TODO: define your index field mappings here, e.g.:
          # "field_name" => %{"type" => "keyword"}
        }
      }
    }
  end

  #{project_es_clauses}
end
```

**Clausola `project_es` per ogni evento:**
```elixir
  project_es #{event}, fn event, _position ->
    # TODO: return {:ok, doc_map, document_id}, :skip, or {:error, reason}
    {:ok, %{}, event.data.id}
  end
```

### Pattern 3: Introspection — rilevamento ES projector

**What:** Il metodo attuale `detect_projectors/2` usa regex `use\s+Orkestra\.Projector,\s*repo:\s*([\w.]+)`. I projector ES hanno `backend: :elasticsearch` come opzione aggiuntiva ma usano la stessa macro `use Orkestra.Projector`. [VERIFIED: introspection.ex, projector.ex]

**Gap attuale:** La regex corrente NON rileva i projector ES perché cerca `repo:` come primo campo dopo `use Orkestra.Projector,` — ma i moduli ES potrebbero avere `backend:` prima di `repo:`. Tuttavia la struttura generata da `gen_es_projection` pone `backend:` prima di `repo:`, quindi la regex attuale potrebbe non fare match.

**Soluzione:** Aggiornare `detect_projectors/2` con una regex che:
1. Rileva `use Orkestra.Projector` (qualsiasi opzione)
2. Estrae `repo:` separatamente (cerca `repo:\s*([\w.]+)` nell'intero contenuto del modulo)
3. Estrae `backend:` se presente (default `:postgres`)
4. Estrae `cluster:` e `index:` se presenti
5. Estrae gli eventi da `project_es` oltre che da `project`

**Struttura risultante aggiornata:**
```elixir
# Postgres projector (backward-compatible)
%{module: "MyApp.OrderProjector", repo: "MyApp.Repo", backend: :postgres,
  cluster: nil, index: nil, events: ["MyApp.Events.OrderPlaced"]}

# ES projector (nuovo)
%{module: "MyApp.OrderESProjector", repo: "MyApp.Repo", backend: :elasticsearch,
  cluster: "MyApp.ESCluster", index: "orders", events: ["MyApp.Events.OrderPlaced"]}
```

### Pattern 4: build_domain_map — annotazione backend

**What:** La funzione `build_domain_map/1` itera `projectors` e genera righe di testo. [VERIFIED: introspection.ex:254-259]

**Aggiornamento:** La riga header del projector deve includere il backend:
```
# Attuale:
"#{proj.module} (projector)"

# Nuovo (con backend):
"#{proj.module} (projector, backend: #{proj.backend})"

# Per ES, includere anche cluster e index:
"#{proj.module} (projector, backend: elasticsearch, index: #{proj.index})"
```

### Anti-Patterns to Avoid

- **Non copiare la logica del generatore nel tool:** Il tool deve solo chiamare `Generator.gen_es_projection/5`; la logica del template vive esclusivamente in `Generator`. [VERIFIED: tutti i tool seguono questo pattern]
- **Non rompere la backward-compatibility di `detect_projectors`:** I test esistenti verificano projector Postgres (`"MyApp.Orders.Projectors.OrderProjector"`); la struttura deve restare compatibile (aggiungere campi, non cambiare quelli esistenti).
- **Non usare `project` (Postgres) nel template ES:** Il DSL ES usa `project_es/2`; mescolarli causa un `CompileError` a compile-time. [VERIFIED: projector.ex:305-312]
- **Non omettere `index_mapping/0`:** È un callback richiesto dai projector ES; il template generato deve sempre includere uno scaffold con TODO.

---

## Don't Hand-Roll

| Problem | Don't Build | Use Instead | Why |
|---------|-------------|-------------|-----|
| Registrazione MCP tool | DSL custom | `use Hermes.Server.Component, type: :tool` + `schema do` | Pattern consolidato; già usato da tutti i 9 tool esistenti |
| Parsing JSON eventi | Parser custom | `Jason.decode!/1` | Già dipendenza diretta del progetto |
| Scrittura file con mkdir_p | Logica custom | `OrkestraMcp.Generator.write!/3` | Funzione pubblica riutilizzabile già esistente |
| Naming module→path | Logica custom | `OrkestraMcp.Naming.module_to_file_path/1` | Già usato da tutti i generatori |

**Key insight:** Tutto il codice necessario esiste già — questa fase è pura composizione, non nuova infrastruttura.

---

## Common Pitfalls

### Pitfall 1: Regex detect_projectors non fa match su ES projector
**What goes wrong:** La regex attuale `use\s+Orkestra\.Projector,\s*repo:\s*([\w.]+)` assume `repo:` come prima opzione. Nel template ES, l'ordine è `backend:`, `repo:`, `cluster:`, `index:`. La regex fallisce in silenzio e il projector ES non compare in `ListProjections`.
**Why it happens:** Regex troppo stretta; ordine delle opzioni non garantito.
**How to avoid:** Usare due passaggi: (1) test `content =~ ~r/use\s+Orkestra\.Projector/` per rilevare qualsiasi projector, poi (2) estrarre `repo:` con `Regex.run(~r/repo:\s*([\w.]+)/, content)` — indipendente dall'ordine.
**Warning signs:** Test `detect_projectors` per ES projector ritorna lista vuota.

### Pitfall 2: Mancanza fixture ES projector nei test
**What goes wrong:** `introspection_test.exs` usa `@fixture_dir` con file di fixture statici. Senza una fixture ES projector, non si può verificare il rilevamento con un test di integrazione leggero.
**Why it happens:** La directory fixture esiste già; va solo aggiunto un file ES projector.
**How to avoid:** Aggiungere `test/fixtures/sample_project/lib/my_app/orders/projectors/order_es_projector.ex` con `use Orkestra.Projector, backend: :elasticsearch, ...`.
**Warning signs:** Test di introspezione per backend ES devono usare contenuto inline invece della fixture.

### Pitfall 3: `index_mapping/0` non marcato `@impl true` nel template
**What goes wrong:** `Orkestra.Projector` dichiara `index_mapping/0` come callback opzionale. Senza `@impl true`, il compilatore Elixir non verifica la firma e l'AI che usa il codice generato potrebbe non capire che è un callback.
**Why it happens:** Dimenticare l'attributo `@impl true` nel template del generator.
**How to avoid:** Il template in `gen_es_projection/5` deve sempre includere `@impl true` prima di `def index_mapping do`.

### Pitfall 4: Il dominio map mostra ES projector come Postgres
**What goes wrong:** Se `detect_projectors` estrae correttamente il modulo ma non il campo `backend:`, la riga nel domain map mostrerà `(projector)` senza indicazione ES.
**Why it happens:** Dimenticare di estrarre e propagare il campo `backend` nella struttura del projector.
**How to avoid:** Assicurarsi che la struttura restituita da `detect_projectors` contenga sempre `backend: :postgres | :elasticsearch` e che `build_domain_map` usi quel campo.

### Pitfall 5: Aggiungere il tool al server senza registrarlo
**What goes wrong:** Il modulo `GenEsProjection` esiste ma non è registrato in `Server`, quindi il tool non appare nell'elenco MCP.
**Why it happens:** Dimenticare `component(OrkestraMcp.Tools.GenEsProjection)` in `server.ex`.
**How to avoid:** Verificare che `mix test` include il nuovo tool nell'elenco eseguendo le suite di test dopo la registrazione.

---

## Code Examples

### Esempio 1: Struttura gen_es_projection/5 in Generator

```elixir
# Source: lib/orkestra/projector.ex (ES projector example, verified)
def gen_es_projection(module_name, repo_module, cluster_module, index, events) do
  project_es_clauses =
    if events == [] do
      """
        project_es EventModule, fn _event, _position ->
          # TODO: return {:ok, doc_map, document_id}, :skip, or {:error, reason}
          {:ok, %{}, nil}
        end
      """
      |> String.trim_trailing()
    else
      events
      |> Enum.map_join("\n\n", fn event ->
        """
          project_es #{event}, fn _event, _position ->
            # TODO: implement projection logic for #{event}
            {:ok, %{}, nil}
          end
        """
        |> String.trim_trailing()
      end)
    end

  source = """
  defmodule #{module_name} do
    use Orkestra.Projector,
      backend: :elasticsearch,
      repo: #{repo_module},
      cluster: #{cluster_module},
      index: "#{index}",
      event_store: Orkestra.EventStore.InMemory

    @impl true
    def index_mapping do
      %{
        "mappings" => %{
          "properties" => %{
            # TODO: define your index field mappings here, e.g.:
            # "field_name" => %{"type" => "keyword"}
          }
        }
      }
    end

  #{project_es_clauses}
  end
  """

  {String.trim(source), Naming.module_to_file_path(module_name)}
end
```

### Esempio 2: detect_projectors/2 aggiornato (approccio multi-regex)

```elixir
# Source: verified from introspection.ex current implementation
defp detect_projectors(acc, content) do
  if content =~ ~r/use\s+Orkestra\.Projector/ do
    case extract_module_name(content) do
      nil ->
        acc
      module_name ->
        repo = extract_option(content, "repo")
        backend = extract_backend(content)
        cluster = extract_option(content, "cluster")
        index_name = extract_string_option(content, "index")
        events = extract_projected_events_all(content)

        entry = %{
          module: module_name,
          repo: repo,
          backend: backend,
          cluster: cluster,
          index: index_name,
          events: events
        }
        %{acc | projectors: acc.projectors ++ [entry]}
    end
  else
    acc
  end
end

defp extract_option(content, key) do
  case Regex.run(~r/#{key}:\s*([\w.]+)/, content) do
    [_, value] -> value
    nil -> nil
  end
end

defp extract_backend(content) do
  case Regex.run(~r/backend:\s*:(\w+)/, content) do
    [_, "elasticsearch"] -> :elasticsearch
    _ -> :postgres
  end
end

defp extract_string_option(content, key) do
  case Regex.run(~r/#{key}:\s*"([^"]+)"/, content) do
    [_, value] -> value
    nil -> nil
  end
end

defp extract_projected_events_all(content) do
  postgres_events = Regex.scan(~r/project\s+([\w.]+),/, content)
    |> Enum.map(fn [_, e] -> e end)
  es_events = Regex.scan(~r/project_es\s+([\w.]+),/, content)
    |> Enum.map(fn [_, e] -> e end)
  Enum.uniq(postgres_events ++ es_events)
end
```

**Attenzione:** `project` è prefisso di `project_es` — la regex `project\s+` (con spazio) evita il falso match, ma va verificato con test.

### Esempio 3: Fixture ES projector per i test

```elixir
# Source: modellato su test/fixtures/sample_project/lib/my_app/orders/projectors/order_projector.ex
defmodule MyApp.Orders.Projectors.OrderESProjector do
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: MyApp.OrderProjection.Repo,
    cluster: MyApp.ESCluster,
    index: "orders",
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

  project_es MyApp.Orders.Events.OrderPlaced, fn _event, _position ->
    {:ok, %{}, nil}
  end
end
```

---

## State of the Art

| Old Approach | Current Approach | When Changed | Impact |
|--------------|------------------|--------------|--------|
| `detect_projectors` solo Postgres (`repo:` come primo campo) | Rilevamento multi-backend con `backend:`, `cluster:`, `index:` | Fase 11 | Backward-compatible; aggiunta di campi alla struttura |
| `ListProjections` mostra solo `module`, `repo`, `events` | Aggiunta di `backend`, `cluster`, `index` per ES | Fase 11 | Consumatori MCP vedono info complete sul backend |

---

## Assumptions Log

| # | Claim | Section | Risk if Wrong |
|---|-------|---------|---------------|
| A1 | L'ordine delle opzioni in `use Orkestra.Projector` nel template generato è `backend:`, `repo:`, `cluster:`, `index:` — quindi la regex attuale `repo:` come PRIMO campo non fa match | Pitfall 1 / Code Examples | Se invece `repo:` è estratto correttamente anche in presenza di `backend:` prima, la regex attuale potrebbe già funzionare per i projector ES; va verificato con un test |
| A2 | `index_mapping/0` è un `@optional_callbacks` in `Orkestra.Projector` (non forzato) | Code Examples | Se è required, il template che genera solo uno scaffold con TODO è corretto ma il compilatore potrebbe non emettere warning sulla mancanza — nessun impatto funzionale |

**Note:** A1 può essere verificato banalmente con un test unitario di introspezione prima di toccare la regex; A2 è un dettaglio di documentazione e non influenza il piano di implementazione.

---

## Open Questions

1. **Struttura evento generato da `project_es` nei test di introspezione**
   - What we know: `extract_projected_events` usa regex `project\s+([\w.]+),` — non rileva `project_es`
   - What's unclear: La struttura `entry.events` per i projector ES deve includere eventi da `project_es`? (Sì, per coerenza con `ListProjections`)
   - Recommendation: Unificare in `extract_projected_events_all/1` che cattura entrambi

2. **Backward-compatibility della struttura `projectors` in ListProjections**
   - What we know: Il JSON di output di `ListProjections` attuale ha `{module, repo, events}`
   - What's unclear: Aggiungere `backend`, `cluster`, `index` è additive e non rompe i client, ma potrebbe richiedere aggiornamenti nei test che verificano strutture esatte
   - Recommendation: Aggiungere i campi, aggiornare i test `introspection_test.exs` per verificare anche i nuovi campi

---

## Environment Availability

Step 2.6: SKIPPED (nessuna dipendenza esterna — fase di sola modifica codice/test Elixir, nessun servizio runtime richiesto).

---

## Validation Architecture

### Test Framework

| Property | Value |
|----------|-------|
| Framework | ExUnit (built-in Elixir) |
| Config file | `orkestra_mcp/test/test_helper.exs` |
| Quick run command | `cd orkestra_mcp && mix test` |
| Full suite command | `cd orkestra_mcp && mix test --warnings-as-errors` |

### Phase Requirements → Test Map

| Req ID | Behavior | Test Type | Automated Command | File Exists? |
|--------|----------|-----------|-------------------|-------------|
| MCP-01 | `gen_es_projection` scaffolda modulo ES projector con backend, repo, cluster, index, events | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/tools/gen_es_projection_test.exs` | ❌ Wave 0 |
| MCP-01 | `Generator.gen_es_projection/5` produce sorgente Elixir valido con clausole `project_es` e `index_mapping/0` | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/generator_test.exs` | ✅ (aggiungere `describe`) |
| MCP-02 | `Introspection.discover/1` riconosce ES projector con `backend: :elasticsearch`, `cluster`, `index` | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/introspection_test.exs` | ✅ (aggiungere test) |
| MCP-02 | `build_domain_map/1` mostra il backend ES nel testo | unit | `cd orkestra_mcp && mix test test/orkestra_mcp/introspection_test.exs` | ✅ (aggiungere test) |
| MCP-02 | `ListProjections` include i projector ES nel JSON restituito | integration | `cd orkestra_mcp && mix test test/orkestra_mcp/introspection_test.exs` | ✅ (indiretto via discover) |

### Sampling Rate

- **Per task commit:** `cd orkestra_mcp && mix test`
- **Per wave merge:** `cd orkestra_mcp && mix test --warnings-as-errors`
- **Phase gate:** Full suite green (44 test esistenti + nuovi) prima di `/gsd-verify-work`

### Wave 0 Gaps

- [ ] `orkestra_mcp/test/orkestra_mcp/tools/gen_es_projection_test.exs` — copre MCP-01 (tool integration)
- [ ] `orkestra_mcp/test/fixtures/sample_project/lib/my_app/orders/projectors/order_es_projector.ex` — fixture ES projector per test di introspezione

*(Tutti gli altri file di test esistono già e richiedono solo l'aggiunta di `describe` / `test` blocks)*

---

## Security Domain

### Applicable ASVS Categories (ASVS Level 1)

| ASVS Category | Applies | Standard Control |
|---------------|---------|-----------------|
| V2 Authentication | no | — |
| V3 Session Management | no | — |
| V4 Access Control | no | — |
| V5 Input Validation | yes (limitato) | `Jason.decode!/1` con rescue — il tool riceve input da AI client tramite MCP |
| V6 Cryptography | no | — |

**Note di sicurezza:**
- Il tool `gen_es_projection` riceve `module_name`, `cluster_module`, `index` come stringhe non valide dall'AI client. Il codice generato viene scritto su filesystem nel `project_dir` configurato. Non c'è escaping del nome modulo nella stringa sorgente. Tuttavia, questo è il pattern consolidato per tutti i generatori esistenti — l'input è considerato trusted (AI client locale). [VERIFIED: gen_projection.ex, gen_es_queries.ex — stesso approccio]
- Nessun rischio ASVS High per questa fase di code generation locale.

---

## Sources

### Primary (HIGH confidence)
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/tools/gen_projection.ex` — pattern tool Postgres (verificato direttamente)
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/tools/gen_es_queries.ex` — pattern tool ES queries (verificato direttamente)
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/generator.ex` — tutte le funzioni gen_* esistenti (verificato direttamente)
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/introspection.ex` — logica detect_projectors e build_domain_map (verificato direttamente)
- `/data/progetti/orkestra/orkestra_mcp/lib/orkestra_mcp/server.ex` — pattern registrazione component (verificato direttamente)
- `/data/progetti/orkestra/lib/orkestra/projector.ex` — DSL ES projector completo con `project_es/2`, `index_mapping/0`, opzioni `backend:`, `cluster:`, `index:` (verificato direttamente)
- Output `mix test` in orkestra_mcp: 44 test, 0 failures (verificato direttamente)

### Secondary (MEDIUM confidence)
- `.planning/REQUIREMENTS.md` — scope MCP-01, MCP-02 (documento di progetto)
- `.planning/STATE.md` — stato attuale milestone v1.1 (documento di progetto)

---

## Metadata

**Confidence breakdown:**
- Standard Stack: HIGH — dipendenze verificate in mix.exs; nessuna nuova libreria necessaria
- Architecture: HIGH — pattern tool/generator/introspection verificati in codebase esistente
- Pitfalls: HIGH — analisi diretta della regex in introspection.ex e del DSL in projector.ex
- Test patterns: HIGH — 44 test esistenti analizzati; pattern ExUnit consolidato

**Research date:** 2026-06-25
**Valid until:** 2026-09-25 (stack stabile; dipendenze fisse in mix.lock)
