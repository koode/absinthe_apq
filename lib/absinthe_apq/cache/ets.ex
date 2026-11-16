defmodule AbsintheAPQ.Cache.ETS do
  @moduledoc """
  A bounded, in-memory `AbsintheAPQ.Cache` in an ETS table.

  Start it in your application's supervision tree:

      children = [
        {AbsintheAPQ.Cache.ETS, max_entries: 1_000},
        MyAppWeb.Endpoint
      ]

  It is the default `:cache` of `AbsintheAPQ.DocumentProvider`. A store with another
  `:name` must be passed explicitly:

      children = [{AbsintheAPQ.Cache.ETS, name: MyApp.APQCache}]

      document_providers: [
        {AbsintheAPQ.DocumentProvider, cache: {AbsintheAPQ.Cache.ETS, name: MyApp.APQCache}},
        Absinthe.Plug.DocumentProvider.Default
      ]

  ## Options

    * `:name`: the name of the process and of its ETS table. Defaults to
      `AbsintheAPQ.Cache.ETS`.
    * `:max_entries`: the most queries the table holds. Defaults to `1_000`.

  ## Bounds and eviction

  The table never holds more than `:max_entries` queries. When a new query would go
  over the limit, the query that was stored first is removed (first in, first out).
  Reading a query does not change its place, and storing a hash that is already in the
  table changes nothing. An evicted query costs its clients one extra round trip: the
  hash-only request misses and the client sends the full query again.

  Together with the `:max_query_bytes` option of `AbsintheAPQ.DocumentProvider`, this
  bounds the memory a client can fill: about `max_entries * max_query_bytes` bytes, or
  32 MiB with the defaults.

  The table lives in this node's memory only. Every node of a cluster has its own, and
  a restart empties it; clients then register their queries again.

  ## Concurrency

  Reads go straight to the ETS table, from the request process, with read concurrency
  on. Writes go through this process, one at a time, so the count and the eviction
  order stay exact.
  """

  @behaviour AbsintheAPQ.Cache

  use GenServer

  @default_name __MODULE__
  @default_max_entries 1_000

  @doc false
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    name = Keyword.get(opts, :name, @default_name)
    %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [opts]}}
  end

  @doc """
  Starts the store. See the module documentation for the options.
  """
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    opts = Keyword.validate!(opts, name: @default_name, max_entries: @default_max_entries)
    name = Keyword.fetch!(opts, :name)
    max_entries = Keyword.fetch!(opts, :max_entries)

    if not (is_integer(max_entries) and max_entries > 0) do
      raise ArgumentError, ":max_entries must be a positive integer, got: #{inspect(max_entries)}"
    end

    GenServer.start_link(__MODULE__, {name, max_entries}, name: name)
  end

  @impl AbsintheAPQ.Cache
  def get(hash, opts) do
    table = Keyword.get(opts, :name, @default_name)

    case :ets.whereis(table) do
      :undefined -> {:error, :not_started}
      table_id -> lookup(table_id, hash)
    end
  end

  @impl AbsintheAPQ.Cache
  def put(hash, query, opts) do
    name = Keyword.get(opts, :name, @default_name)

    case GenServer.whereis(name) do
      nil -> {:error, :not_started}
      pid -> GenServer.call(pid, {:put, hash, query})
    end
  end

  @doc """
  Returns the number of queries in the store.
  """
  @spec size(keyword()) :: non_neg_integer()
  def size(opts \\ []) do
    table = Keyword.get(opts, :name, @default_name)
    :ets.info(table, :size)
  end

  @impl GenServer
  def init({name, max_entries}) do
    table = :ets.new(name, [:set, :protected, :named_table, read_concurrency: true])
    state = %{table: table, max_entries: max_entries, order: :queue.new(), count: 0}
    {:ok, state}
  end

  @impl GenServer
  def handle_call({:put, hash, query}, _from, state) do
    state =
      if :ets.insert_new(state.table, {hash, query}) do
        order = :queue.in(hash, state.order)
        evict(%{state | order: order, count: state.count + 1})
      else
        state
      end

    {:reply, :ok, state}
  end

  defp lookup(table_id, hash) do
    case :ets.lookup(table_id, hash) do
      [{^hash, query}] -> {:ok, query}
      [] -> :miss
    end
  end

  defp evict(%{count: count, max_entries: max_entries} = state) when count > max_entries do
    {{:value, oldest}, order} = :queue.out(state.order)
    :ets.delete(state.table, oldest)
    %{state | order: order, count: count - 1}
  end

  defp evict(state), do: state
end
