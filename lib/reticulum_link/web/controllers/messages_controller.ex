defmodule ReticulumLink.Web.MessagesController do
  @moduledoc """
  GET /api/messages — List stored LXMF messages.
  POST /api/messages — Send a new LXMF message.
  """
  use Phoenix.Controller, formats: [:json]

  alias ReticulumLink.Lxmf.{Message, MessageStore, PropagationEngine}

  def index(conn, _params) do
    messages =
      case Process.whereis(MessageStore) do
        nil -> []
        _pid -> MessageStore.all()
      end

    rendered =
      Enum.map(messages, fn msg ->
        %{
          hash: Base.encode16(msg.hash || <<>>, case: :lower),
          source: Base.encode16(msg.source_hash, case: :lower),
          destination: Base.encode16(msg.destination_hash, case: :lower),
          title: Message.title_string(msg) || "",
          content: Message.content_string(msg) || "",
          timestamp: msg.timestamp,
          state: msg.state
        }
      end)

    json(conn, %{messages: rendered, count: length(rendered)})
  end

  def create(conn, params) do
    with {:ok, dest_hex} <- Map.fetch(params, "destination"),
         {:ok, src_hex} <- Map.fetch(params, "source"),
         {:ok, content} <- Map.fetch(params, "content") do
      dest = Base.decode16!(dest_hex, case: :mixed)
      src = Base.decode16!(src_hex, case: :mixed)
      title = Map.get(params, "title", "")

      msg = Message.new(dest, src, content, title)

      case Message.pack(msg) do
        {:ok, packed} ->
          # Store and propagate
          _ = MessageStore.store(packed)
          _ = PropagationEngine.receive_message(packed)

          conn
          |> put_status(:created)
          |> json(%{
            status: "queued",
            hash: Base.encode16(packed.hash, case: :lower)
          })
      end
    else
      :error ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: "missing_field", required: ["destination", "source", "content"]})
    end
  rescue
    ArgumentError ->
      conn
      |> put_status(:bad_request)
      |> json(%{
        error: "invalid_hex",
        message: "destination and source must be valid hex strings"
      })
  end
end
