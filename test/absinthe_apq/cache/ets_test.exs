defmodule AbsintheAPQ.Cache.ETSTest do
  use ExUnit.Case, async: true

  alias AbsintheAPQ.Cache.ETS

  setup do
    name = :"apq_ets_#{System.unique_integer([:positive])}"
    %{name: name, opts: [name: name]}
  end

  describe "get/2 and put/3" do
    test "returns a stored query and :miss for an unknown hash", %{name: name, opts: opts} do
      start_supervised!({ETS, name: name})

      assert ETS.get("a", opts) == :miss
      assert ETS.put("a", "{ a }", opts) == :ok
      assert ETS.get("a", opts) == {:ok, "{ a }"}
    end

    test "returns {:error, :not_started} when the store is not running", %{opts: opts} do
      assert ETS.get("a", opts) == {:error, :not_started}
      assert ETS.put("a", "{ a }", opts) == {:error, :not_started}
    end

    test "uses the module name when no name is given" do
      start_supervised!(ETS)

      assert ETS.put("default", "{ default }", []) == :ok
      assert ETS.get("default", []) == {:ok, "{ default }"}
      assert :ets.whereis(ETS) != :undefined
    end
  end

  describe "bounds and eviction" do
    test "never holds more than :max_entries queries", %{name: name, opts: opts} do
      start_supervised!({ETS, name: name, max_entries: 3})

      for index <- 1..10, do: :ok = ETS.put("hash#{index}", "query #{index}", opts)

      assert ETS.size(opts) == 3
    end

    test "evicts the query that was stored first", %{name: name, opts: opts} do
      start_supervised!({ETS, name: name, max_entries: 2})

      :ok = ETS.put("first", "{ first }", opts)
      :ok = ETS.put("second", "{ second }", opts)
      # Reading does not move an entry.
      {:ok, "{ first }"} = ETS.get("first", opts)
      :ok = ETS.put("third", "{ third }", opts)

      assert ETS.get("first", opts) == :miss
      assert ETS.get("second", opts) == {:ok, "{ second }"}
      assert ETS.get("third", opts) == {:ok, "{ third }"}
    end

    test "storing a hash again neither duplicates nor moves it", %{name: name, opts: opts} do
      start_supervised!({ETS, name: name, max_entries: 2})

      :ok = ETS.put("first", "{ first }", opts)
      :ok = ETS.put("second", "{ second }", opts)
      :ok = ETS.put("first", "{ first }", opts)
      assert ETS.size(opts) == 2

      :ok = ETS.put("third", "{ third }", opts)

      assert ETS.get("first", opts) == :miss
      assert ETS.get("second", opts) == {:ok, "{ second }"}
    end

    test "rejects a :max_entries that is not a positive integer", %{name: name} do
      assert_raise ArgumentError, ~r/:max_entries must be a positive integer/, fn ->
        ETS.start_link(name: name, max_entries: 0)
      end
    end

    test "rejects unknown options", %{name: name} do
      assert_raise ArgumentError, ~r/unknown keys \[:max_size\]/, fn ->
        ETS.start_link(name: name, max_size: 10)
      end
    end
  end

  describe "concurrency" do
    test "concurrent writers and readers keep the bound and the entries", %{
      name: name,
      opts: opts
    } do
      start_supervised!({ETS, name: name, max_entries: 50})

      results =
        1..500
        |> Task.async_stream(
          fn index ->
            hash = "hash#{rem(index, 100)}"
            query = "query #{rem(index, 100)}"
            :ok = ETS.put(hash, query, opts)
            {hash, query, ETS.get(hash, opts)}
          end,
          max_concurrency: 50
        )
        |> Enum.map(fn {:ok, result} -> result end)

      assert ETS.size(opts) == 50

      # A read returns the query stored under its hash, or :miss once it was evicted;
      # never another hash's query.
      for {_hash, query, read} <- results do
        assert read in [{:ok, query}, :miss]
      end
    end

    test "two stores with different names are independent" do
      first = :"apq_ets_first_#{System.unique_integer([:positive])}"
      second = :"apq_ets_second_#{System.unique_integer([:positive])}"
      start_supervised!({ETS, name: first})
      start_supervised!({ETS, name: second})

      :ok = ETS.put("hash", "{ first }", name: first)

      assert ETS.get("hash", name: first) == {:ok, "{ first }"}
      assert ETS.get("hash", name: second) == :miss
    end
  end
end
