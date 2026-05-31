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
      ReticulumLink.Web.Endpoint
    ]

    opts = [strategy: :one_for_one, name: ReticulumLink.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  def stop(_state) do
    :ok
  end
end
