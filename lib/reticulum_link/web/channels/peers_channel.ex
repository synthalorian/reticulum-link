defmodule ReticulumLink.Web.PeersChannel do
  @moduledoc """
  WebSocket channel for real-time peer events.

  Clients join "peers:lobby" to receive:
  - peer:joined — when a new peer is discovered
  - peer:left — when a peer times out
  - peer:updated — when peer info changes
  """
  use Phoenix.Channel

  alias ReticulumLink.Transport.PathManager

  @impl true
  def join("peers:lobby", _payload, socket) do
    # Send current peer list on join
    paths =
      case Process.whereis(PathManager) do
        nil -> []
        _pid -> PathManager.all_paths()
      end

    peers =
      Enum.map(paths, fn entry ->
        %{
          hash: Base.encode16(entry.destination_hash, case: :lower),
          hops: entry.hops
        }
      end)

    {:ok, %{peers: peers, count: length(peers)}, socket}
  end

  def join("peers:" <> _id, _payload, socket) do
    {:ok, socket}
  end

  @impl true
  def handle_in("ping", _payload, socket) do
    {:reply, {:ok, %{pong: true, timestamp: System.system_time(:second)}}, socket}
  end

  def handle_in("list_peers", _payload, socket) do
    paths =
      case Process.whereis(PathManager) do
        nil -> []
        _pid -> PathManager.all_paths()
      end

    peers =
      Enum.map(paths, fn entry ->
        %{
          hash: Base.encode16(entry.destination_hash, case: :lower),
          hops: entry.hops
        }
      end)

    {:reply, {:ok, %{peers: peers, count: length(peers)}}, socket}
  end
end
