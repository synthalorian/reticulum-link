defmodule ReticulumLink.Web.Plugs.Auth do
  @moduledoc """
  Token-based API authentication plug.

  Reads `Authorization: Bearer <token>` header and validates against
  configured API tokens. Tokens are set in application config:

      config :reticulum_link, :api_tokens, ["secret_token_1", "secret_token_2"]

  If no tokens are configured, all requests are allowed (development mode).
  """

  import Plug.Conn

  @behaviour Plug

  @impl true
  def init(opts), do: opts

  @impl true
  def call(conn, _opts) do
    tokens = Application.get_env(:reticulum_link, :api_tokens)

    if tokens == nil or tokens == [] do
      # No tokens configured — allow all (dev mode)
      conn
    else
      check_token(conn, tokens)
    end
  end

  defp check_token(conn, tokens) do
    case get_req_header(conn, "authorization") do
      ["Bearer " <> token] ->
        if token in tokens do
          conn
        else
          halt_unauthorized(conn)
        end

      _ ->
        halt_unauthorized(conn)
    end
  end

  defp halt_unauthorized(conn) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(401, Jason.encode!(%{error: "Unauthorized"}))
    |> halt()
  end
end
