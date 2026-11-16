defmodule AbsintheAPQ.Test.Schema do
  @moduledoc false

  use Absinthe.Schema

  query do
    field :hello, :string do
      arg :name, :string
      resolve &hello/2
    end
  end

  mutation do
    field :ping, :string do
      resolve &ping/2
    end
  end

  defp hello(arguments, _resolution) do
    name = Map.get(arguments, :name, "world")
    {:ok, "Hello, #{name}"}
  end

  defp ping(_arguments, _resolution), do: {:ok, "pong"}
end
