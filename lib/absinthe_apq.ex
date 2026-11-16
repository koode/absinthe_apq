defmodule AbsintheAPQ do
  @moduledoc """
  Apollo Automatic Persisted Queries (APQ) for Absinthe and `Absinthe.Plug`.

  A client sends the SHA-256 hash of a query instead of the query text. When the server
  knows the hash, it runs the stored query. When it does not, it answers with a
  `PersistedQueryNotFound` error, and the client sends the hash and the query text once,
  so the server can store them.

  The parts:

    * `AbsintheAPQ.DocumentProvider` reads the `persistedQuery` extension of a request
      and gives `Absinthe.Plug` the document to run, or the APQ error to return.
    * `AbsintheAPQ.Cache` is the behaviour of the store that maps hashes to queries.
      `AbsintheAPQ.Cache.ETS` is the built-in, bounded, in-memory store.
    * `before_send/2` is an optional `Absinthe.Plug` `:before_send` hook that gives APQ
      errors the HTTP status and `cache-control` header that Apollo servers use.

  The rules the library follows, with their sources, are in the
  [protocol notes](PROTOCOL.md).

  ## Telemetry

  Every event name starts with `:absinthe_apq`. The metadata of every event has the
  `:hash` that the request sent, except `[:absinthe_apq, :invalid_request]`, whose hash
  may be missing or malformed, and `[:absinthe_apq, :not_supported]`.

    * `[:absinthe_apq, :hit]`: a hash-only request found its query in the cache.
      Measurements: `%{query_bytes: integer}`.
    * `[:absinthe_apq, :miss]`: a hash-only request did not find its query, and gets
      the `PersistedQueryNotFound` error. Measurements: `%{}`.
    * `[:absinthe_apq, :store]`: a query and its hash were stored, after the query passed
      validation. Measurements: `%{query_bytes: integer}`.
    * `[:absinthe_apq, :hash_mismatch]`: the query text does not hash to the hash the
      request sent. Measurements: `%{query_bytes: integer}`.
    * `[:absinthe_apq, :query_too_large]`: the query is larger than `:max_query_bytes`,
      so it runs but is not stored. Measurements: `%{query_bytes: integer}`. Metadata
      also has `:max_query_bytes`.
    * `[:absinthe_apq, :invalid_request]`: the `persistedQuery` extension has an
      unsupported version or a malformed hash. Measurements: `%{}`. Metadata:
      `%{reason: :unsupported_version | :invalid_hash}`.
    * `[:absinthe_apq, :not_supported]`: the provider runs with `enabled: false`, and
      the request gets the `PersistedQueryNotSupported` error. Measurements: `%{}`.
    * `[:absinthe_apq, :cache_error]`: the cache returned an error, or an entry whose
      query does not hash to its key. Measurements: `%{}`. Metadata also has
      `:operation` (`:get` or `:put`) and `:reason`: the error the cache returned,
      `{:exception, exception}`, `{:exit, reason}`, `{:throw, value}`,
      `{:invalid_return, value}`, or `:stored_query_hash_mismatch`. A failed `:get` answers the
      request with `PersistedQueryNotFound`; a failed `:put` still runs the query.
  """

  alias AbsintheAPQ.Phase.Error

  @doc """
  Returns the SHA-256 hash of `query` as 64 lowercase hexadecimal characters.

  This is the hash an APQ client sends in `extensions.persistedQuery.sha256Hash`.

      iex> AbsintheAPQ.hash("{__typename}")
      "ecf4edb46db40b5132295c0291d62fb65d6759a9eedfa4d5d612dd5ec54a6b38"
  """
  @spec hash(String.t()) :: String.t()
  def hash(query) when is_binary(query) do
    :sha256 |> :crypto.hash(query) |> Base.encode16(case: :lower)
  end

  @doc """
  An `Absinthe.Plug` `:before_send` hook for the HTTP side of APQ errors.

  `Absinthe.Plug` sends every executed result with status 200, and a document provider
  cannot reach the connection. Add this hook to answer APQ errors the way Apollo Server
  and Apollo Router do:

    * every APQ error gets `cache-control: private, no-cache, must-revalidate`, so a CDN
      does not keep a `PersistedQueryNotFound` answer for a hash that is stored a moment
      later;
    * a hash mismatch, an unsupported version and a malformed hash get status 400.
      `PersistedQueryNotFound` and `PersistedQueryNotSupported` keep status 200, which
      the protocol requires.

  In a batched request the status stays 200, because the other results in the batch
  are not errors.

      forward "/graphql", Absinthe.Plug,
        schema: MyAppWeb.Schema,
        document_providers: [AbsintheAPQ.DocumentProvider, Absinthe.Plug.DocumentProvider.Default],
        before_send: {AbsintheAPQ, :before_send}

  If you already have a `:before_send` hook, call this function from it.
  """
  @spec before_send(Plug.Conn.t(), Absinthe.Blueprint.t()) :: Plug.Conn.t()
  def before_send(%Plug.Conn{} = conn, %Absinthe.Blueprint{} = blueprint) do
    case Error.kind(blueprint) do
      nil -> conn
      kind -> put_error_response(conn, Error.http_status(kind))
    end
  end

  def before_send(%Plug.Conn{} = conn, _blueprint), do: conn

  defp put_error_response(conn, status) do
    conn = Plug.Conn.put_resp_header(conn, "cache-control", "private, no-cache, must-revalidate")

    if status == 200 or batch?(conn) do
      conn
    else
      # Absinthe.Plug calls send_resp/3 with 200 after this hook; a before_send callback
      # runs after the status is set, so it can replace it.
      Plug.Conn.register_before_send(conn, &%{&1 | status: status})
    end
  end

  defp batch?(%Plug.Conn{body_params: %{"_json" => queries}}) when is_list(queries), do: true
  defp batch?(%Plug.Conn{}), do: false
end
