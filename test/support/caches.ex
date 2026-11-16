defmodule AbsintheAPQ.Test.FailingCache do
  @moduledoc false
  @behaviour AbsintheAPQ.Cache

  @impl AbsintheAPQ.Cache
  def get(_hash, _opts), do: {:error, :down}

  @impl AbsintheAPQ.Cache
  def put(_hash, _query, _opts), do: {:error, :down}
end

defmodule AbsintheAPQ.Test.RaisingCache do
  @moduledoc false
  @behaviour AbsintheAPQ.Cache

  @impl AbsintheAPQ.Cache
  def get(_hash, _opts), do: raise("cache is down")

  @impl AbsintheAPQ.Cache
  def put(_hash, _query, _opts), do: exit(:cache_is_down)
end

defmodule AbsintheAPQ.Test.UnexpectedCache do
  @moduledoc false
  @behaviour AbsintheAPQ.Cache

  # Returns values outside the behaviour, as a buggy adapter would.
  @impl AbsintheAPQ.Cache
  def get(_hash, opts), do: Keyword.get(opts, :get, nil)

  @impl AbsintheAPQ.Cache
  def put(_hash, _query, _opts), do: true
end

defmodule AbsintheAPQ.Test.FixedCache do
  @moduledoc false
  @behaviour AbsintheAPQ.Cache

  # Returns the :query option for every hash, like a store whose entry was overwritten.
  @impl AbsintheAPQ.Cache
  def get(_hash, opts), do: {:ok, Keyword.fetch!(opts, :query)}

  @impl AbsintheAPQ.Cache
  def put(_hash, _query, _opts), do: :ok
end
