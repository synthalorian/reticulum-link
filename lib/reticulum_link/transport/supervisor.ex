defmodule ReticulumLink.Transport.Supervisor do
  @moduledoc """
  Top-level supervisor for the Transport layer.

  Manages:
  - Interface processes (TCP, Serial, AutoInterface)
  - Link management (future: Phase 3)
  - Path management (future: Phase 3)
  - Announce handling (future: Phase 3)
  """

  use Supervisor

  require Logger

  def start_link(opts \\ []) do
    Supervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl true
  def init(_opts) do
    children = [
      # Interface supervisor — dynamically spawns interface processes
      {DynamicSupervisor,
       strategy: :one_for_one, name: ReticulumLink.Transport.InterfaceSupervisor}
    ]

    Logger.info("Transport supervisor started")
    Supervisor.init(children, strategy: :one_for_one)
  end
end
