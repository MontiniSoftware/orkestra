defmodule Orkestra.ES.Facet do
  @moduledoc """
  Canonical facet structs shared by the `Orkestra.ES` subsystem.

  Facets model a **library-defined, fixed structure** — an attribute
  (`code`/`name`) that owns an ordered list of values (`code`/`name`/`count`).
  The content is dynamic (it arrives with the documents), but the shape is
  always the same, which lets the schema declare a single `facets` slot instead
  of one mapping per attribute.

  This module is pure: it has **no dependency on Snap** and performs no I/O.

  See `Orkestra.ES.Facet.Attribute` and `Orkestra.ES.Facet.Value`.
  """

  defmodule Value do
    @moduledoc """
    A single facet value belonging to an `Orkestra.ES.Facet.Attribute`.

    `count` is `nil` inside indexed documents (values carry no count when
    stored) and only becomes a `non_neg_integer()` when the struct is produced
    from an Elasticsearch aggregation result.
    """

    @typedoc "A facet value with an optional aggregation `count`."
    @type t :: %__MODULE__{
            code: String.t(),
            name: String.t(),
            count: non_neg_integer() | nil
          }

    defstruct code: nil, name: nil, count: nil
  end

  defmodule Attribute do
    @moduledoc """
    A facet attribute: a `code`/`name` pair owning an ordered list of
    `Orkestra.ES.Facet.Value` structs.
    """

    @typedoc "A facet attribute grouping an ordered list of values."
    @type t :: %__MODULE__{
            code: String.t(),
            name: String.t(),
            values: [Orkestra.ES.Facet.Value.t()]
          }

    defstruct code: nil, name: nil, values: []
  end
end
