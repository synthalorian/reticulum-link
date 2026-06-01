defmodule ReticulumLink.Transport.PathManager do
  @moduledoc """
  Routing table management for Reticulum path discovery.

  Stores paths to destinations in an ETS table with TTL-based expiration.
  Each path records:
  - Destination hash (128-bit)
  - Next-hop interface / transport ID
  - Hop count
  - Timestamp (for expiration)
  - RSSI/SNR (optional link quality metrics)

  ## Path entry

      %{
        destination_hash: <<_::128>>,
        transport_id: <<_::128>> | nil,
        hops: non_neg_integer(),
        timestamp: DateTime.t(),
        expires_at: DateTime.t(),
        rssi: integer() | nil,
        snr: float() | nil
      }

  ## Table structure

  ETS table `:path_table` with `{destination_hash, path_entry}` tuples.
  """

  use GenServer

  require Logger

  @default_path_ttl 86_400
  @cleanup_interval 300_000

  @typedoc "Path entry"
  @type path_entry :: %{
          destination_hash: binary(),
          transport_id: binary() | nil,
          hops: non_neg_integer(),
          timestamp: DateTime.t(),
          expires_at: DateTime.t(),
          rssi: integer() | nil,
          snr: float() | nil
        }

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start the PathManager GenServer.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a path to a destination.

  ## Parameters

  * `destination_hash` — 128-bit destination hash
  * `transport_id` — 128-bit transport ID (nil for direct paths)
  * `hops` — Hop count to reach destination
  * `ttl` — Time-to-live in seconds (default: 86400)
  * `rssi` / `snr` — Optional link quality metrics
  """
  @spec register_path(
          binary(),
          binary() | nil,
          non_neg_integer(),
          non_neg_integer(),
          integer() | nil,
          float() | nil
        ) ::
          :ok
  def register_path(
        destination_hash,
        transport_id \\ nil,
        hops \\ 0,
        ttl \\ @default_path_ttl,
        rssi \\ nil,
        snr \\ nil
      ) do
    GenServer.call(
      __MODULE__,
      {:register_path, destination_hash, transport_id, hops, ttl, rssi, snr}
    )
  end

  @doc """
  Look up a path to a destination.

  Returns `{:ok, path_entry}` or `{:error, :no_path}`.
  """
  @spec lookup_path(binary()) :: {:ok, path_entry()} | {:error, :no_path}
  def lookup_path(destination_hash) do
    GenServer.call(__MODULE__, {:lookup_path, destination_hash})
  end

  @doc """
  Check if a path exists to a destination.
  """
  @spec has_path?(binary()) :: boolean()
  def has_path?(destination_hash) do
    case lookup_path(destination_hash) do
      {:ok, _} -> true
      _ -> false
    end
  end

  @doc """
  Get all known paths.
  """
  @spec all_paths() :: [path_entry()]
  def all_paths do
    GenServer.call(__MODULE__, :all_paths)
  end

  @doc """
  Get path count.
  """
  @spec path_count() :: non_neg_integer()
  def path_count do
    GenServer.call(__MODULE__, :path_count)
  end

  @doc """
  Delete a path.
  """
  @spec delete_path(binary()) :: :ok
  def delete_path(destination_hash) do
    GenServer.call(__MODULE__, {:delete_path, destination_hash})
  end

  @doc """
  Request a path to a destination (triggers path discovery).

  Broadcasts a path request on all interfaces.
  """
  @spec request_path(binary()) :: :ok
  def request_path(destination_hash) do
    GenServer.cast(__MODULE__, {:request_path, destination_hash})
  end

  # ===========================================================================
  # Server callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    table = :ets.new(:path_table, [:set, :protected, read_concurrency: true])
    timer = Process.send_after(self(), :cleanup, @cleanup_interval)
    name = Keyword.get(opts, :name, __MODULE__)
    {:ok, %{table: table, cleanup_timer: timer, name: name}}
  end

  @impl true
  def handle_call(
        {:register_path, destination_hash, transport_id, hops, ttl, rssi, snr},
        _from,
        state
      ) do
    now = DateTime.utc_now()
    expires_at = DateTime.add(now, ttl, :second)

    entry = %{
      destination_hash: destination_hash,
      transport_id: transport_id,
      hops: hops,
      timestamp: now,
      expires_at: expires_at,
      rssi: rssi,
      snr: snr
    }

    :ets.insert(state.table, {destination_hash, entry})

    Logger.debug(
      "Path registered: #{Base.encode16(destination_hash, case: :lower)} (#{hops} hops)"
    )

    {:reply, :ok, state}
  end

  @impl true
  def handle_call({:lookup_path, destination_hash}, _from, state) do
    result =
      case :ets.lookup(state.table, destination_hash) do
        [{^destination_hash, entry}] ->
          if DateTime.compare(entry.expires_at, DateTime.utc_now()) == :gt do
            {:ok, entry}
          else
            {:error, :path_expired}
          end

        [] ->
          {:error, :no_path}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_call(:all_paths, _from, state) do
    paths =
      :ets.tab2list(state.table)
      |> Enum.map(fn {_hash, entry} -> entry end)
      |> Enum.filter(fn entry ->
        DateTime.compare(entry.expires_at, DateTime.utc_now()) == :gt
      end)

    {:reply, paths, state}
  end

  @impl true
  def handle_call(:path_count, _from, state) do
    count = :ets.info(state.table, :size)
    {:reply, count, state}
  end

  @impl true
  def handle_call({:delete_path, destination_hash}, _from, state) do
    :ets.delete(state.table, destination_hash)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    count_before = :ets.info(state.table, :size)
    now = DateTime.utc_now()

    # ETS match spec: delete entries where expires_at < now
    # We need to match the tuple shape {hash, map}
    :ets.select_delete(state.table, [
      {{:_, %{expires_at: :"$1"}}, [{:<, :"$1", {:const, now}}], [true]}
    ])

    count_after = :ets.info(state.table, :size)
    deleted = count_before - count_after

    if deleted > 0 do
      Logger.debug("Path cleanup: removed #{deleted} expired paths (#{count_after} remaining)")
    end

    timer = Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, %{state | cleanup_timer: timer}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end
end
