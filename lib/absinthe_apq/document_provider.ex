defmodule AbsintheAPQ.DocumentProvider do
  @moduledoc """
  An `Absinthe.Plug.DocumentProvider` for Apollo Automatic Persisted Queries.

  Put it before `Absinthe.Plug.DocumentProvider.Default`, so requests without the
  `persistedQuery` extension still work:

      forward "/graphql", Absinthe.Plug,
        schema: MyAppWeb.Schema,
        document_providers: [AbsintheAPQ.DocumentProvider, Absinthe.Plug.DocumentProvider.Default]

  To pass options, give a `{module, options}` tuple, which `Absinthe.Plug` supports for
  every document provider:

      document_providers: [
        {AbsintheAPQ.DocumentProvider, max_query_bytes: 65_536},
        Absinthe.Plug.DocumentProvider.Default
      ]

  `Absinthe.Plug` does not validate document provider options when it starts, so this
  module checks them on each request and raises an `ArgumentError` for an unknown
  option. To build the options at runtime, use the `{module, function}` form of
  `:document_providers`, which `Absinthe.Plug` calls with its config on every request.

  ## Options

    * `:cache`: the `AbsintheAPQ.Cache` module, or a `{module, options}` tuple whose
      options are passed to its callbacks. Defaults to `AbsintheAPQ.Cache.ETS`, the
      store started with its default name.
    * `:enabled`: when `false`, every request with the `persistedQuery` extension gets
      the `PersistedQueryNotSupported` error (`PERSISTED_QUERY_NOT_SUPPORTED`), which
      makes Apollo Client stop sending hashes for the rest of the session and send full
      queries instead. Use it to turn APQ off while clients still send hashes: without
      this provider, a hash-only request gets `Absinthe.Plug`'s
      "No query document supplied" error, which Apollo Client does not retry. Defaults
      to `true`.
    * `:max_query_bytes`: the largest query, in bytes, that is stored. A larger query
      with a correct hash still runs, but is not stored, so its hash-only requests keep
      missing. Defaults to `32_768`.

  ## What it does with a request

    * No `persistedQuery` extension: `{:cont, request}`, so the next document provider
      handles the request.
    * Hash only, stored: runs the stored query.
    * Hash only, not stored, or the cache fails: the `PersistedQueryNotFound` error
      (`extensions.code` `PERSISTED_QUERY_NOT_FOUND`). Apollo Client then sends the
      hash and the query.
    * Hash and query: when the query hashes to the hash, runs the query, and stores it
      once it has passed validation. Otherwise the error
      `provided sha does not match query` (`PERSISTED_QUERY_HASH_MISMATCH`).
    * Any `persistedQuery` extension when `enabled: false`: the
      `PersistedQueryNotSupported` error (`PERSISTED_QUERY_NOT_SUPPORTED`).
    * A `version` other than `1`: the error `Unsupported persisted query version`
      (`PERSISTED_QUERY_UNSUPPORTED_VERSION`).
    * A `sha256Hash` that is not 64 lowercase hexadecimal characters: the error
      `PERSISTED_QUERY_INVALID_HASH`.

  The extensions may be a decoded map (a JSON `POST` body) or a JSON string (the
  `extensions` parameter of a `GET` request).

  Subscriptions over `Absinthe.Phoenix` sockets do not go through document providers,
  so APQ does not apply to them.
  """

  @behaviour Absinthe.Plug.DocumentProvider

  alias Absinthe.Phase.Document.Execution.Resolution
  alias Absinthe.Phase.Document.Validation
  alias AbsintheAPQ.CacheCall
  alias AbsintheAPQ.Phase

  @default_cache AbsintheAPQ.Cache.ETS
  @default_max_query_bytes 32_768
  @hash_length 64

  @impl Absinthe.Plug.DocumentProvider
  @spec process(Absinthe.Plug.Request.Query.t(), keyword()) ::
          Absinthe.Plug.DocumentProvider.result()
  def process(%{params: params, document: document} = request, opts)
      when is_nil(document) or is_binary(document) do
    case persisted_query(params) do
      :none -> {:cont, request}
      {:ok, persisted_query} -> process_persisted(request, persisted_query, config(opts))
    end
  end

  def process(request, _opts), do: {:cont, request}

  @impl Absinthe.Plug.DocumentProvider
  @spec pipeline(Absinthe.Plug.Request.Query.t()) :: Absinthe.Pipeline.t()
  def pipeline(%{document_provider_key: {:apq_error, kind}}) do
    # Resolution does nothing without an operation. It is here because the batch runner
    # of Absinthe.Plug splits every pipeline at that phase.
    [{Phase.Error, kind: kind}, Resolution, Absinthe.Phase.Document.Result]
  end

  def pipeline(%{document_provider_key: {:apq_store, hash}} = request) do
    %{document: query, pipeline: as_configured, document_provider: {_module, opts}} = request
    %{cache: cache} = config(opts)
    store = {Phase.Store, hash: hash, query: query, cache: cache}
    insert_store(as_configured, store)
  end

  def pipeline(%{pipeline: as_configured}), do: as_configured

  defp process_persisted(request, _persisted_query, %{enabled: false}) do
    :telemetry.execute([:absinthe_apq, :not_supported], %{}, %{})
    error(request, :not_supported)
  end

  defp process_persisted(request, persisted_query, config) do
    case parse(persisted_query) do
      {:ok, hash} -> handle(request, hash, config)
      {:error, reason} -> invalid_request(request, reason)
    end
  end

  defp handle(%{document: query} = request, hash, config) when query in [nil, ""] do
    case CacheCall.get(config.cache, hash) do
      {:ok, stored_query} ->
        measurements = %{query_bytes: byte_size(stored_query)}
        :telemetry.execute([:absinthe_apq, :hit], measurements, %{hash: hash})
        found = %{request | document: stored_query, document_provider_key: :apq_hit}
        {:halt, found}

      :miss ->
        :telemetry.execute([:absinthe_apq, :miss], %{}, %{hash: hash})
        error(request, :not_found)

      {:error, reason} ->
        CacheCall.report_error(:get, hash, reason)
        error(request, :not_found)
    end
  end

  defp handle(%{document: query} = request, hash, config) do
    query_bytes = byte_size(query)
    measurements = %{query_bytes: query_bytes}

    cond do
      AbsintheAPQ.hash(query) != hash ->
        :telemetry.execute([:absinthe_apq, :hash_mismatch], measurements, %{hash: hash})
        error(request, :hash_mismatch)

      query_bytes > config.max_query_bytes ->
        metadata = %{hash: hash, max_query_bytes: config.max_query_bytes}
        :telemetry.execute([:absinthe_apq, :query_too_large], measurements, metadata)
        {:halt, %{request | document_provider_key: :apq_unstored}}

      true ->
        {:halt, %{request | document_provider_key: {:apq_store, hash}}}
    end
  end

  defp invalid_request(request, reason) do
    :telemetry.execute([:absinthe_apq, :invalid_request], %{}, %{reason: reason})
    error(request, reason)
  end

  # Absinthe.Plug answers "No query document supplied" when the document is nil, so a
  # hash-only request gets an empty document. Phase.Error ignores it.
  defp error(%{document: document} = request, kind) do
    document = document || ""
    failed = %{request | document: document, document_provider_key: {:apq_error, kind}}
    {:halt, failed}
  end

  defp persisted_query(%{"extensions" => extensions}) when is_binary(extensions) do
    case JSON.decode(extensions) do
      {:ok, %{"persistedQuery" => persisted_query}} -> {:ok, persisted_query}
      _not_persisted -> :none
    end
  end

  defp persisted_query(%{"extensions" => %{"persistedQuery" => persisted_query}}),
    do: {:ok, persisted_query}

  defp persisted_query(_params), do: :none

  defp parse(%{"version" => 1, "sha256Hash" => hash}) do
    if hash?(hash) do
      {:ok, hash}
    else
      {:error, :invalid_hash}
    end
  end

  defp parse(%{"version" => 1}), do: {:error, :invalid_hash}
  defp parse(_persisted_query), do: {:error, :unsupported_version}

  defp hash?(hash) when is_binary(hash) and byte_size(hash) == @hash_length,
    do: lowercase_hex?(hash)

  defp hash?(_hash), do: false

  defp lowercase_hex?(<<char, rest::binary>>) when char in ?0..?9 or char in ?a..?f,
    do: lowercase_hex?(rest)

  defp lowercase_hex?(<<>>), do: true
  defp lowercase_hex?(_rest), do: false

  # After Validation.Result, which skips the rest of the pipeline when the document has
  # errors, so only valid queries are stored. A custom pipeline without that phase
  # stores the query before it runs.
  defp insert_store(pipeline, store) do
    if Enum.any?(List.flatten(pipeline), &validation_result?/1) do
      Absinthe.Pipeline.insert_after(pipeline, Validation.Result, store)
    else
      [store | pipeline]
    end
  end

  defp validation_result?({Validation.Result, _options}), do: true
  defp validation_result?(Validation.Result), do: true
  defp validation_result?(_phase), do: false

  defp config(opts) do
    opts =
      Keyword.validate!(opts,
        cache: @default_cache,
        enabled: true,
        max_query_bytes: @default_max_query_bytes
      )

    enabled = Keyword.fetch!(opts, :enabled)

    if not is_boolean(enabled) do
      raise ArgumentError, ":enabled must be a boolean, got: #{inspect(enabled)}"
    end

    max_query_bytes = Keyword.fetch!(opts, :max_query_bytes)

    if not (is_integer(max_query_bytes) and max_query_bytes > 0) do
      raise ArgumentError,
            ":max_query_bytes must be a positive integer, got: #{inspect(max_query_bytes)}"
    end

    cache = opts |> Keyword.fetch!(:cache) |> cache()
    %{cache: cache, enabled: enabled, max_query_bytes: max_query_bytes}
  end

  defp cache({module, cache_opts}) when is_atom(module) and is_list(cache_opts),
    do: {module, cache_opts}

  defp cache(module) when is_atom(module), do: {module, []}

  defp cache(other) do
    raise ArgumentError,
          ":cache must be a module or a {module, options} tuple, got: #{inspect(other)}"
  end
end
