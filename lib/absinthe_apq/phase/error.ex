defmodule AbsintheAPQ.Phase.Error do
  @moduledoc false

  # Replaces the whole document pipeline for a request that gets an APQ error. The error
  # is the only entry in the result's "errors" list; it has no locations, because there is
  # no document to point into.

  use Absinthe.Phase

  alias Absinthe.Blueprint

  @type kind ::
          :not_found | :not_supported | :hash_mismatch | :unsupported_version | :invalid_hash

  # Message and extensions.code of each error. Apollo Client 4 retries with the full query
  # when the message is "PersistedQueryNotFound" or the code is "PERSISTED_QUERY_NOT_FOUND",
  # and turns APQ off for the session on "PersistedQueryNotSupported" or
  # "PERSISTED_QUERY_NOT_SUPPORTED", so no other error may use those messages or codes.
  @errors %{
    not_found: {"PersistedQueryNotFound", "PERSISTED_QUERY_NOT_FOUND", 200},
    not_supported: {"PersistedQueryNotSupported", "PERSISTED_QUERY_NOT_SUPPORTED", 200},
    hash_mismatch: {"provided sha does not match query", "PERSISTED_QUERY_HASH_MISMATCH", 400},
    unsupported_version:
      {"Unsupported persisted query version", "PERSISTED_QUERY_UNSUPPORTED_VERSION", 400},
    invalid_hash: {
      "persistedQuery.sha256Hash must be 64 lowercase hexadecimal characters",
      "PERSISTED_QUERY_INVALID_HASH",
      400
    }
  }

  @codes Map.new(@errors, fn {kind, {_message, code, _status}} -> {code, kind} end)

  @impl Absinthe.Phase
  @spec run(term(), keyword()) :: {:ok, Blueprint.t()}
  def run(_input, options) do
    kind = Keyword.fetch!(options, :kind)
    error = error(kind)
    execution = %Blueprint.Execution{validation_errors: [error]}
    blueprint = %Blueprint{execution: execution}
    {:ok, blueprint}
  end

  @spec error(kind()) :: Absinthe.Phase.Error.t()
  def error(kind) do
    {message, code, _status} = Map.fetch!(@errors, kind)
    # Absinthe.Phase.Document.Result merges :extra into the error object. This module's
    # pipeline runs that phase without options, so :spec_compliant_errors never wraps
    # :extra in a second "extensions" key.
    extra = %{extensions: %{code: code}}
    %Absinthe.Phase.Error{phase: __MODULE__, message: message, extra: extra}
  end

  @spec http_status(kind()) :: 200 | 400
  def http_status(kind) do
    {_message, _code, status} = Map.fetch!(@errors, kind)
    status
  end

  @spec kind(Blueprint.t()) :: kind() | nil
  def kind(%Blueprint{execution: %Blueprint.Execution{validation_errors: errors}}) do
    Enum.find_value(errors, &error_kind/1)
  end

  defp error_kind(%Absinthe.Phase.Error{phase: __MODULE__, extra: %{extensions: %{code: code}}}),
    do: Map.get(@codes, code)

  defp error_kind(_error), do: nil
end
