defmodule ReticulumLink.Web.HealthController do
  @moduledoc """
  GET /health — Health check endpoint for load balancers.

  Returns 200 if the node is operational, 503 if degraded.
  """
  use Phoenix.Controller, formats: [:json]

  alias ReticulumLink.Transport.{LinkManager, PathManager}
  alias ReticulumLink.Lxmf.{MessageStore, PropagationEngine}

  def index(conn, _params) do
    checks = %{
      links: process_alive?(LinkManager),
      paths: process_alive?(PathManager),
      messages: process_alive?(MessageStore),
      propagation: process_alive?(PropagationEngine)
    }

    healthy = Enum.all?(checks, fn {_k, v} -> v end)

    status = if healthy, do: 200, else: 503

    conn
    |> put_status(status)
    |> json(%{
      status: if(healthy, do: "healthy", else: "degraded"),
      checks: checks,
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601()
    })
  end

  defp process_alive?(module) do
    case Process.whereis(module) do
      nil -> false
      pid -> Process.alive?(pid)
    end
  end
end
