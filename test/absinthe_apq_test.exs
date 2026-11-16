defmodule AbsintheAPQTest do
  use ExUnit.Case, async: true

  import Plug.Test

  alias AbsintheAPQ.Phase.Error

  doctest AbsintheAPQ

  defp blueprint(kind) do
    {:ok, blueprint} = Error.run("", kind: kind)
    blueprint
  end

  describe "hash/1" do
    test "is 64 lowercase hexadecimal characters" do
      assert AbsintheAPQ.hash("") ==
               "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    end
  end

  describe "before_send/2" do
    test "leaves a response without an APQ error alone" do
      conn = conn(:get, "/")
      assert AbsintheAPQ.before_send(conn, %Absinthe.Blueprint{}) == conn
      assert AbsintheAPQ.before_send(conn, %{result: %{}}) == conn
    end

    test "sets the status after Absinthe.Plug sends 200" do
      for {kind, status} <- [
            not_found: 200,
            not_supported: 200,
            hash_mismatch: 400,
            unsupported_version: 400,
            invalid_hash: 400
          ] do
        conn = :get |> conn("/") |> AbsintheAPQ.before_send(blueprint(kind))
        sent = Plug.Conn.send_resp(conn, 200, "{}")

        assert sent.status == status

        assert Plug.Conn.get_resp_header(sent, "cache-control") == [
                 "private, no-cache, must-revalidate"
               ]
      end
    end

    test "keeps status 200 in a batch" do
      conn = %{conn(:post, "/") | body_params: %{"_json" => [%{}]}}

      sent =
        conn
        |> AbsintheAPQ.before_send(blueprint(:hash_mismatch))
        |> Plug.Conn.send_resp(200, "[]")

      assert sent.status == 200
    end
  end
end
