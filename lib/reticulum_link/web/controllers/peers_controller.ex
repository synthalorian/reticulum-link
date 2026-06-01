defmodule ReticulumLink.Web.PeersController do
  @moduledoc """
  GET /api/peers — List known peers from the path manager.
  """
  use Phoenix.Controller, formats: [:json]

  alias ReticulumLink.Transport.PathManager

  def index(conn, _params) do
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

    json(conn, %{peers: peers, count: length(peers)})
  end
end
