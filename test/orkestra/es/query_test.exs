defmodule Orkestra.ES.QueryTest do
  @moduledoc false

  use ExUnit.Case, async: true

  alias Orkestra.ES.Query

  # -------------------------------------------------------------------------
  # new/0
  # -------------------------------------------------------------------------
  describe "new/0" do
    test "returns a Query struct with empty lists and nil pagination" do
      q = Query.new()

      assert %Query{} = q
      assert q.must == []
      assert q.should == []
      assert q.filter == []
      assert q.must_not == []
      assert q.aggs == %{}
      assert q.size == nil
      assert q.from == nil
      assert q.sort == []
    end
  end

  # -------------------------------------------------------------------------
  # bool clauses
  # -------------------------------------------------------------------------
  describe "bool clauses" do
    test "must/2 adds a clause to bool.must" do
      result =
        Query.new()
        |> Query.must(match: %{"status" => "placed"})
        |> Query.build()

      assert result == %{
               "query" => %{
                 "bool" => %{
                   "must" => [%{"match" => %{"status" => "placed"}}]
                 }
               }
             }
    end

    test "should/2 adds a clause to bool.should" do
      result =
        Query.new()
        |> Query.should(term: %{"tag" => "urgent"})
        |> Query.build()

      assert result == %{
               "query" => %{
                 "bool" => %{
                   "should" => [%{"term" => %{"tag" => "urgent"}}]
                 }
               }
             }
    end

    test "filter/2 adds a clause to bool.filter" do
      result =
        Query.new()
        |> Query.filter(range: %{"created_at" => %{"gte" => "2024-01-01"}})
        |> Query.build()

      assert result == %{
               "query" => %{
                 "bool" => %{
                   "filter" => [%{"range" => %{"created_at" => %{"gte" => "2024-01-01"}}}]
                 }
               }
             }
    end

    test "must_not/2 adds a clause to bool.must_not" do
      result =
        Query.new()
        |> Query.must_not(term: %{"cancelled" => true})
        |> Query.build()

      assert result == %{
               "query" => %{
                 "bool" => %{
                   "must_not" => [%{"term" => %{"cancelled" => true}}]
                 }
               }
             }
    end

    test "calling must/2 twice accumulates both clauses (does NOT drop the first)" do
      result =
        Query.new()
        |> Query.must(match: %{"status" => "placed"})
        |> Query.must(match: %{"merchant_id" => "m-123"})
        |> Query.build()

      must_clauses = get_in(result, ["query", "bool", "must"])

      assert length(must_clauses) == 2
      assert %{"match" => %{"status" => "placed"}} in must_clauses
      assert %{"match" => %{"merchant_id" => "m-123"}} in must_clauses
    end
  end

  # -------------------------------------------------------------------------
  # aggs/3
  # -------------------------------------------------------------------------
  describe "aggs/3" do
    test "adds a named aggregation to the aggs map" do
      result =
        Query.new()
        |> Query.aggs("by_status", terms: %{"field" => "status"})
        |> Query.build()

      assert result["aggs"] == %{
               "by_status" => %{"terms" => %{"field" => "status"}}
             }
    end

    test "multiple aggs/3 calls add separate named aggregations" do
      result =
        Query.new()
        |> Query.aggs("by_status", terms: %{"field" => "status"})
        |> Query.aggs("by_merchant", terms: %{"field" => "merchant_id"})
        |> Query.build()

      assert result["aggs"]["by_status"] == %{"terms" => %{"field" => "status"}}
      assert result["aggs"]["by_merchant"] == %{"terms" => %{"field" => "merchant_id"}}
    end
  end

  # -------------------------------------------------------------------------
  # pagination
  # -------------------------------------------------------------------------
  describe "pagination" do
    test "size/2 sets the size field" do
      result =
        Query.new()
        |> Query.size(50)
        |> Query.build()

      assert result["size"] == 50
    end

    test "from/2 sets the from field" do
      result =
        Query.new()
        |> Query.from(100)
        |> Query.build()

      assert result["from"] == 100
    end

    test "size/2 with 0 sets size to 0 (aggregations-only query)" do
      result =
        Query.new()
        |> Query.size(0)
        |> Query.build()

      assert result["size"] == 0
    end
  end

  # -------------------------------------------------------------------------
  # sort/2
  # -------------------------------------------------------------------------
  describe "sort/2" do
    test "sort/2 adds a sort clause to the sort list" do
      result =
        Query.new()
        |> Query.sort(%{"created_at" => %{"order" => "desc"}})
        |> Query.build()

      assert result["sort"] == [%{"created_at" => %{"order" => "desc"}}]
    end

    test "calling sort/2 twice accumulates both sort clauses" do
      result =
        Query.new()
        |> Query.sort(%{"created_at" => %{"order" => "desc"}})
        |> Query.sort(%{"status" => %{"order" => "asc"}})
        |> Query.build()

      assert length(result["sort"]) == 2
      assert %{"created_at" => %{"order" => "desc"}} in result["sort"]
      assert %{"status" => %{"order" => "asc"}} in result["sort"]
    end
  end

  # -------------------------------------------------------------------------
  # build/1
  # -------------------------------------------------------------------------
  describe "build/1" do
    test "empty query produces %{\"query\" => %{\"bool\" => %{}}} (match_all equivalent)" do
      result = Query.new() |> Query.build()

      assert result == %{"query" => %{"bool" => %{}}}
    end

    test "omits empty bool keys: no 'should' key when should list is empty" do
      result =
        Query.new()
        |> Query.must(match: %{"status" => "placed"})
        |> Query.build()

      bool = result["query"]["bool"]
      assert Map.has_key?(bool, "must")
      refute Map.has_key?(bool, "should")
      refute Map.has_key?(bool, "filter")
      refute Map.has_key?(bool, "must_not")
    end

    test "omits size, from, sort, aggs when not set" do
      result = Query.new() |> Query.must(match: %{"x" => "y"}) |> Query.build()

      refute Map.has_key?(result, "size")
      refute Map.has_key?(result, "from")
      refute Map.has_key?(result, "sort")
      refute Map.has_key?(result, "aggs")
    end

    test "omits sort when sort list is empty" do
      result = Query.new() |> Query.build()
      refute Map.has_key?(result, "sort")
    end

    test "omits aggs when aggs map is empty" do
      result = Query.new() |> Query.build()
      refute Map.has_key?(result, "aggs")
    end
  end

  # -------------------------------------------------------------------------
  # composition
  # -------------------------------------------------------------------------
  describe "composition" do
    test "composing must and filter via pipe produces correct combined output" do
      result =
        Query.new()
        |> Query.must(match: %{"status" => "placed"})
        |> Query.filter(range: %{"created_at" => %{"gte" => "2024-01-01"}})
        |> Query.build()

      assert result == %{
               "query" => %{
                 "bool" => %{
                   "must" => [%{"match" => %{"status" => "placed"}}],
                   "filter" => [%{"range" => %{"created_at" => %{"gte" => "2024-01-01"}}}]
                 }
               }
             }
    end

    test "full pipeline with must + filter + must_not + aggs + size + from + sort" do
      result =
        Query.new()
        |> Query.must(match: %{"status" => "placed"})
        |> Query.filter(range: %{"created_at" => %{"gte" => "2024-01-01", "lte" => "2024-12-31"}})
        |> Query.must_not(term: %{"cancelled" => true})
        |> Query.aggs("by_status", terms: %{"field" => "status", "size" => 10})
        |> Query.size(50)
        |> Query.from(0)
        |> Query.sort(%{"created_at" => %{"order" => "desc"}})
        |> Query.build()

      assert result == %{
               "query" => %{
                 "bool" => %{
                   "must" => [%{"match" => %{"status" => "placed"}}],
                   "filter" => [
                     %{
                       "range" => %{
                         "created_at" => %{"gte" => "2024-01-01", "lte" => "2024-12-31"}
                       }
                     }
                   ],
                   "must_not" => [%{"term" => %{"cancelled" => true}}]
                 }
               },
               "aggs" => %{
                 "by_status" => %{"terms" => %{"field" => "status", "size" => 10}}
               },
               "size" => 50,
               "from" => 0,
               "sort" => [%{"created_at" => %{"order" => "desc"}}]
             }
    end
  end
end
