defmodule ReticulumLink.Transport.LinkManager do
  @moduledoc """
  DynamicSupervisor for managing Link processes.

  Spawns one GenServer per encrypted link. Links are keyed by their
  link_id (128-bit hash). The LinkManager provides lookup and lifecycle
  management.

  ## Usage

      # Start an outbound link
      {:ok, link_pid} = LinkManager.start_link_initiator(destination_hash)

      # Start an inbound link from a received LINKREQUEST
      {:ok, link_pid} = LinkManager.start_link_responder(dst_hash, peer_pub, peer_sig_pub)

      # Look up a link by ID
      {:ok, pid} = LinkManager.get_link(link_id)
  """

  use DynamicSupervisor

  alias ReticulumLink.Transport.Link

  require Logger

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start the LinkManager.
  """
  @spec start_link(Keyword.t()) :: Supervisor.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    DynamicSupervisor.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Start an initiator link (outbound).
  """
  @spec start_link_initiator(binary(), Keyword.t()) :: DynamicSupervisor.on_start_child()
  def start_link_initiator(destination_hash, opts \\ []) do
    link_name = generate_link_name()
    opts = Keyword.put(opts, :name, link_name)

    spec = %{
      id: link_name,
      start: {Link, :start_link_initiator, [destination_hash, opts]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Start a responder link (inbound).
  """
  @spec start_link_responder(binary(), binary(), binary(), Keyword.t()) ::
          DynamicSupervisor.on_start_child()
  def start_link_responder(destination_hash, peer_pub, peer_sig_pub, opts \\ []) do
    link_name = generate_link_name()
    opts = Keyword.put(opts, :name, link_name)

    spec = %{
      id: link_name,
      start: {Link, :start_link_responder, [destination_hash, peer_pub, peer_sig_pub, opts]},
      restart: :temporary,
      type: :worker
    }

    DynamicSupervisor.start_child(__MODULE__, spec)
  end

  @doc """
  Get a link process by its registered name.
  """
  @spec get_link(atom()) :: {:ok, pid()} | {:error, :not_found}
  def get_link(link_name) when is_atom(link_name) do
    case Process.whereis(link_name) do
      nil -> {:error, :not_found}
      pid -> {:ok, pid}
    end
  end

  @doc """
  List all active links.
  """
  @spec list_links() :: [{atom(), pid()}]
  def list_links do
    DynamicSupervisor.which_children(__MODULE__)
    |> Enum.filter(fn {_, pid, _, _} -> is_pid(pid) end)
    |> Enum.map(fn {id, pid, _, _} -> {id, pid} end)
  end

  @doc """
  Count active links.
  """
  @spec link_count() :: non_neg_integer()
  def link_count do
    DynamicSupervisor.count_children(__MODULE__).active
  end

  @doc """
  Terminate a link.
  """
  @spec terminate_link(atom() | pid()) :: :ok | {:error, :not_found}
  def terminate_link(link_name) when is_atom(link_name) do
    case get_link(link_name) do
      {:ok, pid} -> terminate_link(pid)
      error -> error
    end
  end

  def terminate_link(pid) when is_pid(pid) do
    DynamicSupervisor.terminate_child(__MODULE__, pid)
  end

  # ===========================================================================
  # Server callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one, max_restarts: 100, max_seconds: 60)
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp generate_link_name do
    :"link_#{System.unique_integer([:positive])}"
  end
end
