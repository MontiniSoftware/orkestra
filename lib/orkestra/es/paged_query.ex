defmodule Orkestra.ES.PagedQuery do
  @moduledoc """
  Pure builder and response parser behind `Orkestra.ES.Repository.get_paged/1`.

  `build/2` compiles a high-level option list into a full Elasticsearch
  `_search` request body; `parse_response/3` turns the search response back into
  an `Orkestra.ES.Page`. Both functions are pure — they only manipulate maps,
  lists and strings, have **no dependency on Snap**, and are therefore testable
  without any HTTP layer. `build/2` is layered on top of `Orkestra.ES.Query` for
  the bool-query and sort assembly.

  ## Options

    * `:search` — a query string. Compiled into a `multi_match` over the
      schema's `searchable_fields`. The `multi_match` uses the default
      `best_fields` type (natural relevance boosting across fields) and runs in
      `must` context so it contributes to the score. Requesting a search on a
      schema with no searchable fields returns `{:error, :no_searchable_fields}`.

      Searchable fields inside embeds participate too. Fields reached through
      `mode: :object` embeds enter the `multi_match` with their dotted path
      (`"items.name"`). Fields inside `mode: :nested` embeds cannot be matched
      by a root-level `multi_match` (an Elasticsearch limitation), so when any
      nested embed carries searchable fields the `must` clause becomes an inner
      `bool` `should` (`minimum_should_match: 1`) containing the root+object
      `multi_match` plus one `nested` query (correct `path`) with a
      `multi_match` on its fields for **each** such embed — recursively for
      nested-inside-nested (composed paths). `{:error, :no_searchable_fields}`
      is returned only when no searchable field exists anywhere in the tree.

    * `:filters` — a keyword list or map of `field => spec`. The clause is
      derived from the field's declared type:

        * `:keyword` / `:boolean` / `{:array, :keyword}` — a scalar becomes a
          `term`, a list becomes a `terms`, both in `filter` context.
        * numeric (`:integer`/`:long`/`:float`/`:double`) and `:date` — a scalar
          becomes a `term`; a `{:gt | :gte | :lt | :lte, value}` tuple becomes a
          one-sided `range`; a `{:range, from, to}` becomes a `gte`/`lte`
          `range` (a `nil` bound is omitted); a list of op tuples is merged into
          a single combined `range`. All in `filter` context.
        * `:text` — a `match`, in `must` context (contributes to the score).
        * the facets slot (see below) — a list/keyword of `{attr_code,
          value_code}` pairs. Each pair produces one `nested` query in `filter`
          context matching `attr_code` and `value_code` (a list of value codes
          becomes a `terms`). Multiple pairs are AND-combined.
        * an embed name — the spec is a keyword list (or map) of sub-filters
          over the embedded schema's fields, each derived from its declared
          type exactly as above:

              filters: [items: [sku: "X", quantity: {:gte, 2}]]

          For a `mode: :object` embed every sub-filter becomes an independent
          clause on the dotted path (`"items.sku"`, `"items.quantity"`) in its
          usual context. **Beware the cross-entry false positives**: with an
          `embeds_many` in object mode the sub-filters are not correlated to
          the same entry — a document matches if *any* entry satisfies each
          condition separately. For a `mode: :nested` embed the sub-filters
          are combined into **one** `nested` query with an inner `bool`, so
          all conditions must hold on the **same** entry. Sub-filters may
          recurse into deeper embeds by name. An unknown field inside an embed
          returns `{:error, {:unknown_filter_field, "items.sku_typo"}}` with
          the full dotted path.

      An unknown top-level field returns
      `{:error, {:unknown_filter_field, field}}`.

    * `:facets` — `false` (default), `true`, or a list of attribute codes.
      Requires the schema to declare a facets slot, otherwise
      `{:error, :no_facets_field}`. The aggregation is a `nested` agg on the
      facets path, a `terms` on `attr_code` (size 100, optionally restricted with
      `include` when a code list is given), each attribute carrying a size-1
      `terms` on `attr_name` for its display name and a `terms` sub-aggregation
      on `value_code` (size 100) with a size-1 `terms` on `value_name`. Because
      all active filters live in the query, the aggregation counts reflect them
      automatically. Facets are therefore **conjunctive** (a filtered attribute
      constrains the counts of the others); disjunctive facets are out of scope.
      The size limits (100 attributes, 100 values per attribute) are fixed.

    * `:sort` — a keyword list of `field => :asc | :desc`. The field must exist;
      a `:text` field is only sortable through its `keyword` sub-field, so it
      requires `keyword: true` or `sortable: true`, otherwise
      `{:error, {:not_sortable, field}}`. Sorting on embedded fields (either
      the embed name or a dotted path) is **not supported** — a current
      limitation — and returns `{:error, {:not_sortable, field}}`. The schema's `primary_key` is **always**
      appended as a final `asc` tiebreaker (unless already present), which keeps
      `search_after` cursors stable even when no sort is supplied.

    * `:page` / `:page_size` — offset pagination (defaults `1` / `20`), compiled
      into `from`/`size`.

    * `:after` — a cursor string for `search_after` pagination, mutually
      exclusive with `:page` (`{:error, :conflicting_pagination}`). The cursor is
      the URL-safe Base64 of the JSON-encoded sort values of a previous page's
      last hit; a malformed cursor returns `{:error, :invalid_cursor}`.

  The request body always sets `"track_total_hits" => true` so `total` is exact
  for `total_pages`.
  """

  alias Orkestra.ES.{Facet, Page, Query}

  @default_page 1
  @default_page_size 20
  @attr_agg_size 100
  @value_agg_size 100
  @range_ops [:gt, :gte, :lt, :lte]

  @doc """
  Builds a full Elasticsearch `_search` request body from `opts`.

  Returns `{:ok, body}` or `{:error, reason}` (see the module doc for the
  possible reasons). `body` is a string-keyed map ready to hand to
  `Snap.Search.search/3`.
  """
  @spec build(module(), keyword()) :: {:ok, map()} | {:error, term()}
  def build(schema, opts) do
    with {:ok, search_clauses} <- build_search(schema, opts),
         {:ok, filter_clauses} <- build_filters(schema, opts),
         {:ok, sort_clauses} <- build_sort(schema, opts),
         {:ok, aggs} <- build_aggs(schema, opts),
         {:ok, pagination} <- resolve_pagination(opts) do
      query =
        Query.new()
        |> apply_clauses(search_clauses ++ filter_clauses)
        |> apply_sorts(sort_clauses)
        |> Query.size(pagination.page_size)
        |> apply_from(pagination)

      body =
        query
        |> Query.build()
        |> Map.put("track_total_hits", true)
        |> apply_aggs(aggs)
        |> apply_search_after(pagination)

      {:ok, body}
    end
  end

  @doc """
  Turns a search response into an `Orkestra.ES.Page`.

  `response` may be a raw response body map (string-keyed) or a
  `Snap.SearchResponse` struct — the parser reads both without referencing Snap
  at compile time. `opts` are the same options passed to `build/2` (they carry
  the pagination mode and whether facets were requested).
  """
  @spec parse_response(module(), keyword(), map() | struct()) :: Page.t()
  def parse_response(schema, opts, response) do
    {hits, total, aggregations} = normalize_response(response)

    entries = Enum.map(hits, fn %{source: source} -> schema.from_hit(source || %{}) end)
    page_size = Keyword.get(opts, :page_size, @default_page_size)
    next_cursor = compute_next_cursor(hits, page_size)
    facets = build_facets(schema, opts, aggregations)
    page_info = build_page_info(opts, total, page_size, next_cursor)

    %Page{entries: entries, total: total, facets: facets, page_info: page_info}
  end

  # -- full-text search -------------------------------------------------------

  defp build_search(schema, opts) do
    case Keyword.get(opts, :search) do
      value when value in [nil, ""] ->
        {:ok, []}

      text ->
        {flat_fields, nested_scopes} = collect_search_fields(schema, "")

        cond do
          flat_fields == [] and nested_scopes == [] ->
            {:error, :no_searchable_fields}

          nested_scopes == [] ->
            {:ok, [{:must, :multi_match, multi_match_body(text, flat_fields)}]}

          true ->
            clauses =
              flat_multi_match(text, flat_fields) ++
                Enum.map(nested_scopes, &nested_search_query(text, &1))

            {:ok, [{:must, :bool, %{"should" => clauses, "minimum_should_match" => 1}}]}
        end
    end
  end

  # Recursively collects the searchable field paths of a schema and its embed
  # tree. Returns `{flat_fields, nested_scopes}`:
  #
  #   * `flat_fields` — dotted paths reachable from `prefix` without crossing a
  #     nested boundary (own searchable fields + those of object-mode embeds,
  #     recursively). These can be targeted by a plain `multi_match`.
  #   * `nested_scopes` — one `%{path:, fields:, scopes:}` per nested embed that
  #     contains at least one searchable field anywhere in its subtree (scopes
  #     with nothing searchable are pruned). Each requires a `nested` query.
  defp collect_search_fields(schema, prefix) do
    flat = for f <- schema.__es_schema__(:searchable_fields), do: prefix <> Atom.to_string(f)

    Enum.reduce(schema.__es_schema__(:embeds), {flat, []}, fn embed, {flat_acc, scope_acc} ->
      child_prefix = prefix <> Atom.to_string(embed.name) <> "."
      {child_flat, child_scopes} = collect_search_fields(embed.schema, child_prefix)

      case embed.mode do
        :object ->
          {flat_acc ++ child_flat, scope_acc ++ child_scopes}

        :nested ->
          if child_flat == [] and child_scopes == [] do
            {flat_acc, scope_acc}
          else
            path = String.trim_trailing(child_prefix, ".")
            {flat_acc, scope_acc ++ [%{path: path, fields: child_flat, scopes: child_scopes}]}
          end
      end
    end)
  end

  defp multi_match_body(text, fields),
    do: %{"query" => text, "fields" => fields, "type" => "best_fields"}

  defp flat_multi_match(_text, []), do: []
  defp flat_multi_match(text, fields), do: [%{"multi_match" => multi_match_body(text, fields)}]

  # Builds a `nested` search query for one scope. Nested-inside-nested embeds
  # recurse: the inner query becomes a bool `should` combining the scope's own
  # multi_match with the sub-scopes' nested queries.
  defp nested_search_query(text, %{path: path, fields: fields, scopes: scopes}) do
    inner_clauses =
      flat_multi_match(text, fields) ++ Enum.map(scopes, &nested_search_query(text, &1))

    inner =
      case inner_clauses do
        [single] -> single
        many -> %{"bool" => %{"should" => many, "minimum_should_match" => 1}}
      end

    %{"nested" => %{"path" => path, "query" => inner}}
  end

  # -- filters ----------------------------------------------------------------

  defp build_filters(schema, opts) do
    fields = schema.__es_schema__(:fields)
    facets_field = schema.__es_schema__(:facets_field)
    embeds = schema.__es_schema__(:embeds)
    filters = opts |> Keyword.get(:filters, []) |> to_pairs()

    Enum.reduce_while(filters, {:ok, []}, fn {key, spec}, {:ok, acc} ->
      case resolve_field(fields, facets_field, embeds, key) do
        :error ->
          {:halt, {:error, {:unknown_filter_field, key}}}

        {:facets, field} ->
          {:cont, {:ok, acc ++ facets_filter(field, to_pairs(spec))}}

        {:field, meta} ->
          {:cont, {:ok, acc ++ [field_clause(meta, spec)]}}

        {:embed, embed} ->
          case embed_clauses_for(embed, "", to_pairs(spec)) do
            {:ok, clauses} -> {:cont, {:ok, acc ++ clauses}}
            {:error, _} = err -> {:halt, err}
          end
      end
    end)
  end

  defp resolve_field(fields, facets_field, embeds, key) do
    key_str = to_string(key)

    cond do
      not is_nil(facets_field) and key_str == Atom.to_string(facets_field) ->
        {:facets, facets_field}

      embed = Enum.find(embeds, fn %{name: n} -> Atom.to_string(n) == key_str end) ->
        {:embed, embed}

      meta = Enum.find(fields, fn %{name: n} -> Atom.to_string(n) == key_str end) ->
        {:field, meta}

      true ->
        :error
    end
  end

  defp field_clause(%{type: type, name: name}, spec),
    do: clause_for(Atom.to_string(name), type, spec)

  # Derives the clause triple for a (possibly dotted) field path from its
  # declared type — the shared core of top-level and embedded sub-filters.
  defp clause_for(field, type, spec) do
    cond do
      base_type(type) == :text -> {:must, :match, %{field => spec}}
      term_type?(base_type(type)) -> term_clause(field, spec)
      numeric_or_date?(base_type(type)) -> numeric_clause(field, spec)
      true -> {:filter, :term, %{field => spec}}
    end
  end

  # -- embedded filters -------------------------------------------------------

  # Compiles the sub-filters of one embed reached at dotted `prefix`.
  #
  #   * `mode: :object` — every sub-filter becomes an independent clause on the
  #     dotted path, in its usual context (cross-entry false positives are
  #     possible on `embeds_many`, see the module doc).
  #   * `mode: :nested` — all sub-filters are combined into ONE `nested` query
  #     with an inner bool, so they must hold on the same entry.
  defp embed_clauses_for(%{mode: :object, name: name, schema: schema}, prefix, pairs) do
    embed_clauses(schema, prefix <> Atom.to_string(name) <> ".", pairs)
  end

  defp embed_clauses_for(%{mode: :nested, name: name, schema: schema}, prefix, pairs) do
    path = prefix <> Atom.to_string(name)

    case embed_clauses(schema, path <> ".", pairs) do
      {:ok, triples} -> {:ok, [{:filter, :nested, nested_filter_body(path, triples)}]}
      {:error, _} = err -> err
    end
  end

  # Resolves each sub-filter pair against the embedded schema: a field becomes
  # a typed clause on the dotted path; a deeper embed recurses. An unknown key
  # fails with the full dotted path (e.g. `"items.sku_typo"`).
  defp embed_clauses(schema, prefix, pairs) do
    fields = schema.__es_schema__(:fields)
    embeds = schema.__es_schema__(:embeds)

    Enum.reduce_while(pairs, {:ok, []}, fn {key, spec}, {:ok, acc} ->
      key_str = to_string(key)

      cond do
        meta = Enum.find(fields, fn %{name: n} -> Atom.to_string(n) == key_str end) ->
          {:cont, {:ok, acc ++ [clause_for(prefix <> key_str, meta.type, spec)]}}

        embed = Enum.find(embeds, fn %{name: n} -> Atom.to_string(n) == key_str end) ->
          case embed_clauses_for(embed, prefix, to_pairs(spec)) do
            {:ok, clauses} -> {:cont, {:ok, acc ++ clauses}}
            {:error, _} = err -> {:halt, err}
          end

        true ->
          {:halt, {:error, {:unknown_filter_field, prefix <> key_str}}}
      end
    end)
  end

  # Wraps clause triples into the body of a correlated `nested` query: `match`
  # clauses (text) go to the inner bool's `must`, everything else to `filter`.
  defp nested_filter_body(path, triples) do
    must = for {:must, type, value} <- triples, do: %{Atom.to_string(type) => value}
    filter = for {:filter, type, value} <- triples, do: %{Atom.to_string(type) => value}

    bool =
      %{}
      |> put_bool_clause("must", must)
      |> put_bool_clause("filter", filter)

    %{"path" => path, "query" => %{"bool" => bool}}
  end

  defp put_bool_clause(map, _key, []), do: map
  defp put_bool_clause(map, key, clauses), do: Map.put(map, key, clauses)

  defp base_type({:array, inner}), do: inner
  defp base_type(type), do: type

  defp term_type?(type), do: type in [:keyword, :boolean]
  defp numeric_or_date?(type), do: type in [:integer, :long, :float, :double, :date]

  defp term_clause(field, spec) when is_list(spec), do: {:filter, :terms, %{field => spec}}
  defp term_clause(field, spec), do: {:filter, :term, %{field => spec}}

  defp numeric_clause(field, {:range, from, to}),
    do: {:filter, :range, %{field => range_bounds(from, to)}}

  defp numeric_clause(field, {op, value}) when op in @range_ops,
    do: {:filter, :range, %{field => %{Atom.to_string(op) => value}}}

  defp numeric_clause(field, spec) when is_list(spec) do
    if Enum.all?(spec, fn el -> match?({op, _} when op in @range_ops, el) end) do
      bounds =
        Enum.reduce(spec, %{}, fn {op, value}, acc -> Map.put(acc, Atom.to_string(op), value) end)

      {:filter, :range, %{field => bounds}}
    else
      {:filter, :terms, %{field => spec}}
    end
  end

  defp numeric_clause(field, spec), do: {:filter, :term, %{field => spec}}

  defp range_bounds(from, to) do
    %{}
    |> maybe_bound("gte", from)
    |> maybe_bound("lte", to)
  end

  defp maybe_bound(map, _key, nil), do: map
  defp maybe_bound(map, key, value), do: Map.put(map, key, value)

  defp facets_filter(facets_field, pairs) do
    path = Atom.to_string(facets_field)

    Enum.map(pairs, fn {attr, value} ->
      value_clause =
        if is_list(value) do
          %{"terms" => %{"#{path}.value_code" => Enum.map(value, &to_string/1)}}
        else
          %{"term" => %{"#{path}.value_code" => to_string(value)}}
        end

      nested = %{
        "path" => path,
        "query" => %{
          "bool" => %{
            "must" => [
              %{"term" => %{"#{path}.attr_code" => to_string(attr)}},
              value_clause
            ]
          }
        }
      }

      {:filter, :nested, nested}
    end)
  end

  # -- sort -------------------------------------------------------------------

  defp build_sort(schema, opts) do
    fields = schema.__es_schema__(:fields)
    primary_key = schema.__es_schema__(:primary_key)
    sort_opt = opts |> Keyword.get(:sort, []) |> to_pairs()

    case build_sort_clauses(fields, sort_opt) do
      {:error, _} = error ->
        error

      {:ok, clauses, sorted} ->
        pk_str = Atom.to_string(primary_key)

        clauses =
          if pk_str in sorted do
            clauses
          else
            clauses ++ [%{pk_str => %{"order" => "asc"}}]
          end

        {:ok, clauses}
    end
  end

  defp build_sort_clauses(fields, sort_opt) do
    Enum.reduce_while(sort_opt, {:ok, [], []}, fn {field, direction}, {:ok, clauses, sorted} ->
      case sort_clause(fields, field, direction) do
        {:ok, clause} ->
          {:cont, {:ok, clauses ++ [clause], sorted ++ [to_string(field)]}}

        {:error, _} = error ->
          {:halt, error}
      end
    end)
  end

  defp sort_clause(fields, field, direction) do
    key = to_string(field)
    order = if direction == :desc, do: "desc", else: "asc"

    case Enum.find(fields, fn %{name: n} -> Atom.to_string(n) == key end) do
      nil ->
        {:error, {:not_sortable, field}}

      %{type: :text, opts: opts} ->
        if Keyword.get(opts, :keyword) || Keyword.get(opts, :sortable) do
          {:ok, %{(key <> ".keyword") => %{"order" => order}}}
        else
          {:error, {:not_sortable, field}}
        end

      %{} ->
        {:ok, %{key => %{"order" => order}}}
    end
  end

  # -- aggregations (facets) --------------------------------------------------

  defp build_aggs(schema, opts) do
    facets = Keyword.get(opts, :facets, false)
    facets_field = schema.__es_schema__(:facets_field)

    cond do
      facets == false -> {:ok, nil}
      is_nil(facets_field) -> {:error, :no_facets_field}
      facets == true -> {:ok, facets_agg(facets_field, nil)}
      is_list(facets) -> {:ok, facets_agg(facets_field, Enum.map(facets, &to_string/1))}
      true -> {:ok, facets_agg(facets_field, nil)}
    end
  end

  defp facets_agg(facets_field, include) do
    path = Atom.to_string(facets_field)

    attr_terms = %{"field" => "#{path}.attr_code", "size" => @attr_agg_size}
    attr_terms = if include, do: Map.put(attr_terms, "include", include), else: attr_terms

    %{
      "facets" => %{
        "nested" => %{"path" => path},
        "aggs" => %{
          "attr" => %{
            "terms" => attr_terms,
            "aggs" => %{
              "attr_name" => %{"terms" => %{"field" => "#{path}.attr_name", "size" => 1}},
              "value" => %{
                "terms" => %{"field" => "#{path}.value_code", "size" => @value_agg_size},
                "aggs" => %{
                  "value_name" => %{"terms" => %{"field" => "#{path}.value_name", "size" => 1}}
                }
              }
            }
          }
        }
      }
    }
  end

  # -- pagination -------------------------------------------------------------

  defp resolve_pagination(opts) do
    has_after? = Keyword.has_key?(opts, :after)
    has_page? = Keyword.has_key?(opts, :page)
    page_size = Keyword.get(opts, :page_size, @default_page_size)

    cond do
      has_after? and has_page? ->
        {:error, :conflicting_pagination}

      has_after? ->
        case decode_cursor(Keyword.get(opts, :after)) do
          {:ok, search_after} ->
            {:ok, %{mode: :cursor, page_size: page_size, search_after: search_after}}

          :error ->
            {:error, :invalid_cursor}
        end

      true ->
        page = Keyword.get(opts, :page, @default_page)
        {:ok, %{mode: :offset, page: page, page_size: page_size, from: (page - 1) * page_size}}
    end
  end

  defp decode_cursor(cursor) when is_binary(cursor) do
    with {:ok, json} <- Base.url_decode64(cursor, padding: false),
         {:ok, values} <- Jason.decode(json),
         true <- is_list(values) do
      {:ok, values}
    else
      _ -> :error
    end
  end

  defp decode_cursor(_), do: :error

  defp encode_cursor(sort_values) when is_list(sort_values) do
    sort_values |> Jason.encode!() |> Base.url_encode64(padding: false)
  end

  # -- query assembly ---------------------------------------------------------

  defp apply_clauses(query, clauses) do
    Enum.reduce(clauses, query, fn
      {:must, type, value}, acc -> Query.must(acc, [{type, value}])
      {:filter, type, value}, acc -> Query.filter(acc, [{type, value}])
    end)
  end

  defp apply_sorts(query, clauses) do
    Enum.reduce(clauses, query, fn clause, acc -> Query.sort(acc, clause) end)
  end

  defp apply_from(query, %{mode: :offset, from: from}), do: Query.from(query, from)
  defp apply_from(query, _pagination), do: query

  defp apply_aggs(body, nil), do: body
  defp apply_aggs(body, aggs), do: Map.put(body, "aggs", aggs)

  defp apply_search_after(body, %{mode: :cursor, search_after: search_after}),
    do: Map.put(body, "search_after", search_after)

  defp apply_search_after(body, _pagination), do: body

  # -- response parsing -------------------------------------------------------

  # Normalizes both a Snap.SearchResponse struct and a raw response body map
  # into `{hits, total, aggregations}`, where each hit is `%{source:, sort:}`.
  # A struct is read via generic map access, so this module never references
  # Snap at compile time.
  defp normalize_response(response) when is_struct(response) do
    hits_container = Map.get(response, :hits)
    raw_hits = if hits_container, do: Map.get(hits_container, :hits) || [], else: []
    total = if hits_container, do: Map.get(hits_container, :total), else: 0

    hits =
      Enum.map(raw_hits, fn hit -> %{source: Map.get(hit, :source), sort: Map.get(hit, :sort)} end)

    {hits, normalize_total(total), Map.get(response, :aggregations)}
  end

  defp normalize_response(body) when is_map(body) do
    hits_section = body["hits"] || %{}
    raw_hits = hits_section["hits"] || []

    hits = Enum.map(raw_hits, fn hit -> %{source: hit["_source"], sort: hit["sort"]} end)

    {hits, normalize_total(hits_section["total"]), body["aggregations"]}
  end

  defp normalize_total(%{"value" => value}), do: value
  defp normalize_total(value) when is_integer(value), do: value
  defp normalize_total(_), do: 0

  defp compute_next_cursor([], _page_size), do: nil

  defp compute_next_cursor(hits, page_size) do
    if length(hits) < page_size do
      nil
    else
      case List.last(hits) do
        %{sort: sort_values} when is_list(sort_values) -> encode_cursor(sort_values)
        _ -> nil
      end
    end
  end

  defp build_facets(schema, opts, aggregations) do
    case Keyword.get(opts, :facets, false) do
      false -> nil
      _ -> parse_facets(aggregations, schema.__es_schema__(:facets_field))
    end
  end

  defp parse_facets(nil, _facets_field), do: []

  defp parse_facets(aggregations, _facets_field) do
    attr_buckets = get_in(aggregations, ["facets", "attr", "buckets"]) || []

    Enum.map(attr_buckets, fn bucket ->
      %Facet.Attribute{
        code: bucket["key"],
        name: first_bucket_key(bucket["attr_name"]) || bucket["key"],
        values: parse_facet_values(bucket["value"])
      }
    end)
  end

  defp parse_facet_values(nil), do: []

  defp parse_facet_values(value_agg) do
    buckets = value_agg["buckets"] || []

    Enum.map(buckets, fn bucket ->
      %Facet.Value{
        code: bucket["key"],
        name: first_bucket_key(bucket["value_name"]) || bucket["key"],
        count: bucket["doc_count"]
      }
    end)
  end

  defp first_bucket_key(nil), do: nil

  defp first_bucket_key(agg) do
    case agg["buckets"] do
      [%{"key" => key} | _] -> key
      _ -> nil
    end
  end

  defp build_page_info(opts, total, page_size, next_cursor) do
    if Keyword.has_key?(opts, :after) do
      %{mode: :cursor, page_size: page_size, next_cursor: next_cursor}
    else
      page = Keyword.get(opts, :page, @default_page)
      total_pages = if page_size > 0, do: div(total + page_size - 1, page_size), else: 0

      %{
        mode: :offset,
        page: page,
        page_size: page_size,
        total_pages: total_pages,
        next_cursor: next_cursor
      }
    end
  end

  # -- shared helpers ---------------------------------------------------------

  defp to_pairs(nil), do: []
  defp to_pairs(map) when is_map(map), do: Map.to_list(map)
  defp to_pairs(list) when is_list(list), do: list
end
