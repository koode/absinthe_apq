defmodule AbsintheAPQ.CacheCall do
  @moduledoc false

  # Calls the configured AbsintheAPQ.Cache and turns everything that is not a valid
  # answer (an unknown return value, a raise, an exit) into {:error, reason}, so the
  # document provider can fail closed.

  @type cache :: {module(), keyword()}

  @spec get(cache(), String.t()) :: {:ok, String.t()} | :miss | {:error, term()}
  def get({module, opts}, hash) do
    case guarded(fn -> module.get(hash, opts) end) do
      {:ok, query} when is_binary(query) -> verified(query, hash)
      :miss -> :miss
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_return, other}}
    end
  end

  @spec put(cache(), String.t(), String.t()) :: :ok | {:error, term()}
  def put({module, opts}, hash, query) do
    case guarded(fn -> module.put(hash, query, opts) end) do
      :ok -> :ok
      {:error, reason} -> {:error, reason}
      other -> {:error, {:invalid_return, other}}
    end
  end

  @spec report_error(:get | :put, String.t(), term()) :: :ok
  def report_error(operation, hash, reason) do
    metadata = %{hash: hash, operation: operation, reason: reason}
    :telemetry.execute([:absinthe_apq, :cache_error], %{}, metadata)
  end

  # A stored query runs only if it still hashes to its key, whatever the store returned.
  defp verified(query, hash) do
    if AbsintheAPQ.hash(query) == hash do
      {:ok, query}
    else
      {:error, :stored_query_hash_mismatch}
    end
  end

  defp guarded(call) do
    call.()
  rescue
    exception -> {:error, {:exception, exception}}
  catch
    :exit, reason -> {:error, {:exit, reason}}
    :throw, value -> {:error, {:throw, value}}
  end
end
