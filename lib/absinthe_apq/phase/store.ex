defmodule AbsintheAPQ.Phase.Store do
  @moduledoc false

  # Stores a registered query once it has passed validation. The document provider puts
  # this phase right after Absinthe.Phase.Document.Validation.Result, which jumps past
  # the rest of the pipeline when the document has errors, so an invalid query is never
  # stored. The query runs whether or not the store succeeds.

  use Absinthe.Phase

  alias AbsintheAPQ.CacheCall

  @impl Absinthe.Phase
  @spec run(Absinthe.Blueprint.t(), keyword()) :: {:ok, Absinthe.Blueprint.t()}
  def run(blueprint, options) do
    hash = Keyword.fetch!(options, :hash)
    query = Keyword.fetch!(options, :query)
    cache = Keyword.fetch!(options, :cache)

    case CacheCall.put(cache, hash, query) do
      :ok ->
        measurements = %{query_bytes: byte_size(query)}
        :telemetry.execute([:absinthe_apq, :store], measurements, %{hash: hash})

      {:error, reason} ->
        CacheCall.report_error(:put, hash, reason)
    end

    {:ok, blueprint}
  end
end
