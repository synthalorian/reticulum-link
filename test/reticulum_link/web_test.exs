defmodule ReticulumLink.WebTest do
  use ExUnit.Case, async: true
  import Plug.Test
  import Plug.Conn

  alias ReticulumLink.Web.Router

  @opts Router.init([])

  describe "GET /api/status" do
    setup do
      Application.delete_env(:reticulum_link, :api_tokens)
      :ok
    end

    test "returns node status" do
      conn = conn(:get, "/api/status")
      conn = Router.call(conn, @opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert body["node"] == "reticulum_link"
      assert is_integer(body["uptime"])
      assert is_integer(body["links"])
      assert is_integer(body["paths"])
      assert is_integer(body["messages"])
      assert is_boolean(body["propagation"])
    end
  end

  describe "GET /api/peers" do
    setup do
      Application.delete_env(:reticulum_link, :api_tokens)
      :ok
    end

    test "returns peer list" do
      conn = conn(:get, "/api/peers")
      conn = Router.call(conn, @opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["peers"])
      assert is_integer(body["count"])
    end
  end

  describe "GET /api/messages" do
    setup do
      Application.delete_env(:reticulum_link, :api_tokens)
      :ok
    end

    test "returns message list" do
      conn = conn(:get, "/api/messages")
      conn = Router.call(conn, @opts)

      assert conn.status == 200
      body = Jason.decode!(conn.resp_body)
      assert is_list(body["messages"])
      assert is_integer(body["count"])
    end
  end

  describe "POST /api/messages" do
    setup do
      Application.delete_env(:reticulum_link, :api_tokens)
      :ok
    end

    test "creates a message with valid params" do
      dest = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
      src = :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)

      params = %{
        "destination" => dest,
        "source" => src,
        "content" => "hello from api",
        "title" => "test"
      }

      conn = conn(:post, "/api/messages", params)
      conn = put_req_header(conn, "content-type", "application/json")
      conn = Router.call(conn, @opts)

      assert conn.status == 201
      body = Jason.decode!(conn.resp_body)
      assert body["status"] == "queued"
      assert is_binary(body["hash"])
    end

    test "returns 400 for missing fields" do
      conn = conn(:post, "/api/messages", %{"destination" => "abc"})
      conn = put_req_header(conn, "content-type", "application/json")
      conn = Router.call(conn, @opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "missing_field"
    end

    test "returns 400 for invalid hex" do
      params = %{
        "destination" => "not-hex",
        "source" => "not-hex",
        "content" => "hello"
      }

      conn = conn(:post, "/api/messages", params)
      conn = put_req_header(conn, "content-type", "application/json")
      conn = Router.call(conn, @opts)

      assert conn.status == 400
      body = Jason.decode!(conn.resp_body)
      assert body["error"] == "invalid_hex"
    end
  end

  describe "auth plug" do
    setup do
      # Ensure no tokens are configured for most tests
      prev = Application.get_env(:reticulum_link, :api_tokens)
      Application.delete_env(:reticulum_link, :api_tokens)

      on_exit(fn ->
        if prev, do: Application.put_env(:reticulum_link, :api_tokens, prev)
      end)

      :ok
    end

    test "allows requests when no tokens configured" do
      conn = conn(:get, "/api/status")
      conn = Router.call(conn, @opts)

      assert conn.status == 200
    end

    test "rejects requests with invalid token" do
      Application.put_env(:reticulum_link, :api_tokens, ["valid_token"])

      conn = conn(:get, "/api/status")
      conn = put_req_header(conn, "authorization", "Bearer invalid_token")
      conn = Router.call(conn, @opts)

      assert conn.status == 401
    end

    test "allows requests with valid token" do
      Application.put_env(:reticulum_link, :api_tokens, ["valid_token"])

      conn = conn(:get, "/api/status")
      conn = put_req_header(conn, "authorization", "Bearer valid_token")
      conn = Router.call(conn, @opts)

      assert conn.status == 200
    end
  end
end
