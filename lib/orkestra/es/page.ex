defmodule Orkestra.ES.Page do
  @moduledoc """
  A page of results returned by `Orkestra.ES.Repository`'s `get_paged/1`.

  A page bundles the decoded `entries`, the `total` number of matching
  documents, the optionally-computed `facets`, and a `page_info` map describing
  the pagination mode.

  This module is pure: it carries no dependency on Snap and performs no I/O.

  ## Fields

    * `entries` — the list of schema structs for the current page, in ranking
      order (decoded via the schema's `from_hit/1`).
    * `total` — the total number of documents matching the query (independent of
      the page size).
    * `facets` — a list of `Orkestra.ES.Facet.Attribute` structs (each owning its
      `Orkestra.ES.Facet.Value` list with aggregation `count`s), or `nil` when
      facets were not requested.
    * `page_info` — a map describing how the page was paginated.

  ## `page_info`

  Two shapes are possible, distinguished by the `:mode` key:

    * **offset** — `%{mode: :offset, page:, page_size:, total_pages:,
      next_cursor:}`. `total_pages` is `ceil(total / page_size)`.
    * **cursor** — `%{mode: :cursor, page_size:, next_cursor:}`, used for
      `search_after` pagination.

  In both shapes `next_cursor` is an opaque, URL-safe Base64 string that can be
  fed back as the `:after` option to fetch the following page, or `nil` when the
  current page is the last one (fewer hits than `page_size` were returned).
  """

  alias Orkestra.ES.Facet

  @typedoc "A page of paginated read-model results."
  @type t :: %__MODULE__{
          entries: [struct()],
          total: non_neg_integer(),
          facets: [Facet.Attribute.t()] | nil,
          page_info: map()
        }

  defstruct entries: [], total: 0, facets: nil, page_info: %{}
end
