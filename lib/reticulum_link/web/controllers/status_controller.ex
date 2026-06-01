defmodule ReticulumLink.Web.StatusController do
  @moduledoc """
  GET /api/status — Node status, uptime, peer count, link count.
  """
  use Phoenix.Controller, formats: [:json]

  alias ReticulumLink.Transport.{LinkManager, PathManager}
  alias ReticulumLink.Lxmf.{MessageStore, PropagationEngine}

  def index(conn, _params) do
    {:ok, link_count} = safe_call(LinkManager, :link_count, 0)
    {:ok, path_count} = safe_call(PathManager, :path_count, 0)
    {:ok, msg_count} = safe_call(MessageStore, :count, 0)
    {:ok, engine_status} = safe_call(PropagationEngine, :status, %{enabled: false})

    json(conn, %{
      node: "reticulum_link",
      version: Application.spec(:reticulum_link, :vsn) |> to_string(),
      uptime: :erlang.statistics(:wall_clock) |> elem(0) |> div(1000),
      links: link_count,
      paths: path_count,
      messages: msg_count,
      propagation: engine_status.enabled
    })
  end

  defp safe_call(module, fun, default) do
    case Process.whereis(module) do
      nil -> {:ok, default}
      _pid -> {:ok, apply(module, fun, [])}
    end
  rescue
    _ -> {:ok, default}
  end
end
