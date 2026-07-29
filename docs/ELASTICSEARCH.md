# Orkestra.ES — Elasticsearch/OpenSearch Read Models

`Orkestra.ES` is a standalone, declarative layer for building Elasticsearch/OpenSearch read models in Elixir. It provides an Ecto-like schema DSL, automatic mapping generation with per-culture analyzers, a pure repository API, and seamless integration with Orkestra projections.

**Use this module when you need:**
- Rich full-text search over domain events (multi-lingual or single-language)
- Faceted navigation (category filters, dynamic attributes, counts)
- Sorted pagination with search-after cursor support
- Zero-downtime schema migrations via alias + versioned indexes
- Standalone use (independent of the projection subsystem) or integrated with projectors

---

## Table of Contents

- [Installation](#installation)
- [Defining a schema](#defining-a-schema)
- [Cultures and multi-language support](#cultures-and-multi-language-support)
- [Facets](#facets)
- [Repository API](#repository-api)
- [Paginated queries](#paginated-queries)
- [Index lifecycle](#index-lifecycle)
- [Using with projections](#using-with-projections)
- [Telemetry and observability](#telemetry-and-observability)
- [Security](#security)

---

## Installation

Add the optional `snap` dependency to `mix.exs`. `snap` is the Elasticsearch HTTP client:

```elixir
def deps do
  [
    {:orkestra, "~> 0.1.0"},
    {:snap, "~> 0.2.0"},           # HTTP client for ES/OpenSearch
    {:finch, "~> 0.21.0"}          # HTTP transport (optional; needed for some environments)
  ]
end
```

Then fetch dependencies:

```bash
mix deps.get
```

Define a `Snap.Cluster` module in your application to point to your Elasticsearch or OpenSearch instance:

```elixir
defmodule MyApp.ESCluster do
  use Snap.Cluster,
    url: System.fetch_env!("ELASTICSEARCH_URL"),  # e.g., "http://localhost:9200"
    auth: Orkestra.ES.Auth.ApiKey,                # or Snap.Auth.Basic
    api_key: System.fetch_env!("ELASTICSEARCH_API_KEY")
end
```

---

## Defining a schema

A schema declares an index, its fields (with types and analysis), optional cultures, and a fixed facets slot. The schema macro generates:
- A struct with all declared fields
- Introspection functions (`__es_schema__/1`)
- The full Elasticsearch mapping (with analysis settings per culture)
- A deterministic mapping hash for drift detection
- Document casting (`to_doc/1`, `from_hit/1`)

### Basic schema (mono-culture)

```elixir
defmodule MyApp.Search.Product do
  use Orkestra.ES.Schema, index: "products"

  settings number_of_shards: 1, number_of_replicas: 0 do
    # Define analyzers and filters here
    analyzer(:product_search,
      tokenizer: "standard",
      filter: ["lowercase", "asciifolding"]
    )
  end

  schema do
    # Field syntax: field(:name, :type, options)
    field(:product_id, :keyword, primary_key: true)
    field(:name, :text, analyzer: :product_search, searchable: true, keyword: true)
    field(:category, :keyword)
    field(:price, :float)
    field(:stock, :integer)
    field(:created_at, :date, sortable: true)
    field(:tags, {:array, :keyword})
  end
end
```

### Multi-culture schema

```elixir
defmodule MyApp.Search.Article do
  use Orkestra.ES.Schema,
    index: "articles",
    cultures: [:it, :en, :es],
    default_culture: :it

  settings number_of_shards: 2 do
    # Italian analyzer
    analyzer(:full_text, for: :it,
      tokenizer: "standard",
      filter: ["lowercase", "asciifolding", :stemmer_it]
    )
    filter(:stemmer_it, for: :it, type: "stemmer", language: "light_italian")

    # English analyzer
    analyzer(:full_text, for: :en,
      tokenizer: "standard",
      filter: ["lowercase", "porter_stem"]
    )

    # Spanish analyzer
    analyzer(:full_text, for: :es,
      tokenizer: "standard",
      filter: ["lowercase", :stemmer_es]
    )
    filter(:stemmer_es, for: :es, type: "stemmer", language: "spanish")
  end

  schema do
    field(:article_id, :keyword, primary_key: true)
    field(:title, :text, analyzer: :full_text, searchable: true, keyword: true)
    field(:body, :text, analyzer: :full_text, searchable: true)
    field(:published_at, :date, sortable: true)
    field(:author_id, :keyword)
  end
end
```

### Schema options

| Option | Required | Description |
|--------|----------|-------------|
| `:index` | yes | The base index name (e.g., `"products"`). Multi-culture schemas get one alias per culture: `products_it`, `products_en`. |
| `:cultures` | no | A list of culture atoms. Omit for mono-culture schemas. |
| `:default_culture` | required with `:cultures` | The default culture when no explicit culture is passed. Must be in `:cultures`. |

### Field types

| Type | Elasticsearch type | Notes |
|------|-------------------|-------|
| `:keyword` | `keyword` | Exact-match, aggregatable. Suitable for IDs, status codes, categories. |
| `:text` | `text` | Full-text searchable. Requires an analyzer. |
| `:integer` | `integer` | 32-bit signed integer. |
| `:long` | `long` | 64-bit signed integer. |
| `:float` | `float` | Single-precision floating-point. |
| `:double` | `double` | Double-precision floating-point. |
| `:boolean` | `boolean` | True/false. |
| `:date` | `date` | ISO 8601 dates or custom format. |
| `{:array, :keyword}` | `keyword` (flattened) | Array of a scalar type; stored flattened by ES. |

### Field options

| Option | Type | Description |
|--------|------|-------------|
| `primary_key: true` | boolean | Marks the field as the document `_id`. Exactly one field required; must be `:keyword`. |
| `analyzer: :name` | atom | `:text` only. References a logical analyzer defined in `settings`. |
| `searchable: true` | boolean | `:text` only. Marks the field for full-text search via `get_paged(search: "...")`. |
| `keyword: true` | boolean | `:text` only. Adds a `"keyword"` sub-field for exact-match filters and sorting. |
| `sortable: true` | boolean | Adds metadata for sorting. For `:text` fields it auto-adds the keyword sub-field. |
| `format: "date format"` | string | `:date` only. Custom Elasticsearch date format (e.g., `"yyyy-MM-dd"`). |
| `default: value` | any | Struct default when the field is not provided. |

### Compile-time validation

The schema macro validates at compile time:
- `:index` is present
- Exactly one field has `primary_key: true`
- All analyzers referenced by `:text` fields are defined in `settings` for every culture
- No unknown field types

Errors are raised during compilation; fix the schema definition and recompile.

### Introspection

Generated by the macro:

```elixir
# Get all field metadata
Product.__es_schema__(:fields)
# => [%{name: :product_id, type: :keyword, opts: [primary_key: true]}, ...]

# Get searchable fields (for full-text search)
Product.__es_schema__(:searchable_fields)
# => [:name]

# Get the facets field (if declared), or nil
Product.__es_schema__(:facets_field)
# => :attributes

# Get cultures (empty list for mono-culture)
Product.__es_schema__(:cultures)
# => []

# Get the primary key field
Product.__es_schema__(:primary_key)
# => :product_id

# Get the index name
Product.__es_schema__(:index)
# => "products"

# Get the default culture
Product.__es_schema__(:default_culture)
# => nil (mono-culture)
```

---

## Cultures and multi-language support

A multi-culture schema maps to multiple aliases — one per culture — all backed by the same versioned physical indexes. Each culture can have its own analyzers and text processing rules, enabling language-specific stemming, tokenization, and accent folding.

### Alias naming

- **Mono-culture** — unsuffixed alias (e.g., `"products"`)
- **Multi-culture** — suffixed aliases (e.g., `"articles_it"`, `"articles_en"`, `"articles_es"`)

### Per-culture analyzers

```elixir
settings do
  # Shared analyzer (fallback, no `for:`)
  analyzer(:base, tokenizer: "standard", filter: ["lowercase"])

  # Italian-only analyzer
  analyzer(:full_text, for: :it,
    tokenizer: "standard",
    filter: ["lowercase", "asciifolding", :stemmer_it]
  )
  filter(:stemmer_it, for: :it, type: "stemmer", language: "light_italian")

  # English-only analyzer
  analyzer(:full_text, for: :en,
    tokenizer: "standard",
    filter: ["lowercase", "porter_stem"]
  )
end
```

An analyzer defined **without** `for:` acts as a shared fallback. An analyzer defined **with** `for:` is only included in that culture's mapping. Every analyzer referenced by a `:text` field **must** be defined for every culture, either as a shared fallback or a per-culture definition.

### Repository culture resolution

Every repository function accepts an optional `:culture` in its options:

```elixir
# Default culture (from the schema)
{:ok, product} = Products.get(product_id)

# Explicit culture
{:ok, product} = Products.get(product_id, culture: :en)

# Multi-culture get_paged with facets
{:ok, page} = Products.get_paged(
  search: "laptop",
  facets: true,
  culture: :it
)

# Mono-culture schema rejects any culture
{:error, {:unknown_culture, :it, []}} = Products.get(id, culture: :it)
```

---

## Facets

Facets are dynamic, hierarchical filters: an attribute (e.g., "Color") owns a set of values (e.g., "Red", "Blue"), and each value can have an aggregation count. Facets are declared as a **single, fixed slot** on the schema (not one per field).

### Facet structure

Facets have a library-defined, canonical structure:

```
Orkestra.ES.Facet.Attribute
  code: String (e.g., "color")
  name: String (e.g., "Color")
  values: [
    Orkestra.ES.Facet.Value
      code: String (e.g., "red")
      name: String (e.g., "Red")
      count: non_neg_integer() | nil
  ]
```

When stored in Elasticsearch, facets are flattened as a nested field:
- `attr_code` — attribute code
- `attr_name` — attribute name
- `value_code` — value code
- `value_name` — value name

When retrieved via `get_paged(facets: true)`, counts are populated from ES aggregations.

### Declaring facets

```elixir
defmodule MyApp.Search.Product do
  use Orkestra.ES.Schema, index: "products"

  settings number_of_shards: 1 do
    # ...
  end

  schema do
    field(:product_id, :keyword, primary_key: true)
    field(:name, :text, searchable: true)
    # ...
    facets(:attributes)  # Declare a single facets slot
  end
end
```

### Indexing documents with facets

Structure your documents to include attributes under the `:attributes` field:

```elixir
doc = %{
  product_id: "prod-123",
  name: "Laptop",
  attributes: [
    %{
      code: "color",
      name: "Color",
      values: [
        %{code: "black", name: "Black"},
        %{code: "silver", name: "Silver"}
      ]
    },
    %{
      code: "brand",
      name: "Brand",
      values: [
        %{code: "dell", name: "Dell"}
      ]
    }
  ]
}

{:ok, product} = Products.save(%MyApp.Search.Product{
  product_id: "prod-123",
  name: "Laptop",
  attributes: doc.attributes
})
```

### Querying with facets

Request facet counts in `get_paged`:

```elixir
{:ok, page} = Products.get_paged(
  search: "laptop",
  facets: true,  # Request all facets
  filters: [category: "electronics"],
  page: 1,
  page_size: 20
)

# page.facets is a list of Orkestra.ES.Facet.Attribute
# Each attribute owns its values with aggregation counts
Enum.each(page.facets, fn attr ->
  IO.inspect(attr.code)  # "color", "brand"
  Enum.each(attr.values, fn val ->
    IO.inspect({val.code, val.count})  # {"black", 42}, {"silver", 15}
  end)
end)
```

Facets with active filters are conjunctive: if you filter by `color: "red"`, the facet counts for other attributes reflect only products that match that filter. The `"color"` facet still shows all available values but their counts drop accordingly.

Request specific facets by code:

```elixir
{:ok, page} = Products.get_paged(
  facets: [:color, :brand]  # Only these attributes
)
```

---

## Repository API

A repository binds a schema to a cluster and provides CRUD, bulk, and query methods.

### Defining a repository

```elixir
defmodule MyApp.Search.Products do
  use Orkestra.ES.Repository,
    schema: MyApp.Search.Product,
    cluster: MyApp.ESCluster
end
```

Both `:schema` and `:cluster` are required. All generated functions are `defoverridable`, so you can override them for caching, logging, or other middleware.

### CRUD operations

#### `get(id, opts \\ [])`

Fetches a single document by its primary-key value.

```elixir
{:ok, product} = Products.get("prod-123")
{:ok, product} = Products.get("prod-456", culture: :en)
{:error, :not_found} = Products.get("missing-id")
{:error, reason} = Products.get(id)  # Network or parsing error
```

Returns:
- `{:ok, struct}` — document found and decoded
- `{:error, :not_found}` — document does not exist
- `{:error, term}` — network or server error

#### `save(struct, opts \\ [])`

Upserts a single document. The `_id` is taken from the primary-key field.

```elixir
product = %MyApp.Search.Product{
  product_id: "prod-123",
  name: "Laptop",
  category: "electronics"
}

{:ok, product} = Products.save(product)
{:ok, product} = Products.save(product, culture: :en)
{:error, {:missing_primary_key, :product_id}} = Products.save(%{name: "No ID"})
{:error, reason} = Products.save(product)
```

Returns:
- `{:ok, struct}` — successfully saved
- `{:error, {:missing_primary_key, field}}` — primary-key field is nil
- `{:error, term}` — network or server error

#### `save_all(structs, opts \\ [])`

Bulk-upserts multiple documents via the Elasticsearch bulk API. All structs must have their primary-key field set.

```elixir
products = [
  %MyApp.Search.Product{product_id: "p1", name: "Item 1"},
  %MyApp.Search.Product{product_id: "p2", name: "Item 2"}
]

:ok = Products.save_all(products)
:ok = Products.save_all(products, culture: :it, page_size: 100)
{:error, {:missing_primary_key, :product_id}} = Products.save_all([%{name: "No ID"}])
{:error, %Snap.BulkError{}} = Products.save_all(products)  # Some items failed
```

Returns:
- `:ok` — all documents indexed successfully
- `{:error, :missing_primary_key, field}` — a struct has nil primary key
- `{:error, %Snap.BulkError{}}` — some items failed (inspect for details)
- `{:error, term}` — network or server error

#### `delete(id, opts \\ [])`

Deletes a single document by its primary-key value.

```elixir
:ok = Products.delete("prod-123")
:ok = Products.delete("prod-456", culture: :en)
{:error, :not_found} = Products.delete("missing-id")
{:error, reason} = Products.delete(id)
```

Returns:
- `:ok` — successfully deleted
- `{:error, :not_found}` — document did not exist
- `{:error, term}` — network or server error

### Query operations

#### `count(opts \\ [])`

Counts documents, optionally constrained by a `:query`.

```elixir
{:ok, total} = Products.count()
{:ok, total} = Products.count(culture: :it)
{:ok, 5} = Products.count(query: Orkestra.ES.Query.new() |> Orkestra.ES.Query.filter(term: %{"status" => "active"}))
```

Returns:
- `{:ok, non_neg_integer}` — the count
- `{:error, term}` — network or server error

#### `stream(opts \\ [])`

Returns a **lazy** stream of documents matching an optional `:query`, using the Elasticsearch scroll API.

```elixir
# Stream all documents
Products.stream()
|> Stream.each(fn product -> IO.inspect(product) end)
|> Stream.run()

# Stream with a filter query
query = Orkestra.ES.Query.new()
        |> Orkestra.ES.Query.filter(term: %{"status" => "active"})

Products.stream(query: query, culture: :en)
|> Enum.take(10)
```

The stream is opened eagerly (the span is recorded), but scroll requests happen lazily as you consume elements.

Returns:
- An `Enumerable.t()` of schema structs
- Raises `ArgumentError` on an unknown culture (since return type is not a tuple)

#### `refresh(opts \\ [])`

Refreshes the target index, making recent writes searchable.

```elixir
:ok = Products.refresh()
:ok = Products.refresh(culture: :it)
{:error, reason} = Products.refresh()
```

Returns:
- `:ok` on success
- `{:error, term}` on failure

#### `search(query, opts \\ [])`

Escape hatch: runs a raw `Orkestra.ES.Query` or a raw ES request map and returns the full `Snap.SearchResponse`.

```elixir
query = Orkestra.ES.Query.new()
        |> Orkestra.ES.Query.must(match: %{"status" => "active"})
        |> Orkestra.ES.Query.size(50)

{:ok, response} = Products.search(query)

# Hits are not decoded; decode with schema.from_hit/1 if needed
Enum.each(response.hits.hits, fn hit ->
  product = MyApp.Search.Product.from_hit(hit["_source"])
  IO.inspect(product)
end)
```

Returns:
- `{:ok, %Snap.SearchResponse{}}` — raw response, hits not decoded
- `{:error, term}` — network or server error

---

## Paginated queries

`get_paged/1` is the primary method for paginated, faceted search.

### Syntax

```elixir
{:ok, page} = Products.get_paged(
  search: "laptop 15-inch",                # Full-text search
  filters: [
    category: "electronics",
    price: {:gte, 500},
    stock: {:range, 1, 1000},
    brand: ["dell", "hp"]                  # Multiple values → terms
  ],
  facets: [:color, :brand],                # Request specific facets
  sort: [created_at: :desc, name: :asc],   # Sort fields
  page: 2,                                 # Offset pagination (page 2)
  page_size: 25,
  culture: :en
)

# or with cursor pagination
{:ok, page} = Products.get_paged(
  search: "laptop",
  page_size: 20,
  after: previous_page.page_info.next_cursor,  # From a prior page
  culture: :en
)
```

### Options

#### Full-text search

**`:search`** — string (optional)

Full-text search across all `searchable: true` fields. Uses a `multi_match` query with `best_fields` type (natural relevance boosting). Requires at least one searchable field in the schema.

```elixir
get_paged(search: "red laptop")  # Matches documents with those terms
get_paged(search: "")            # Empty search is ignored
```

#### Filters

**`:filters`** — keyword list or map of `field => spec` (optional)

Type-aware filters derived from field types:

| Field type | Spec value | ES query |
|------------|-----------|----------|
| `:keyword` / `:boolean` | `"value"` | `term` |
| `:keyword` / `:boolean` | `["a", "b"]` | `terms` |
| `:integer`, `:float`, `:date` | `123` | `term` |
| `:integer`, `:float`, `:date` | `{:gt, 100}`, `{:gte, 100}`, `{:lt, 200}`, `{:lte, 200}` | `range` |
| `:integer`, `:float`, `:date` | `{:range, 100, 200}` | `range` with both bounds |
| `:integer`, `:float`, `:date` | `[{:gte, 100}, {:lt, 200}]` | merged `range` |
| `:text` | `"value"` | `match` (contributes to score) |
| facets slot | `[color: "red", brand: "dell"]` | nested filter on `attr_code`/`value_code` |

```elixir
# Keywords/exacts
get_paged(filters: [status: "active"])
get_paged(filters: [tags: ["urgent", "review"]])

# Ranges
get_paged(filters: [price: {:gte, 100}])
get_paged(filters: [stock: {:range, 1, 1000}])

# Facets
get_paged(filters: [attributes: [color: "red", brand: "dell"]])

# Text (full-text within a field, not via :search)
get_paged(filters: [description: "sustainable"])
```

#### Facets

**`:facets`** — `true`, `false` (default), or `[:code1, :code2]` (optional)

Request facet aggregations. Requires the schema to declare a facets slot. Size limits are fixed: 100 attributes, 100 values per attribute.

```elixir
get_paged(facets: true)           # All facets
get_paged(facets: [:color, :brand])  # Specific facets
get_paged(facets: false)           # No facets (page.facets is nil)
```

#### Sorting

**`:sort`** — keyword list of `field => :asc | :desc` (optional)

Sort by one or more fields. The schema's primary key is **always** appended as a final `:asc` tiebreaker (unless already present) to keep `search_after` cursors stable.

```elixir
get_paged(sort: [created_at: :desc, name: :asc])
get_paged(sort: [price: :asc])
```

Text fields are sortable only via their `keyword` sub-field. Declare `keyword: true` or `sortable: true` on the field:

```elixir
# In schema: field(:title, :text, sortable: true)
get_paged(sort: [title: :asc])  # Sorts on title.keyword
```

#### Pagination (offset mode)

**`:page`** (default `1`) — positive integer

**`:page_size`** (default `20`) — positive integer

```elixir
{:ok, page} = Products.get_paged(page: 1, page_size: 50)
page.page_info
# => %{
#      mode: :offset,
#      page: 1,
#      page_size: 50,
#      total_pages: 5,        # ceil(total / page_size)
#      next_cursor: "..."     # For fetching the next page
#    }
```

#### Pagination (cursor mode)

**`:after`** — Base64-encoded cursor string (mutually exclusive with `:page`)

Use `search_after` pagination for large result sets or deep paging:

```elixir
# First page
{:ok, page1} = Products.get_paged(page_size: 20)

# Next page using cursor
{:ok, page2} = Products.get_paged(
  page_size: 20,
  after: page1.page_info.next_cursor
)

page2.page_info
# => %{
#      mode: :cursor,
#      page_size: 20,
#      next_cursor: "..."     # nil if this is the last page
#    }
```

`:page` and `:after` are mutually exclusive; using both returns `{:error, :conflicting_pagination}`.

#### Culture

**`:culture`** — atom (defaults to schema default)

```elixir
get_paged(search: "laptop", culture: :it)
get_paged(search: "laptop", culture: :en)
{:error, {:unknown_culture, :fr, [:it, :en]}} = get_paged(culture: :fr)
```

### Return value

```elixir
{:ok, %Orkestra.ES.Page{
  entries: [%Product{}, %Product{}, ...],  # Decoded structs
  total: 150,                              # Total matching documents
  facets: [                                # nil if facets: false
    %Orkestra.ES.Facet.Attribute{
      code: "color",
      name: "Color",
      values: [
        %Orkestra.ES.Facet.Value{code: "red", name: "Red", count: 42},
        %Orkestra.ES.Facet.Value{code: "blue", name: "Blue", count: 38}
      ]
    },
    ...
  ],
  page_info: %{
    mode: :offset,
    page: 1,
    page_size: 20,
    total_pages: 8,
    next_cursor: "..."
  }
}}

# Errors
{:error, :no_searchable_fields}                # Schema has no searchable fields
{:error, {:unknown_filter_field, :bad_field}} # Filter references unknown field
{:error, {:not_sortable, :field}}             # Unsortable field in sort
{:error, :no_facets_field}                    # Facets requested but schema has none
{:error, :conflicting_pagination}             # Both :page and :after supplied
{:error, :invalid_cursor}                     # Malformed cursor
{:error, term}                                # Network or server error
```

---

## Index lifecycle

Orkestra.ES manages zero-downtime index updates via **alias + versioned physical indexes**. Each culture of a schema maps to a stable alias pointing to a versioned physical index. Mappings are stored with a SHA-256 hash for drift detection.

### Alias and versioning

Physical index names follow the pattern: `{alias}-{unix_microseconds}`. For example:

```
Schema alias   → products (mono-culture) or products_it, products_en (multi-culture)
Physical index → products-1719782400000000
                 products-1719782500000000 (after migration)
```

The alias always points to the latest physical index. Old indexes are cleaned up automatically after a successful migration.

### Mapping hash

The mapping hash (SHA-256) is stored in `mappings._meta.orkestra_schema_hash` on each physical index. During migration, if the hash doesn't match the current schema definition, the index is rebuilt.

### Mix tasks

Three mix tasks manage the index lifecycle. All require schema configuration:

```elixir
# config/config.exs
config :orkestra, :es_schemas, [
  {MyApp.Search.Product, MyApp.ESCluster},
  {MyApp.Search.Article, MyApp.ESCluster}
]
```

#### `mix orkestra.es.setup`

Creates aliases and versioned indexes for all configured schemas (idempotent — existing aliases are left untouched).

```bash
mix orkestra.es.setup
mix orkestra.es.setup --schema MyApp.Search.Product
mix orkestra.es.setup --schema MyApp.Search.Product --culture it
```

Options:
- `--schema` — only setup the given schema module
- `--culture` — only setup the given culture (multi-culture schemas only)

Output: `created` or `already_exists` per schema × culture.

#### `mix orkestra.es.status`

Prints a read-only table showing alias existence, drift status, and mapping hashes.

```bash
mix orkestra.es.status
mix orkestra.es.status --schema MyApp.Search.Product
```

Output:
```
SCHEMA               CULTURE  ALIAS         EXISTS  DRIFT?  CURRENT   SCHEMA
MyApp.Search.Product -        products      true    false   a3b4c1d2  a3b4c1d2
MyApp.Search.Article it       articles_it   true    true    a1b2c3d4  b5c6d7e8
```

#### `mix orkestra.es.migrate`

Reconciles aliases with the current schema definitions. Creates missing aliases; reindexes drifted ones zero-downtime via `Snap.Indexes.hotswap/5`.

```bash
mix orkestra.es.migrate
mix orkestra.es.migrate --schema MyApp.Search.Product
mix orkestra.es.migrate --dry-run
```

Options:
- `--schema` — only migrate the given schema module
- `--culture` — only migrate the given culture
- `--dry-run` — report actions without applying them

Output: `noop`, `created`, or `migrated` per schema × culture.

### Consistency window

Migration does not capture writes that occur concurrently with the reindex. Documents indexed after the scroll snapshot but before the alias swap are not carried over. Coordinate the write path externally (e.g., halt the projector during migration) to ensure consistency, just as with a projection rebuild.

---

## Using with projections

Orkestra projectors can be backed by Elasticsearch instead of Postgres, using the `Orkestra.ES.Schema` to declare the read-model mapping.

### Projector with schema (recommended)

```elixir
defmodule MyApp.OrderESProjector do
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: MyApp.OrderProjection.Repo,          # Checkpoint repo (Postgres)
    cluster: MyApp.ESCluster,
    schema: MyApp.Search.Order,                # ES read-model schema
    culture: :en,                              # Culture for multi-culture schemas (optional)
    event_store: Orkestra.EventStore.InMemory

  project_es MyApp.Events.OrderPlaced, fn event, _position ->
    {:ok, %MyApp.Search.Order{
      order_id: event.data.order_id,
      product_name: event.data.product_name,
      total: event.data.total,
      status: "placed",
      placed_at: DateTime.utc_now()
    }}
  end

  project_es MyApp.Events.OrderCancelled, fn event, _position ->
    {:ok, %MyApp.Search.Order{
      order_id: event.data.order_id,
      status: "cancelled",
      cancel_reason: event.data.reason
    }}
  end
end
```

With `:schema`, handlers can return either:
- `{:ok, %SchemaStruct{}}` — document and `_id` are derived from the struct
- `{:ok, doc, id}` — legacy tuple; `doc` is an untyped map, `id` is the string `_id`

The `:culture` option defaults to the schema's `default_culture` for multi-culture schemas; omit it for mono-culture schemas.

### Projector with manual index mapping (legacy path)

```elixir
defmodule MyApp.LegacyOrderESProjector do
  use Orkestra.Projector,
    backend: :elasticsearch,
    repo: MyApp.OrderProjection.Repo,
    cluster: MyApp.ESCluster,
    index: "orders",                           # Raw index name
    event_store: Orkestra.EventStore.InMemory

  def index_mapping do
    %{
      "mappings" => %{
        "properties" => %{
          "order_id" => %{"type" => "keyword"},
          "status" => %{"type" => "keyword"},
          "total" => %{"type" => "float"}
        }
      }
    }
  end

  project_es MyApp.Events.OrderPlaced, fn event, _position ->
    {:ok, %{
      "order_id" => event.data.order_id,
      "status" => "placed",
      "total" => event.data.total
    }, event.data.order_id}
  end
end
```

The legacy path writes to a raw index name and requires a manually-defined `index_mapping/0`. Use the schema path for new projectors; the legacy path is supported for backward compatibility.

### Rebuild task

When the schema mapping changes, rebuild the projection:

```bash
mix orkestra.projection.es.rebuild --projector MyApp.OrderESProjector
```

This:
1. Calls `Orkestra.ES.Index.migrate/3` to handle alias + versioning
2. Replays the event stream from the beginning
3. Re-projects all events into the new index

---

## Telemetry and observability

All `Orkestra.ES.Repository` operations emit OpenTelemetry spans and `:telemetry` events.

### Spans

Each operation opens a span named `orkestra.es.{op}` (e.g., `orkestra.es.get`, `orkestra.es.save`, `orkestra.es.get_paged`).

Span attributes:
- `orkestra.es.schema` — the schema module
- `es.index` — the resolved alias
- `es.culture` — the resolved culture (or `nil` for mono-culture)
- `es.doc_count` — document count (only for `save_all/2`)

Cluster credentials and adapter options are never logged.

### Telemetry events

Every operation emits a `[:orkestra, :es, :request]` event:

```elixir
:telemetry.attach_many(
  "es-stats",
  [[:orkestra, :es, :request]],
  fn event, measurements, metadata ->
    IO.inspect(measurements)  # %{duration_ms: 123}
    IO.inspect(metadata)      # %{op: :get, index: "products", culture: nil, schema: ..., result: :ok}
  end,
  nil
)
```

Measurements:
- `duration_ms` — operation duration in milliseconds

Metadata:
- `op` — the operation (`:get`, `:save`, `:delete`, `:count`, `:stream`, `:refresh`, `:search`, `:get_paged`)
- `index` — the resolved alias name
- `culture` — the culture (or `nil`)
- `schema` — the schema module
- `result` — `:ok` or `:error`

---

## Security

### Credentials

Never commit Elasticsearch credentials to source control. Use runtime configuration:

```elixir
# config/runtime.exs
config :my_app, MyApp.ESCluster,
  url: System.fetch_env!("ELASTICSEARCH_URL"),
  auth: Orkestra.ES.Auth.ApiKey,
  api_key: System.fetch_env!("ELASTICSEARCH_API_KEY")
```

### API key authentication

Orkestra.ES provides `Orkestra.ES.Auth.ApiKey` for API key authentication (Elasticsearch 8.x and OpenSearch 2.x+):

```elixir
defmodule MyApp.ESCluster do
  use Snap.Cluster,
    url: System.fetch_env!("ELASTICSEARCH_URL"),
    auth: Orkestra.ES.Auth.ApiKey,
    api_key: System.fetch_env!("ELASTICSEARCH_API_KEY")  # Must be Base64-encoded: "id:api_key"
end
```

The `:api_key` value is the already-encoded combined string from Elasticsearch:

```bash
# In Elasticsearch (or get from your cluster dashboard)
$ curl -X POST "https://my-cluster.es.io:9200/_security/api_key" \
  -H "Content-Type: application/json" \
  -d '{"name":"my-key"}'

{"api_key":"...value...","id":"...id..."}

# In your env file or secrets manager
ELASTICSEARCH_API_KEY="base64(id:value)"
```

### HTTPS in production

Always use `https://` URLs in production:

```elixir
url: "https://my-cluster.es.io:9200"   # Production
url: "http://localhost:9200"            # Local dev only
```

### Dynamic field restrictions

All indexes are created with `"dynamic": "strict"` to prevent mapping explosion attacks. Unknown fields are rejected at index time.

---

## Examples

See the complete working example at `examples/order_system/`:
- `lib/order_system/search/order.ex` — schema definition
- `lib/order_system/search/orders.ex` — repository
- `lib/order_system/orders/queries.ex` — example queries built on `Orders.get_paged/1`
- Integration tests in `test/integration/`
