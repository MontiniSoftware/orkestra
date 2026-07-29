# Plan: Standalone `Orkestra.ES` subsystem

Status: **completed** — implemented 2026-07-29 (no GSD, direct agent orchestration). All 7 phases
done; full suite green in every configuration (default, `--include elasticsearch --include postgres`
with the Docker stack up, and `mix test.integration` against real Elasticsearch 8.15).

## Goal

Extract the Elasticsearch storage layer from the projection subsystem and turn it into a
standalone, independently usable subsystem: declarative Ecto-like schemas → full ES index
mappings (analyzers included) → generated repository with CRUD, rich paged queries and
structured facets — fully instrumented, pluggable, with first-class dev-ex. Projections are
refactored to build on top of it.

## Approved decisions

| Topic | Decision |
|---|---|
| Packaging | Namespace `Orkestra.ES` inside the core library (`lib/orkestra/es/`), `snap` stays an optional dep (`if Code.ensure_loaded?(Snap.Cluster)` guards). |
| Projections | Full refactor: ES projector declares a schema; `Storage.Elasticsearch` becomes a thin adapter delegating to `Orkestra.ES`. Pre-1.0 breaking changes accepted. |
| Index lifecycle | Alias + versioned physical indexes; mapping hash stored in `_meta`; zero-downtime reindex via `Snap.Indexes.hotswap`. Mix tasks `orkestra.es.setup|migrate|status`. |
| Repository richness | Full-text search on `searchable` fields, typed filters (term/terms/range by field type), structured facets, sort, offset pagination **and** `search_after` cursor. |
| Cultures | Schemas declare `cultures:` + `default_culture:`; one alias per culture (`products_it`); analyzers referenced by logical name, defined per-culture in `settings`; every repository function takes optional `culture:`. Mono-culture schemas (no `cultures:`) degrade to a single unsuffixed alias. |
| Facets | No magic per-field facets. The schema declares a `facets :field_name` slot with a **fixed, library-defined structure**: attribute `{code, name}` + values `{code, name}`. Content is dynamic (arrives with documents). Flattened nested mapping `attr_code/attr_name/value_code/value_name`, aggregated with nested terms aggs. |
| Telemetry | OTel spans `orkestra.es.*` + `:telemetry` events `[:orkestra, :es, :request]`, reusing `Orkestra.Telemetry` helpers. Never log credentials/adapter opts. |
| Workflow | No GSD. Opus 4.8 agents for design-heavy work, Haiku for mechanical work. No commits unless the user asks. Comprehensive final integration tests against a real ES in Docker Compose (max 4 GB memory). |

## Target architecture

```
lib/orkestra/es/
  query.ex            # moved from projection/es/query.ex (pure bool-query DSL)
  schema.ex           # `use Orkestra.ES.Schema` — fields, settings/analyzers, facets slot
  schema/…            # internal compiler helpers (field metadata, mapping builder, casting)
  facet.ex            # Orkestra.ES.Facet.Attribute / Orkestra.ES.Facet.Value structs
  page.ex             # Orkestra.ES.Page result struct (entries, total, facets, page_info)
  repository.ex       # `use Orkestra.ES.Repository, schema:, cluster:`
  index.ex            # engine detection, ensure index+alias, versioning, hotswap wrapper
  auth/api_key.ex     # moved from lib/orkestra/auth/api_key.ex
lib/mix/tasks/
  orkestra.es.setup.ex / orkestra.es.migrate.ex / orkestra.es.status.ex
```

### Schema DSL contract

```elixir
defmodule MyApp.Search.Product do
  use Orkestra.ES.Schema,
    index: "products",
    cultures: [:it, :en],
    default_culture: :it

  settings number_of_shards: 1 do
    analyzer :product_search, for: :it,
      tokenizer: "standard", filter: ["lowercase", "asciifolding", :stemmer_it]
    analyzer :product_search, for: :en,
      tokenizer: "standard", filter: ["lowercase", "porter_stem"]
    filter :stemmer_it, for: :it, type: "stemmer", language: "light_italian"
  end

  schema do
    field :product_id, :keyword, primary_key: true
    field :name,       :text,    analyzer: :product_search, searchable: true, keyword: true
    field :category,   :keyword
    field :price,      :float
    field :released_at, :date,   sortable: true
    field :tags,       {:array, :keyword}
    facets :attributes
  end
end
```

Generated: struct, `__es_schema__/1` introspection, `alias_for/1`, `mapping/1` (mappings +
`analysis` settings per culture, `dynamic: strict` always injected), `mapping_hash/1`,
`to_doc/1`, `from_hit/1`. Compile-time validation: analyzers referenced by fields must be
defined for every culture (a definition without `for:` acts as the shared fallback);
`primary_key` required; unknown types rejected.

### Repository contract

```elixir
defmodule MyApp.Search.Products do
  use Orkestra.ES.Repository, schema: MyApp.Search.Product, cluster: MyApp.ESCluster
end

Products.get(id, culture: :en)          # {:ok, %Product{}} | {:error, :not_found}
Products.save(%Product{}, opts)         # upsert, _id from primary_key
Products.save_all(products, opts)       # Snap.Bulk
Products.delete(id, opts)
Products.count(opts) / Products.stream(query, opts) / Products.refresh(opts)
Products.search(%Orkestra.ES.Query{}, opts)   # escape hatch
Products.get_paged(
  search: "trapano",
  filters: [category: "tools", price: {:gte, 100},
            attributes: [color: "red"]],
  facets: true,                          # or [:color, :brand] or false (default)
  sort: [released_at: :desc],
  page: 2, page_size: 20,               # or after: cursor (search_after)
  culture: :it
)
# => {:ok, %Orkestra.ES.Page{entries, total, facets, page_info}}
```

All functions `defoverridable`. Unknown culture → `{:error, {:unknown_culture, c, valid}}`.
Filters derive from field types: keyword/boolean → term (list → terms), numeric/date →
range ops (`{:gte, v}`, `{:range, from, to}`), text → match. `attributes:` filter → nested
filter on `attr_code` + `value_code`.

## Phases

| # | Phase | Agent | Depends on |
|---|---|---|---|
| 1 | Extraction: move `ES.Query`, `Auth.ApiKey`, extract `Orkestra.ES.Index` (engine detection + ensure_index) out of the projection adapter; update refs/tests | Haiku | — |
| 2 | Schema DSL: `Orkestra.ES.Schema` + facet structs + mapping/casting/hash + compile-time validation | Opus | 1 |
| 3 | Repository CRUD: get/save/save_all/delete/count/stream/refresh/search + instrumentation | Opus | 2 |
| 4 | `get_paged`: typed filters, full-text, facets aggs, sort, offset + search_after, `Page` | Opus | 3 |
| 5 | Index lifecycle: alias+versioning, `_meta` hash, mix tasks setup/migrate/status | Opus | 2 (parallel with 3–4) |
| 6 | Projection refactor: projector `schema:` option, thin `Storage.Elasticsearch`, rebuild task on schema mapping; update `examples/order_system` | Opus | 2–5 |
| 7 | Integration tests vs real ES (Docker Compose, ≤ 4 GB) + docs update | Opus + Haiku | 1–6 |

## Test strategy

- Unit tests (pure, `async: true`) for Schema mapping/casting/validation, Query, filter/facet
  compilation, cursor encoding.
- Integration tests under `test/integration/`, tagged `@moduletag :integration`, excluded by
  default in `test_helper.exs`; run with `mix test --only integration` (alias
  `mix test.integration`) against ES from `docker-compose.es.yml` (root): Elasticsearch
  8.15.0 single-node, `xpack.security.enabled=false`, `mem_limit: 4g`,
  `ES_JAVA_OPTS=-Xms2g -Xmx2g`.
- Integration coverage: setup/migrate lifecycle (incl. hotswap reindex + alias swap), CRUD
  round-trip with date/embedded casting, get_paged (filters, search with per-culture
  stemming it/en, facets with active filters, sort, offset & search_after), multi-culture
  isolation, projection end-to-end (InMemory event store → projector → ES read model).

## Non-goals (this milestone)

- MongoDB adapter, AWS SigV4 auth, Postgres repository equivalent.
- Runtime-dynamic culture registration (cultures are declared in the schema).
