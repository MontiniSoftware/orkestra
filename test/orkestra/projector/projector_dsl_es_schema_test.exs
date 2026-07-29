if Code.ensure_loaded?(Snap.Cluster) do
  defmodule Orkestra.Projector.ProjectorDslEsSchemaTest do
    @moduledoc false

    use ExUnit.Case, async: false

    @moduletag :elasticsearch

    alias Orkestra.ES.Facet

    # -------------------------------------------------------------------------
    # Fixtures — schemas, events, projectors
    # -------------------------------------------------------------------------

    defmodule OrderSchema do
      @moduledoc false
      use Orkestra.ES.Schema, index: "schema_orders"

      settings number_of_shards: 1 do
        analyzer(:name_search, tokenizer: "standard", filter: ["lowercase"])
      end

      schema do
        field(:order_id, :keyword, primary_key: true)
        field(:product_name, :text, analyzer: :name_search, searchable: true, keyword: true)
        field(:status, :keyword)
        facets(:attributes)
      end
    end

    defmodule ProductSchema do
      @moduledoc false
      use Orkestra.ES.Schema,
        index: "schema_products",
        cultures: [:it, :en],
        default_culture: :it

      settings do
        analyzer(:folding, tokenizer: "standard", filter: ["lowercase", "asciifolding"])
      end

      schema do
        field(:product_id, :keyword, primary_key: true)
        field(:name, :text, analyzer: :folding, searchable: true)
      end
    end

    defmodule OtherStruct do
      @moduledoc false
      defstruct [:foo]
    end

    defmodule OrderPlaced do
      @moduledoc false
      defstruct [:id, :type, :data, :global_position]
    end

    defmodule OrderCancelled do
      @moduledoc false
      defstruct [:id, :type, :data, :global_position]
    end

    defmodule BadReturn do
      @moduledoc false
      defstruct [:id, :type, :data, :global_position]
    end

    # Mono-culture schema-backed projector
    defmodule MonoESProjector do
      @moduledoc false
      use Orkestra.Projector,
        backend: :elasticsearch,
        repo: SomeCheckpointRepo,
        cluster: Orkestra.Test.ESCluster,
        schema: Orkestra.Projector.ProjectorDslEsSchemaTest.OrderSchema,
        event_store: SomeEventStore

      alias Orkestra.Projector.ProjectorDslEsSchemaTest.OrderSchema

      project_es(Orkestra.Projector.ProjectorDslEsSchemaTest.OrderPlaced, fn event, _pos ->
        {:ok, %OrderSchema{order_id: event.data.order_id, status: "placed"}}
      end)

      project_es(Orkestra.Projector.ProjectorDslEsSchemaTest.OrderCancelled, fn _event, _pos ->
        {:ok, %OrderSchema{order_id: nil, status: "cancelled"}}
      end)

      project_es(Orkestra.Projector.ProjectorDslEsSchemaTest.BadReturn, fn _event, _pos ->
        {:ok, %Orkestra.Projector.ProjectorDslEsSchemaTest.OtherStruct{foo: 1}}
      end)
    end

    # Multi-culture schema-backed projector (explicit culture)
    defmodule ProductEnProjector do
      @moduledoc false
      use Orkestra.Projector,
        backend: :elasticsearch,
        repo: SomeCheckpointRepo,
        cluster: Orkestra.Test.ESCluster,
        schema: Orkestra.Projector.ProjectorDslEsSchemaTest.ProductSchema,
        culture: :en,
        event_store: SomeEventStore

      alias Orkestra.Projector.ProjectorDslEsSchemaTest.ProductSchema

      project_es(Orkestra.Projector.ProjectorDslEsSchemaTest.OrderPlaced, fn event, _pos ->
        {:ok, %ProductSchema{product_id: event.data.order_id, name: "x"}}
      end)
    end

    # -------------------------------------------------------------------------
    # __projection_config__/0
    # -------------------------------------------------------------------------

    describe "__projection_config__/0 with schema:" do
      test "mono-culture: schema set, culture nil, index is the unsuffixed alias" do
        config = MonoESProjector.__projection_config__()

        assert config.backend == :elasticsearch
        assert config.schema == OrderSchema
        assert config.culture == nil
        assert config.index == "schema_orders"
        assert config.cluster == Orkestra.Test.ESCluster
        assert config.projector_module == MonoESProjector
      end

      test "multi-culture: culture and per-culture alias resolved" do
        config = ProductEnProjector.__projection_config__()

        assert config.schema == ProductSchema
        assert config.culture == :en
        assert config.index == "schema_products_en"
      end

      test "multi-culture without :culture defaults to the schema default_culture" do
        defmodule DefaultCultureProjector do
          @moduledoc false
          use Orkestra.Projector,
            backend: :elasticsearch,
            repo: SomeCheckpointRepo,
            cluster: Orkestra.Test.ESCluster,
            schema: Orkestra.Projector.ProjectorDslEsSchemaTest.ProductSchema,
            event_store: SomeEventStore
        end

        config = DefaultCultureProjector.__projection_config__()
        assert config.culture == :it
        assert config.index == "schema_products_it"
      end

      test "still exposes all legacy config keys" do
        config = MonoESProjector.__projection_config__()
        assert config.repo == SomeCheckpointRepo
        assert is_binary(config.projector_name)
        assert is_binary(config.migrations_path)
        assert is_binary(config.migration_source)
      end
    end

    # -------------------------------------------------------------------------
    # generated index_mapping/0
    # -------------------------------------------------------------------------

    describe "generated index_mapping/0" do
      test "mono-culture equals schema.mapping/0" do
        assert MonoESProjector.index_mapping() == OrderSchema.mapping()
      end

      test "multi-culture equals schema.mapping/1 for the resolved culture" do
        assert ProductEnProjector.index_mapping() == ProductSchema.mapping(:en)
      end
    end

    # -------------------------------------------------------------------------
    # __handle_es__/3 struct conversion
    # -------------------------------------------------------------------------

    describe "__handle_es__/3 with struct return" do
      test "converts {:ok, %Schema{}} into {:ok, doc, id} using to_doc + primary key" do
        event = %OrderPlaced{
          type: inspect(OrderPlaced),
          data: %{order_id: "ORD-1"},
          global_position: 0
        }

        assert {:ok, doc, id} = MonoESProjector.__handle_es__("mono", event, 0)
        assert id == "ORD-1"
        assert doc == OrderSchema.to_doc(%OrderSchema{order_id: "ORD-1", status: "placed"})
        assert doc["order_id"] == "ORD-1"
        assert doc["status"] == "placed"
      end

      test "nil primary key returns {:error, {:missing_primary_key, field}}" do
        event = %OrderCancelled{
          type: inspect(OrderCancelled),
          data: %{order_id: "ORD-2"},
          global_position: 1
        }

        assert {:error, {:missing_primary_key, :order_id}} =
                 MonoESProjector.__handle_es__("mono", event, 1)
      end

      test "struct of a different type returns {:error, {:unexpected_return, _}}" do
        event = %BadReturn{type: inspect(BadReturn), data: %{}, global_position: 2}

        assert {:error, {:unexpected_return, %OtherStruct{}}} =
                 MonoESProjector.__handle_es__("mono", event, 2)
      end

      test ":skip passes through for unregistered events" do
        event = %{type: "Unknown.Event", global_position: 0}
        assert :skip == MonoESProjector.__handle_es__("mono", event, 0)
      end
    end

    # -------------------------------------------------------------------------
    # child_spec/1 adapter_opts
    # -------------------------------------------------------------------------

    describe "child_spec/1 with schema:" do
      test "adapter_opts carries schema, culture, and the resolved alias as index" do
        spec = ProductEnProjector.child_spec([])
        assert %{start: {_, _, [config]}} = spec

        assert Keyword.get(config.adapter_opts, :schema) == ProductSchema
        assert Keyword.get(config.adapter_opts, :culture) == :en
        assert Keyword.get(config.adapter_opts, :index) == "schema_products_en"
        assert Keyword.get(config.adapter_opts, :cluster) == Orkestra.Test.ESCluster
        assert is_function(Keyword.get(config.adapter_opts, :handler), 3)
      end

      test "mono-culture adapter_opts carries schema and nil culture" do
        spec = MonoESProjector.child_spec([])
        assert %{start: {_, _, [config]}} = spec
        assert Keyword.get(config.adapter_opts, :schema) == OrderSchema
        assert Keyword.get(config.adapter_opts, :culture) == nil
        assert Keyword.get(config.adapter_opts, :index) == "schema_orders"
      end
    end

    # -------------------------------------------------------------------------
    # facets round-trip through the generated document
    # -------------------------------------------------------------------------

    describe "facets in generated document" do
      test "struct facets are flattened by to_doc via __handle_es__" do
        defmodule FacetProjector do
          @moduledoc false
          use Orkestra.Projector,
            backend: :elasticsearch,
            repo: SomeCheckpointRepo,
            cluster: Orkestra.Test.ESCluster,
            schema: Orkestra.Projector.ProjectorDslEsSchemaTest.OrderSchema,
            event_store: SomeEventStore

          alias Orkestra.Projector.ProjectorDslEsSchemaTest.OrderSchema
          alias Orkestra.ES.Facet

          project_es(Orkestra.Projector.ProjectorDslEsSchemaTest.OrderPlaced, fn event, _pos ->
            {:ok,
             %OrderSchema{
               order_id: event.data.order_id,
               status: "placed",
               attributes: [
                 %Facet.Attribute{
                   code: "category",
                   name: "Category",
                   values: [%Facet.Value{code: "books", name: "Books"}]
                 }
               ]
             }}
          end)
        end

        event = %OrderPlaced{
          type: inspect(OrderPlaced),
          data: %{order_id: "ORD-9"},
          global_position: 0
        }

        assert {:ok, doc, "ORD-9"} = FacetProjector.__handle_es__("facet", event, 0)

        assert doc["attributes"] == [
                 %{
                   "attr_code" => "category",
                   "attr_name" => "Category",
                   "value_code" => "books",
                   "value_name" => "Books"
                 }
               ]
      end
    end

    # -------------------------------------------------------------------------
    # compile-time validation
    # -------------------------------------------------------------------------

    describe "compile-time validation" do
      test "schema: and index: together raise CompileError" do
        assert_raise CompileError, ~r/mutually exclusive/, fn ->
          Code.compile_string("""
          defmodule ThrowawaySchemaAndIndex do
            use Orkestra.Projector,
              backend: :elasticsearch,
              repo: R,
              cluster: C,
              schema: Orkestra.Projector.ProjectorDslEsSchemaTest.OrderSchema,
              index: "boom"
          end
          """)
        end
      end

      test "unknown culture raises CompileError" do
        assert_raise CompileError, ~r/unknown culture/, fn ->
          Code.compile_string("""
          defmodule ThrowawayBadCulture do
            use Orkestra.Projector,
              backend: :elasticsearch,
              repo: R,
              cluster: C,
              schema: Orkestra.Projector.ProjectorDslEsSchemaTest.ProductSchema,
              culture: :fr
          end
          """)
        end
      end

      test ":culture on a mono-culture schema raises CompileError" do
        assert_raise CompileError, ~r/mono-culture/, fn ->
          Code.compile_string("""
          defmodule ThrowawayMonoCulture do
            use Orkestra.Projector,
              backend: :elasticsearch,
              repo: R,
              cluster: C,
              schema: Orkestra.Projector.ProjectorDslEsSchemaTest.OrderSchema,
              culture: :it
          end
          """)
        end
      end

      test ":culture without :schema raises CompileError" do
        assert_raise CompileError, ~r/only valid together with :schema/, fn ->
          Code.compile_string("""
          defmodule ThrowawayCultureNoSchema do
            use Orkestra.Projector,
              backend: :elasticsearch,
              repo: R,
              cluster: C,
              index: "x",
              culture: :it

            def index_mapping, do: %{"mappings" => %{}}
          end
          """)
        end
      end

      test "defining index_mapping/0 alongside schema: raises CompileError" do
        assert_raise CompileError, ~r/single source of truth/, fn ->
          Code.compile_string("""
          defmodule ThrowawaySchemaWithMapping do
            use Orkestra.Projector,
              backend: :elasticsearch,
              repo: R,
              cluster: C,
              schema: Orkestra.Projector.ProjectorDslEsSchemaTest.OrderSchema

            def index_mapping, do: %{"mappings" => %{}}
          end
          """)
        end
      end
    end
  end
end
