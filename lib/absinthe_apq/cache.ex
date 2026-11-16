defmodule AbsintheAPQ.Cache do
  @moduledoc """
  Lets persisted queries live in any store, not only the built-in one.

  `AbsintheAPQ.Cache.ETS` keeps them in this node's memory. To share them between nodes
  or keep them across restarts (Cachex, Nebulex, Redis), write a module with these two
  callbacks and pass it as the `:cache` option of `AbsintheAPQ.DocumentProvider`:

      defmodule MyApp.APQCache do
        @behaviour AbsintheAPQ.Cache

        @impl AbsintheAPQ.Cache
        def get(hash, _opts) do
          case Cachex.get(:apq, hash) do
            {:ok, nil} -> :miss
            {:ok, query} -> {:ok, query}
            {:error, reason} -> {:error, reason}
          end
        end

        @impl AbsintheAPQ.Cache
        def put(hash, query, _opts) do
          case Cachex.put(:apq, hash, query) do
            {:ok, true} -> :ok
            {:error, reason} -> {:error, reason}
          end
        end
      end

  The keys are the hashes that clients send: 64 lowercase hexadecimal characters. Prefix
  them yourself if the store is shared with other data.

  `AbsintheAPQ.DocumentProvider` fails closed. Any `get/2` answer other than
  `{:ok, query}` or `:miss` counts as an error, and the request gets the
  `PersistedQueryNotFound` error, so the client sends the full query again. A query
  that `get/2` returns runs only if it hashes to the key it was stored under. A
  `put/3` error does not stop the request: the client sent the full query, so it runs.
  Errors are reported with the `[:absinthe_apq, :cache_error]` telemetry event.
  """

  @typedoc "The SHA-256 hash of a query, as 64 lowercase hexadecimal characters."
  @type hash :: String.t()

  @typedoc "A GraphQL query string."
  @type query :: String.t()

  @doc """
  Returns the query stored under `hash`, `:miss` when there is none, or an error.

  `opts` are the options given with the module in the `:cache` option, or `[]`.
  """
  @callback get(hash(), opts :: keyword()) :: {:ok, query()} | :miss | {:error, term()}

  @doc """
  Stores `query` under `hash`.

  The document provider calls it only after it has checked that `query` hashes to `hash`
  and that the query passed validation. `opts` are the options given with the module in
  the `:cache` option, or `[]`.
  """
  @callback put(hash(), query(), opts :: keyword()) :: :ok | {:error, term()}
end
