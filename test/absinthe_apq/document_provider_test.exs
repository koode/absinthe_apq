defmodule AbsintheAPQ.DocumentProviderTest do
  # Not async: telemetry handlers see the events of every test process.
  use ExUnit.Case, async: false

  alias Absinthe.Phase.Document.Validation
  alias Absinthe.Plug.Request.Query
  alias AbsintheAPQ.Cache.ETS
  alias AbsintheAPQ.DocumentProvider
  alias AbsintheAPQ.Phase
  alias AbsintheAPQ.Test

  @query "{ hello }"
  @hash AbsintheAPQ.hash(@query)

  setup do
    Test.Telemetry.attach()
    name = :"apq_provider_#{System.unique_integer([:positive])}"
    start_supervised!({ETS, name: name})
    %{opts: [cache: {ETS, name: name}], name: name}
  end

  defp request(params, document \\ nil) do
    %Query{
      document: document,
      operation_name: nil,
      root_value: %{},
      variables: %{},
      raw_options: [],
      params: params
    }
  end

  defp hashed(hash \\ @hash, version \\ 1) do
    %{"extensions" => Test.HTTP.extensions(hash, version)}
  end

  defp with_query(params, query \\ @query), do: Map.put(params, "query", query)

  describe "process/2 without the persistedQuery extension" do
    test "falls through to the next document provider", %{opts: opts} do
      request = request(%{"query" => @query}, @query)
      assert DocumentProvider.process(request, opts) == {:cont, request}
    end

    test "falls through for other extensions, decoded or as a JSON string", %{opts: opts} do
      for extensions <- [%{"tracing" => true}, ~s({"tracing":true}), "not json", ~s("a string")] do
        request = request(%{"extensions" => extensions}, @query)
        assert DocumentProvider.process(request, opts) == {:cont, request}
      end
    end

    test "falls through when an earlier provider set a compiled document", %{opts: opts} do
      request = request(hashed(), %Absinthe.Blueprint{})
      assert DocumentProvider.process(request, opts) == {:cont, request}
    end
  end

  describe "process/2 with a hash only" do
    test "a stored hash is a hit and runs the stored query", %{opts: opts, name: name} do
      :ok = ETS.put(@hash, @query, name: name)

      assert {:halt, request} = DocumentProvider.process(request(hashed()), opts)
      assert request.document == @query
      assert request.document_provider_key == :apq_hit
      assert DocumentProvider.pipeline(%{request | pipeline: [:configured]}) == [:configured]

      assert_received {:telemetry, [:absinthe_apq, :hit], %{query_bytes: 9}, %{hash: @hash}}
    end

    test "an unknown hash is a miss and gets the not-found error", %{opts: opts} do
      assert {:halt, request} = DocumentProvider.process(request(hashed()), opts)
      assert request.document == ""
      assert request.document_provider_key == {:apq_error, :not_found}

      assert DocumentProvider.pipeline(request) == [
               {Phase.Error, kind: :not_found},
               Absinthe.Phase.Document.Execution.Resolution,
               Absinthe.Phase.Document.Result
             ]

      assert_received {:telemetry, [:absinthe_apq, :miss], %{}, %{hash: @hash}}
    end

    test "an empty query counts as no query", %{opts: opts} do
      assert {:halt, request} = DocumentProvider.process(request(hashed(), ""), opts)
      assert request.document_provider_key == {:apq_error, :not_found}
    end

    test "reads extensions sent as a JSON string, as in a GET request", %{opts: opts, name: name} do
      :ok = ETS.put(@hash, @query, name: name)
      extensions = Jason.encode!(Test.HTTP.extensions(@hash))

      assert {:halt, request} =
               DocumentProvider.process(request(%{"extensions" => extensions}), opts)

      assert request.document == @query
    end
  end

  describe "process/2 with a hash and a query" do
    test "a matching hash runs the query and stores it after validation", %{opts: opts} do
      assert {:halt, request} =
               DocumentProvider.process(request(with_query(hashed()), @query), opts)

      assert request.document == @query
      assert request.document_provider_key == {:apq_store, @hash}

      configured = Absinthe.Pipeline.for_document(Test.Schema)
      request = %{request | pipeline: configured, document_provider: {DocumentProvider, opts}}
      pipeline = DocumentProvider.pipeline(request)

      store = {Phase.Store, hash: @hash, query: @query, cache: Keyword.fetch!(opts, :cache)}
      position = Enum.find_index(pipeline, &match?({Validation.Result, _options}, &1))
      assert Enum.at(pipeline, position + 1) == store
      assert pipeline -- [store] == configured
    end

    test "a pipeline without Validation.Result stores before it runs", %{opts: opts} do
      {:halt, request} = DocumentProvider.process(request(with_query(hashed()), @query), opts)

      request = %{
        request
        | pipeline: [Absinthe.Phase.Parse],
          document_provider: {DocumentProvider, opts}
      }

      assert [{Phase.Store, _store_opts}, Absinthe.Phase.Parse] =
               DocumentProvider.pipeline(request)
    end

    test "a hash that does not match gets the mismatch error", %{opts: opts} do
      other_hash = AbsintheAPQ.hash("{ other }")
      params = with_query(hashed(other_hash))

      assert {:halt, request} = DocumentProvider.process(request(params, @query), opts)
      assert request.document == @query
      assert request.document_provider_key == {:apq_error, :hash_mismatch}

      assert_received {:telemetry, [:absinthe_apq, :hash_mismatch], %{query_bytes: 9},
                       %{hash: ^other_hash}}
    end

    test "a query over :max_query_bytes runs but is not stored", %{opts: opts} do
      opts = Keyword.put(opts, :max_query_bytes, 8)

      assert {:halt, request} =
               DocumentProvider.process(request(with_query(hashed()), @query), opts)

      assert request.document == @query
      assert request.document_provider_key == :apq_unstored
      assert DocumentProvider.pipeline(%{request | pipeline: [:configured]}) == [:configured]

      assert_received {:telemetry, [:absinthe_apq, :query_too_large], %{query_bytes: 9},
                       %{hash: @hash, max_query_bytes: 8}}
    end

    test "a query of exactly :max_query_bytes is stored", %{opts: opts} do
      opts = Keyword.put(opts, :max_query_bytes, byte_size(@query))

      assert {:halt, request} =
               DocumentProvider.process(request(with_query(hashed()), @query), opts)

      assert request.document_provider_key == {:apq_store, @hash}
    end
  end

  describe "process/2 with an invalid persistedQuery extension" do
    test "a version other than 1 gets the unsupported version error", %{opts: opts} do
      for version <- [2, 0, "1", nil] do
        assert {:halt, request} = DocumentProvider.process(request(hashed(@hash, version)), opts)
        assert request.document_provider_key == {:apq_error, :unsupported_version}
      end

      for persisted_query <- [%{"sha256Hash" => @hash}, "not a map", nil] do
        params = %{"extensions" => %{"persistedQuery" => persisted_query}}
        assert {:halt, request} = DocumentProvider.process(request(params), opts)
        assert request.document_provider_key == {:apq_error, :unsupported_version}
      end

      assert_received {:telemetry, [:absinthe_apq, :invalid_request], %{},
                       %{reason: :unsupported_version}}
    end

    test "a hash that is not 64 lowercase hexadecimal characters gets the invalid hash error",
         %{opts: opts} do
      for hash <- [String.upcase(@hash), String.slice(@hash, 1..-1//1), @hash <> "0", "", 42] do
        assert {:halt, request} =
                 DocumentProvider.process(request(with_query(hashed(hash))), opts)

        assert request.document_provider_key == {:apq_error, :invalid_hash}
      end

      params = %{"extensions" => %{"persistedQuery" => %{"version" => 1}}}
      assert {:halt, request} = DocumentProvider.process(request(params), opts)
      assert request.document_provider_key == {:apq_error, :invalid_hash}

      assert_received {:telemetry, [:absinthe_apq, :invalid_request], %{},
                       %{reason: :invalid_hash}}
    end
  end

  describe "process/2 fails closed on cache errors" do
    test "an error from get/2 is the not-found error" do
      opts = [cache: Test.FailingCache]

      assert {:halt, request} = DocumentProvider.process(request(hashed()), opts)
      assert request.document_provider_key == {:apq_error, :not_found}

      assert_received {:telemetry, [:absinthe_apq, :cache_error], %{},
                       %{hash: @hash, operation: :get, reason: :down}}
    end

    test "a raising get/2 is the not-found error" do
      assert {:halt, request} =
               DocumentProvider.process(request(hashed()), cache: Test.RaisingCache)

      assert request.document_provider_key == {:apq_error, :not_found}

      assert_received {:telemetry, [:absinthe_apq, :cache_error], %{},
                       %{operation: :get, reason: {:exception, %RuntimeError{}}}}
    end

    test "a get/2 answer outside the behaviour is the not-found error" do
      for answer <- [nil, {:ok, nil}, {:ok, 42}, :error] do
        opts = [cache: {Test.UnexpectedCache, get: answer}]
        assert {:halt, request} = DocumentProvider.process(request(hashed()), opts)
        assert request.document_provider_key == {:apq_error, :not_found}
      end
    end

    test "a stored query that does not hash to its key never runs" do
      opts = [cache: {Test.FixedCache, query: "{ hello(name: \"intruder\") }"}]

      assert {:halt, request} = DocumentProvider.process(request(hashed()), opts)
      assert request.document == ""
      assert request.document_provider_key == {:apq_error, :not_found}

      assert_received {:telemetry, [:absinthe_apq, :cache_error], %{},
                       %{operation: :get, reason: :stored_query_hash_mismatch}}
    end
  end

  describe "process/2 with enabled: false" do
    test "every persistedQuery extension gets the not-supported error", %{opts: opts} do
      opts = Keyword.put(opts, :enabled, false)

      for params <- [hashed(), with_query(hashed()), hashed(@hash, 2)] do
        assert {:halt, request} = DocumentProvider.process(request(params), opts)
        assert request.document_provider_key == {:apq_error, :not_supported}
      end

      request = request(%{"query" => @query}, @query)
      assert DocumentProvider.process(request, opts) == {:cont, request}

      assert_received {:telemetry, [:absinthe_apq, :not_supported], %{}, %{}}
    end
  end

  describe "options" do
    test "an unknown option raises" do
      assert_raise ArgumentError, ~r/unknown keys \[:max_size\]/, fn ->
        DocumentProvider.process(request(hashed()), max_size: 1)
      end
    end

    test "invalid option values raise" do
      assert_raise ArgumentError, ~r/:max_query_bytes must be a positive integer/, fn ->
        DocumentProvider.process(request(hashed()), max_query_bytes: 0)
      end

      assert_raise ArgumentError, ~r/:enabled must be a boolean/, fn ->
        DocumentProvider.process(request(hashed()), enabled: "yes")
      end

      assert_raise ArgumentError, ~r/:cache must be a module/, fn ->
        DocumentProvider.process(request(hashed()), cache: "ets")
      end
    end
  end
end
