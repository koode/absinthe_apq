defmodule AbsintheAPQ.Test.HTTP do
  @moduledoc false

  # Sends requests through Plug.Parsers and Absinthe.Plug, as a Phoenix endpoint would.

  import Plug.Conn
  import Plug.Test

  alias AbsintheAPQ.Test.Schema

  @parsers Plug.Parsers.init(parsers: [:urlencoded, :json], pass: ["*/*"], json_decoder: Jason)

  @doc "Sends `body` as a JSON POST request."
  @spec post(map() | [map()], keyword()) :: Plug.Conn.t()
  def post(body, plug_opts) do
    json = Jason.encode!(body)

    :post
    |> conn("/graphql", json)
    |> put_req_header("content-type", "application/json")
    |> run(plug_opts)
  end

  @doc "Sends `params` as the query string of a GET request, with JSON-encoded extensions."
  @spec get(map(), keyword()) :: Plug.Conn.t()
  def get(params, plug_opts) do
    query_string = params |> Map.new(&encode_param/1) |> URI.encode_query()
    :get |> conn("/graphql?" <> query_string) |> run(plug_opts)
  end

  @doc "The decoded JSON body of a response."
  @spec json(Plug.Conn.t()) :: term()
  def json(conn), do: Jason.decode!(conn.resp_body)

  @doc "The extensions of an APQ request."
  @spec extensions(String.t(), term()) :: map()
  def extensions(hash, version \\ 1) do
    persisted_query = %{"version" => version, "sha256Hash" => hash}
    %{"persistedQuery" => persisted_query}
  end

  defp run(conn, plug_opts) do
    config = [schema: Schema] |> Keyword.merge(plug_opts) |> Absinthe.Plug.init()
    conn |> Plug.Parsers.call(@parsers) |> Absinthe.Plug.call(config)
  end

  defp encode_param({key, value}) when is_map(value), do: {key, Jason.encode!(value)}
  defp encode_param({key, value}), do: {key, value}
end
