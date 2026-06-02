defmodule ReticulumLink.Application do
  @moduledoc false
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      {Phoenix.PubSub, name: ReticulumLink.PubSub},
      ReticulumLink.Crypto.IdentityManager,
      {ReticulumLink.Transport.Supervisor, []},
      {ReticulumLink.Lxmf.Supervisor, []},
      ReticulumLink.Telemetry,
      ReticulumLink.Web.Endpoint
    ]

    # Add Nerves init on embedded targets
    children =
      if apply(Mix, :target, []) != :host do
        children ++ [{Task, fn -> ReticulumLink.Nerves.init() end}]
      else
        children
      end

    opts = [strategy: :one_for_one, name: ReticulumLink.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    :ok
  end
end
