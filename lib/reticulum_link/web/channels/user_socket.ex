defmodule ReticulumLink.Web.UserSocket do
  @moduledoc """
  Phoenix Socket for WebSocket connections.
  """
  use Phoenix.Socket

  channel "peers:*", ReticulumLink.Web.PeersChannel

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
