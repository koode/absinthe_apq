defmodule AbsintheAPQ.Test.ApolloClient do
  @moduledoc false

  # Replays what PersistedQueryLink in @apollo/client 4 (link/persisted-queries) does for
  # one operation: send the hash only (as GET with useGETForHashedQueries, else POST);
  # when an error has the message "PersistedQueryNotFound" or the code
  # "PERSISTED_QUERY_NOT_FOUND", in a 2xx body or in the JSON body of a non-2xx response,
  # send the hash and the query once more, always as POST. On "PersistedQueryNotSupported"
  # or "PERSISTED_QUERY_NOT_SUPPORTED" it sends the query without the extension.

  alias AbsintheAPQ.Test.HTTP

  @doc """
  Runs `query` and returns `{result, requests}`, where `requests` lists each request as
  `{method, :hash_only | :hash_and_query | :query_only, status}`.
  """
  @spec run(String.t(), keyword(), keyword()) :: {map(), [tuple()]}
  def run(query, plug_opts, client_opts \\ []) do
    hash = AbsintheAPQ.hash(query)
    extensions = HTTP.extensions(hash)
    hashed = %{"extensions" => extensions}

    first_conn =
      if Keyword.get(client_opts, :use_get_for_hashed_queries, false) do
        HTTP.get(hashed, plug_opts)
      else
        HTTP.post(hashed, plug_opts)
      end

    first = {first_conn.method, :hash_only, first_conn.status}
    result = HTTP.json(first_conn)

    case retry(result) do
      :not_found ->
        body = %{"query" => query, "extensions" => extensions}
        retry_conn = HTTP.post(body, plug_opts)
        retried = {"POST", :hash_and_query, retry_conn.status}
        {HTTP.json(retry_conn), [first, retried]}

      :not_supported ->
        retry_conn = HTTP.post(%{"query" => query}, plug_opts)
        retried = {"POST", :query_only, retry_conn.status}
        {HTTP.json(retry_conn), [first, retried]}

      :none ->
        {result, [first]}
    end
  end

  defp retry(%{"errors" => errors}) when is_list(errors) do
    cond do
      Enum.any?(
        errors,
        &matches?(&1, "PersistedQueryNotSupported", "PERSISTED_QUERY_NOT_SUPPORTED")
      ) ->
        :not_supported

      Enum.any?(errors, &matches?(&1, "PersistedQueryNotFound", "PERSISTED_QUERY_NOT_FOUND")) ->
        :not_found

      true ->
        :none
    end
  end

  defp retry(_result), do: :none

  defp matches?(%{"message" => message}, message, _code), do: true
  defp matches?(%{"extensions" => %{"code" => code}}, _message, code), do: true
  defp matches?(_error, _message, _code), do: false
end
