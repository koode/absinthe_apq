defmodule AbsintheAPQ.Test.Telemetry do
  @moduledoc false

  @events [
    [:absinthe_apq, :hit],
    [:absinthe_apq, :miss],
    [:absinthe_apq, :store],
    [:absinthe_apq, :hash_mismatch],
    [:absinthe_apq, :query_too_large],
    [:absinthe_apq, :invalid_request],
    [:absinthe_apq, :not_supported],
    [:absinthe_apq, :cache_error]
  ]

  @doc "Sends every AbsintheAPQ event to the calling process until the test ends."
  @spec attach() :: :ok
  def attach do
    id = {__MODULE__, make_ref()}
    :ok = :telemetry.attach_many(id, @events, &__MODULE__.handle/4, self())
    ExUnit.Callbacks.on_exit(fn -> :telemetry.detach(id) end)
  end

  @doc false
  def handle(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end
end
