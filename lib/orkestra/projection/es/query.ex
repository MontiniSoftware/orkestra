defmodule Orkestra.Projection.ES.Query do
  @moduledoc """
  Pipe-based DSL for composing Elasticsearch bool queries.

  Produces a query map compatible with `Snap.Search.search/4` as its third
  argument. The module is pure — zero I/O, zero runtime dependencies beyond
  the Elixir standard library.

  ## Usage

      alias Orkestra.Projection.ES.Query

      query =
        Query.new()
        |> Query.must(match: %{"status" => "placed"})
        |> Query.filter(range: %{"created_at" => %{"gte" => "2024-01-01"}})
        |> Query.must_not(term: %{"cancelled" => true})
        |> Query.aggs("by_status", terms: %{"field" => "status", "size" => 10})
        |> Query.size(50)
        |> Query.from(0)
        |> Query.sort(%{"created_at" => %{"order" => "desc"}})
        |> Query.build()

      {:ok, results} = Snap.Search.search(MyApp.ESCluster, "orders", query)

  ## match_all (empty query)

  An empty `Query.new() |> Query.build()` produces:

      %{"query" => %{"bool" => %{}}}

  Elasticsearch and OpenSearch both interpret an empty bool query as
  `match_all` — all documents match. This is the intended behaviour. You do
  not need to add an explicit `match_all` clause.

  ## Accumulative semantics

  Every clause function (`must/2`, `should/2`, `filter/2`, `must_not/2`,
  `sort/2`) **appends** to the existing list. Calling `must/2` twice will
  produce a bool query with two `must` clauses:

      Query.new()
      |> Query.must(match: %{"status" => "placed"})
      |> Query.must(match: %{"merchant_id" => "m-123"})
      |> Query.build()
      # => %{"query" => %{"bool" => %{"must" => [
      #      %{"match" => %{"status" => "placed"}},
      #      %{"match" => %{"merchant_id" => "m-123"}}
      #    ]}}}

  ## Security note

  Clause values are **not sanitised** by this module. The DSL passes values
  as-is to Elasticsearch. If clause values originate from user input, the
  caller is responsible for validating and sanitising them before building the
  query. Malformed values are rejected by Elasticsearch at runtime with a
  `400 parsing_exception`.
  """

  @typedoc """
  A keyword-list pair `[{clause_type :: atom(), value :: map()}]` representing
  one Elasticsearch query clause.

  Examples:
  - `[match: %{"status" => "placed"}]`
  - `[range: %{"created_at" => %{"gte" => "2024-01-01"}}]`
  - `[term: %{"cancelled" => true}]`
  """
  @type clause :: [{atom(), map()}]

  @typedoc """
  The query accumulator struct. Build one with `new/0` and pipe through the
  DSL functions. Finalise with `build/1`.
  """
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

  defstruct must: [],
            should: [],
            filter: [],
            must_not: [],
            aggs: %{},
            size: nil,
            from: nil,
            sort: []

  @doc """
  Returns a new, empty query accumulator.

  Call this to start a pipe chain before adding clauses.

  ## Example

      Query.new() |> Query.must(match: %{"status" => "placed"}) |> Query.build()
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Appends a clause to the `must` list of the bool query.

  `clause` is a one-element keyword list where the key is the ES clause type
  (e.g. `match:`, `term:`, `range:`) and the value is the clause body.

  ## Example

      Query.new() |> Query.must(match: %{"status" => "placed"})
      Query.new() |> Query.must(term: %{"merchant_id" => "m-123"})
  """
  @spec must(t(), clause()) :: t()
  def must(%__MODULE__{} = q, [{type, value}]),
    do: %{q | must: q.must ++ [%{Atom.to_string(type) => value}]}

  @doc """
  Appends a clause to the `should` list of the bool query.

  At least one `should` clause must match unless `minimum_should_match` is
  set. When combined with `must` or `filter`, `should` influences scoring
  only.

  ## Example

      Query.new() |> Query.should(term: %{"tag" => "urgent"})
  """
  @spec should(t(), clause()) :: t()
  def should(%__MODULE__{} = q, [{type, value}]),
    do: %{q | should: q.should ++ [%{Atom.to_string(type) => value}]}

  @doc """
  Appends a clause to the `filter` list of the bool query.

  Filter clauses must match but do **not** contribute to the relevance score.
  Filtered results are cached by Elasticsearch, making filters faster than
  `must` for exact-match conditions.

  ## Example

      Query.new() |> Query.filter(range: %{"created_at" => %{"gte" => "2024-01-01"}})
  """
  @spec filter(t(), clause()) :: t()
  def filter(%__MODULE__{} = q, [{type, value}]),
    do: %{q | filter: q.filter ++ [%{Atom.to_string(type) => value}]}

  @doc """
  Appends a clause to the `must_not` list of the bool query.

  `must_not` clauses must **not** match. Like `filter`, they do not affect
  scoring.

  ## Example

      Query.new() |> Query.must_not(term: %{"cancelled" => true})
  """
  @spec must_not(t(), clause()) :: t()
  def must_not(%__MODULE__{} = q, [{type, value}]),
    do: %{q | must_not: q.must_not ++ [%{Atom.to_string(type) => value}]}

  @doc """
  Adds a named aggregation clause to the query.

  `name` is the aggregation name used to retrieve results from the ES
  response. `agg_clause` is a one-element keyword list specifying the
  aggregation type and its configuration.

  ## Example

      Query.new()
      |> Query.aggs("by_status", terms: %{"field" => "status", "size" => 10})
      |> Query.size(0)
      |> Query.build()
      # => %{"query" => %{"bool" => %{}}, "aggs" => %{"by_status" => %{"terms" => ...}}, "size" => 0}
  """
  @spec aggs(t(), String.t(), clause()) :: t()
  def aggs(%__MODULE__{} = q, name, [{type, value}]) when is_binary(name),
    do: %{q | aggs: Map.put(q.aggs, name, %{Atom.to_string(type) => value})}

  @doc """
  Sets the maximum number of documents to return.

  Pass `0` when you only need aggregation results and no hits.

  ## Example

      Query.new() |> Query.size(50) |> Query.build()
      # => %{"query" => %{"bool" => %{}}, "size" => 50}
  """
  @spec size(t(), non_neg_integer()) :: t()
  def size(%__MODULE__{} = q, n) when is_integer(n) and n >= 0,
    do: %{q | size: n}

  @doc """
  Sets the starting offset for pagination.

  ## Example

      Query.new() |> Query.size(20) |> Query.from(40) |> Query.build()
  """
  @spec from(t(), non_neg_integer()) :: t()
  def from(%__MODULE__{} = q, n) when is_integer(n) and n >= 0,
    do: %{q | from: n}

  @doc """
  Appends a sort clause map to the sort list.

  The `clause` map uses ES sort syntax directly. Multiple calls accumulate
  additional sort levels in the order they are piped.

  ## Example

      Query.new()
      |> Query.sort(%{"created_at" => %{"order" => "desc"}})
      |> Query.sort(%{"status" => %{"order" => "asc"}})
      |> Query.build()
  """
  @spec sort(t(), map()) :: t()
  def sort(%__MODULE__{} = q, clause) when is_map(clause),
    do: %{q | sort: q.sort ++ [clause]}

  @doc """
  Builds the final Elasticsearch query map from the accumulated query struct.

  Returns a map ready to be passed as the third argument to
  `Snap.Search.search/4`. Keys are omitted when their values are empty (empty
  list, empty map, or nil) so that Elasticsearch does not receive superfluous
  fields.

  The `"query"` key is always present, wrapping a `"bool"` map. If all bool
  clause lists are empty the `"bool"` map will be `%{}`, which Elasticsearch
  interprets as `match_all`.

  ## Example

      Query.new()
      |> Query.must(match: %{"status" => "placed"})
      |> Query.build()
      # => %{"query" => %{"bool" => %{"must" => [%{"match" => %{"status" => "placed"}}]}}}
  """
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
    result = if not is_nil(q.size), do: Map.put(result, "size", q.size), else: result
    result = if not is_nil(q.from), do: Map.put(result, "from", q.from), else: result
    result = if q.sort != [], do: Map.put(result, "sort", q.sort), else: result
    result
  end

  # ---------------------------------------------------------------------------
  # Private helpers
  # ---------------------------------------------------------------------------

  # Puts `key => val` into `map` only when `val` is a non-empty list.
  # Used by build/1 to suppress empty bool clause keys.
  defp put_if_nonempty(map, _key, []), do: map
  defp put_if_nonempty(map, key, val), do: Map.put(map, key, val)
end
