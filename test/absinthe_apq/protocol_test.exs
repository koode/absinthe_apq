defmodule AbsintheAPQ.ProtocolTest do
  # One describe block per rule in docs/PROTOCOL.md, each through Plug.Parsers and
  # Absinthe.Plug. Not async: telemetry handlers see the events of every test process.
  use ExUnit.Case, async: false

  alias AbsintheAPQ.Cache.ETS
  alias AbsintheAPQ.DocumentProvider
  alias AbsintheAPQ.Test.ApolloClient
  alias AbsintheAPQ.Test.HTTP
  alias AbsintheAPQ.Test.Telemetry

  @query "query Hello { hello }"
  @hash AbsintheAPQ.hash(@query)
  @no_cache "private, no-cache, must-revalidate"

  setup do
    Telemetry.attach()
    name = :"apq_protocol_#{System.unique_integer([:positive])}"
    start_supervised!({ETS, name: name})
    provider = {DocumentProvider, cache: {ETS, name: name}}

    plug_opts = [
      document_providers: [provider, Absinthe.Plug.DocumentProvider.Default],
      before_send: {AbsintheAPQ, :before_send}
    ]

    %{name: name, plug_opts: plug_opts}
  end

  defp hashed(hash \\ @hash, version \\ 1), do: %{"extensions" => HTTP.extensions(hash, version)}
  defp registration(query \\ @query), do: Map.put(hashed(AbsintheAPQ.hash(query)), "query", query)

  defp store!(name, query \\ @query),
    do: :ok = ETS.put(AbsintheAPQ.hash(query), query, name: name)

  defp error(message, code), do: %{"message" => message, "extensions" => %{"code" => code}}

  describe "P1: the hash goes in extensions.persistedQuery, without a query" do
    test "a POST body with a decoded extension map runs the stored query",
         %{name: name} = context do
      store!(name)
      conn = HTTP.post(hashed(), context.plug_opts)

      assert conn.status == 200
      assert HTTP.json(conn) == %{"data" => %{"hello" => "Hello, world"}}
    end

    test "variables and operationName apply to the stored query", %{name: name} = context do
      query = "query Greet($name: String) { hello(name: $name) } query Other { hello }"
      store!(name, query)

      body =
        Map.merge(hashed(AbsintheAPQ.hash(query)), %{
          "operationName" => "Greet",
          "variables" => %{"name" => "Abby"}
        })

      conn = HTTP.post(body, context.plug_opts)

      assert HTTP.json(conn) == %{"data" => %{"hello" => "Hello, Abby"}}
    end
  end

  describe "P2: a GET request sends extensions as a JSON string" do
    test "a hash-only GET runs the stored query", %{name: name} = context do
      store!(name)
      conn = HTTP.get(Map.put(hashed(), "variables", %{}), context.plug_opts)

      assert conn.status == 200
      assert HTTP.json(conn) == %{"data" => %{"hello" => "Hello, world"}}
    end

    test "a hash-only GET of an unknown hash gets the not-found error", context do
      conn = HTTP.get(hashed(), context.plug_opts)

      assert conn.status == 200

      assert HTTP.json(conn) == %{
               "errors" => [error("PersistedQueryNotFound", "PERSISTED_QUERY_NOT_FOUND")]
             }
    end
  end

  describe "P3: the hash is the lowercase hex SHA-256 of the exact query text" do
    test "matches the hash in the Apollo Server documentation" do
      assert AbsintheAPQ.hash("{__typename}") ==
               "ecf4edb46db40b5132295c0291d62fb65d6759a9eedfa4d5d612dd5ec54a6b38"
    end

    test "a different whitespace is a different query", context do
      body = Map.put(hashed(), "query", "query Hello {  hello }")
      conn = HTTP.post(body, context.plug_opts)

      assert HTTP.json(conn) == %{
               "errors" => [
                 error("provided sha does not match query", "PERSISTED_QUERY_HASH_MISMATCH")
               ]
             }
    end

    test "an uppercase or malformed hash gets the invalid hash error with status 400", context do
      for hash <- [String.upcase(@hash), "abc"] do
        conn = HTTP.post(Map.put(hashed(hash), "query", @query), context.plug_opts)

        assert conn.status == 400

        assert [%{"extensions" => %{"code" => "PERSISTED_QUERY_INVALID_HASH"}}] =
                 HTTP.json(conn)["errors"]
      end
    end
  end

  describe "P4: a known hash runs the stored query" do
    test "and reports a hit", %{name: name} = context do
      store!(name)
      conn = HTTP.post(hashed(), context.plug_opts)

      assert HTTP.json(conn) == %{"data" => %{"hello" => "Hello, world"}}
      assert_received {:telemetry, [:absinthe_apq, :hit], _measurements, %{hash: @hash}}
    end
  end

  describe "P5: an unknown hash gets PersistedQueryNotFound with status 200" do
    test "with the message and the code Apollo Client matches, and nothing else", context do
      conn = HTTP.post(hashed(), context.plug_opts)

      assert conn.status == 200

      assert HTTP.json(conn) == %{
               "errors" => [error("PersistedQueryNotFound", "PERSISTED_QUERY_NOT_FOUND")]
             }

      assert_received {:telemetry, [:absinthe_apq, :miss], _measurements, %{hash: @hash}}
    end
  end

  describe "P6: APQ error responses are not cacheable" do
    test "the before_send hook sets cache-control: private, no-cache, must-revalidate", context do
      conn = HTTP.post(hashed(), context.plug_opts)
      assert Plug.Conn.get_resp_header(conn, "cache-control") == [@no_cache]
    end

    test "without the hook, Plug's default private cache-control stays", context do
      plug_opts = Keyword.delete(context.plug_opts, :before_send)
      conn = HTTP.get(hashed(), plug_opts)

      assert conn.status == 200

      assert Plug.Conn.get_resp_header(conn, "cache-control") == [
               "max-age=0, private, must-revalidate"
             ]
    end

    test "a successful response keeps its headers", %{name: name} = context do
      store!(name)
      conn = HTTP.get(hashed(), context.plug_opts)

      assert Plug.Conn.get_resp_header(conn, "cache-control") == [
               "max-age=0, private, must-revalidate"
             ]
    end
  end

  describe "P7: a hash with its query runs the query and stores it once it is valid" do
    test "the next hash-only request is a hit", %{name: name} = context do
      conn = HTTP.post(registration(), context.plug_opts)

      assert HTTP.json(conn) == %{"data" => %{"hello" => "Hello, world"}}
      assert ETS.get(@hash, name: name) == {:ok, @query}
      assert_received {:telemetry, [:absinthe_apq, :store], %{query_bytes: 21}, %{hash: @hash}}

      conn = HTTP.post(hashed(), context.plug_opts)
      assert HTTP.json(conn) == %{"data" => %{"hello" => "Hello, world"}}
    end

    test "a query that fails validation is not stored", %{name: name} = context do
      query = "{ unknownField }"
      conn = HTTP.post(registration(query), context.plug_opts)

      assert [%{"message" => message}] = HTTP.json(conn)["errors"]
      assert message =~ "unknownField"
      assert ETS.get(AbsintheAPQ.hash(query), name: name) == :miss
      refute_received {:telemetry, [:absinthe_apq, :store], _measurements, _metadata}
    end

    test "a query that does not parse is not stored", %{name: name} = context do
      query = "{ hello "
      conn = HTTP.post(registration(query), context.plug_opts)

      assert [%{"message" => _message}] = HTTP.json(conn)["errors"]
      assert ETS.get(AbsintheAPQ.hash(query), name: name) == :miss
    end

    test "a store error still runs the query", context do
      provider = {DocumentProvider, cache: AbsintheAPQ.Test.FailingCache}
      plug_opts = Keyword.put(context.plug_opts, :document_providers, [provider])
      conn = HTTP.post(registration(), plug_opts)

      assert HTTP.json(conn) == %{"data" => %{"hello" => "Hello, world"}}

      assert_received {:telemetry, [:absinthe_apq, :cache_error], _measurements,
                       %{operation: :put, reason: :down}}
    end

    test "a query over :max_query_bytes runs but is not stored", %{name: name} = context do
      provider = {DocumentProvider, cache: {ETS, name: name}, max_query_bytes: 10}
      plug_opts = Keyword.put(context.plug_opts, :document_providers, [provider])
      conn = HTTP.post(registration(), plug_opts)

      assert HTTP.json(conn) == %{"data" => %{"hello" => "Hello, world"}}
      assert ETS.get(@hash, name: name) == :miss
    end
  end

  describe "P8: a hash that does not match its query is rejected" do
    test "with status 400, and nothing is stored or run", %{name: name} = context do
      body = Map.put(hashed(), "query", "query Hello { hello(name: \"Sam\") }")
      conn = HTTP.post(body, context.plug_opts)

      assert conn.status == 400
      assert Plug.Conn.get_resp_header(conn, "cache-control") == [@no_cache]

      assert HTTP.json(conn) == %{
               "errors" => [
                 error("provided sha does not match query", "PERSISTED_QUERY_HASH_MISMATCH")
               ]
             }

      assert ETS.get(@hash, name: name) == :miss
    end
  end

  describe "P9: a version other than 1 is rejected" do
    test "with status 400", context do
      conn = HTTP.post(hashed(@hash, 2), context.plug_opts)

      assert conn.status == 400

      assert HTTP.json(conn) == %{
               "errors" => [
                 error(
                   "Unsupported persisted query version",
                   "PERSISTED_QUERY_UNSUPPORTED_VERSION"
                 )
               ]
             }
    end
  end

  describe "P10: with APQ turned off, PersistedQueryNotSupported" do
    test "gets status 200, and Apollo Client sends the full query without the hash",
         %{name: name} = context do
      provider = {DocumentProvider, cache: {ETS, name: name}, enabled: false}

      plug_opts =
        Keyword.put(context.plug_opts, :document_providers, [
          provider,
          Absinthe.Plug.DocumentProvider.Default
        ])

      conn = HTTP.post(hashed(), plug_opts)
      assert conn.status == 200
      assert Plug.Conn.get_resp_header(conn, "cache-control") == [@no_cache]

      assert HTTP.json(conn) == %{
               "errors" => [error("PersistedQueryNotSupported", "PERSISTED_QUERY_NOT_SUPPORTED")]
             }

      assert {result, requests} = ApolloClient.run(@query, plug_opts)
      assert result == %{"data" => %{"hello" => "Hello, world"}}
      assert requests == [{"POST", :hash_only, 200}, {"POST", :query_only, 200}]
    end
  end

  describe "P11: a request without the extension is an ordinary request" do
    test "the next document provider runs it", context do
      conn = HTTP.post(%{"query" => @query}, context.plug_opts)
      assert HTTP.json(conn) == %{"data" => %{"hello" => "Hello, world"}}
    end
  end

  describe "P12: Apollo Client retries once with the full query on not-found" do
    test "POST: miss, then hash and query, then hit", context do
      assert {result, requests} = ApolloClient.run(@query, context.plug_opts)
      assert result == %{"data" => %{"hello" => "Hello, world"}}
      assert requests == [{"POST", :hash_only, 200}, {"POST", :hash_and_query, 200}]

      assert {result, requests} = ApolloClient.run(@query, context.plug_opts)
      assert result == %{"data" => %{"hello" => "Hello, world"}}
      assert requests == [{"POST", :hash_only, 200}]
    end

    test "useGETForHashedQueries: GET miss, POST hash and query, then GET hit", context do
      client_opts = [use_get_for_hashed_queries: true]

      assert {_result, requests} = ApolloClient.run(@query, context.plug_opts, client_opts)
      assert requests == [{"GET", :hash_only, 200}, {"POST", :hash_and_query, 200}]

      assert {result, requests} = ApolloClient.run(@query, context.plug_opts, client_opts)
      assert result == %{"data" => %{"hello" => "Hello, world"}}
      assert requests == [{"GET", :hash_only, 200}]
    end

    test "other APQ errors are not retried", context do
      body = Map.put(hashed(), "query", "{ hello }")
      conn = HTTP.post(body, context.plug_opts)
      errors = HTTP.json(conn)["errors"]

      refute Enum.any?(
               errors,
               &(&1["message"] in ["PersistedQueryNotFound", "PersistedQueryNotSupported"])
             )

      refute Enum.any?(
               errors,
               &(&1["extensions"]["code"] in [
                   "PERSISTED_QUERY_NOT_FOUND",
                   "PERSISTED_QUERY_NOT_SUPPORTED"
                 ])
             )
    end
  end

  describe "P13: a mutation never runs over GET" do
    test "a stored mutation sent hash-only over GET gets status 405", %{name: name} = context do
      mutation = "mutation { ping }"
      store!(name, mutation)
      conn = HTTP.get(hashed(AbsintheAPQ.hash(mutation)), context.plug_opts)

      assert conn.status == 405
    end

    test "the same mutation over POST runs", %{name: name} = context do
      mutation = "mutation { ping }"
      store!(name, mutation)
      conn = HTTP.post(hashed(AbsintheAPQ.hash(mutation)), context.plug_opts)

      assert HTTP.json(conn) == %{"data" => %{"ping" => "pong"}}
    end
  end

  describe "P14: each operation in a batch is handled on its own" do
    test "a hit, a miss and a registration in one batch keep status 200",
         %{name: name} = context do
      store!(name)
      other = "query Other { hello(name: \"Olivia\") }"
      batch = [hashed(), hashed(AbsintheAPQ.hash("{ unknown }")), registration(other)]
      conn = HTTP.post(batch, context.plug_opts)

      assert conn.status == 200

      assert [
               %{"payload" => %{"data" => %{"hello" => "Hello, world"}}},
               %{"payload" => %{"errors" => [not_found]}},
               %{"payload" => %{"data" => %{"hello" => "Hello, Olivia"}}}
             ] = HTTP.json(conn)

      assert not_found == error("PersistedQueryNotFound", "PERSISTED_QUERY_NOT_FOUND")
      assert ETS.get(AbsintheAPQ.hash(other), name: name) == {:ok, other}
    end
  end

  describe "P15: the built-in store is bounded" do
    test "an evicted query is registered again by the client", %{name: name} = context do
      stop_supervised!({ETS, name})
      start_supervised!({ETS, name: name, max_entries: 1})

      {_result, _requests} = ApolloClient.run(@query, context.plug_opts)
      {_result, _requests} = ApolloClient.run("query Other { hello }", context.plug_opts)
      assert ETS.size(name: name) == 1

      assert {result, requests} = ApolloClient.run(@query, context.plug_opts)
      assert result == %{"data" => %{"hello" => "Hello, world"}}
      assert requests == [{"POST", :hash_only, 200}, {"POST", :hash_and_query, 200}]
    end
  end

  describe "P16: a hash can never be bound to another query" do
    test "a stored query that does not hash to its key does not run", context do
      cache = {AbsintheAPQ.Test.FixedCache, query: "query Hello { hello(name: \"intruder\") }"}
      provider = {DocumentProvider, cache: cache}
      plug_opts = Keyword.put(context.plug_opts, :document_providers, [provider])
      conn = HTTP.post(hashed(), plug_opts)

      assert HTTP.json(conn) == %{
               "errors" => [error("PersistedQueryNotFound", "PERSISTED_QUERY_NOT_FOUND")]
             }
    end

    test "registering another query under a stored hash fails", %{name: name} = context do
      store!(name)
      body = Map.put(hashed(), "query", "query Hello { hello(name: \"intruder\") }")
      conn = HTTP.post(body, context.plug_opts)

      assert conn.status == 400
      assert ETS.get(@hash, name: name) == {:ok, @query}
    end
  end
end
