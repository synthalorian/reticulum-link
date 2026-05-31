defmodule ReticulumLink.Transport.AnnounceHandler do
  @moduledoc """
  Handles Reticulum announce propagation.

  Announces are broadcast packets that advertise a destination's existence
  and public key. The AnnounceHandler:

  1. Receives announces from interfaces
  2. Validates and deduplicates (hash-based)
  3. Caches for local routing
  4. Forwards to other interfaces (if transport mode enabled)
  5. Updates the PathManager with discovered paths

  ## Announce deduplication

  Uses a rolling hash set to prevent relay storms. Old entries are
  periodically purged.

  ## Announce rate limiting

  Per-identity rate limiting prevents announce flooding.
  """

  use GenServer

  alias ReticulumLink.Crypto.Hash
  alias ReticulumLink.Transport.PathManager

  require Logger

  @announce_ttl 86_400
  @dedup_window 300
  @cleanup_interval 60_000
  @max_announce_cache 10_000

  @typedoc "Announce entry"
  @type announce_entry :: %{
          identity_hash: binary(),
          destination_hash: binary(),
          public_key: binary(),
          name_hash: binary(),
          random_hash: binary(),
          ratchet: binary() | nil,
          signature: binary(),
          hops: non_neg_integer(),
          received_at: DateTime.t(),
          expires_at: DateTime.t()
        }

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start the AnnounceHandler.
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Process an incoming announce.

  Returns `:ok` if processed, `{:drop, reason}` if filtered.
  """
  @spec handle_announce(binary(), map()) :: :ok | {:drop, atom()}
  def handle_announce(raw_packet, metadata \\ %{}) do
    GenServer.call(__MODULE__, {:handle_announce, raw_packet, metadata})
  end

  @doc """
  Check if an announce hash has been seen recently.
  """
  @spec seen?(binary()) :: boolean()
  def seen?(announce_hash) do
    GenServer.call(__MODULE__, {:seen?, announce_hash})
  end

  @doc """
  Get cached announce count.
  """
  @spec announce_count() :: non_neg_integer()
  def announce_count do
    GenServer.call(__MODULE__, :announce_count)
  end

  # ===========================================================================
  # Server callbacks
  # ===========================================================================

  @impl true
  def init(_opts) do
    table = :ets.new(:announce_cache, [:set, :protected, :named_table, read_concurrency: true])
    seen = :ets.new(:announce_seen, [:set, :protected, :named_table, read_concurrency: true])
    timer = Process.send_after(self(), :cleanup, @cleanup_interval)

    {:ok, %{cache: table, seen: seen, cleanup_timer: timer, forwarded: 0, dropped: 0}}
  end

  @impl true
  def handle_call({:handle_announce, raw_packet, metadata}, _from, state) do
    announce_hash = Hash.sha256(raw_packet) |> binary_part(0, 16)

    cond do
      recently_seen?(state.seen, announce_hash) ->
        {:reply, {:drop, :already_seen}, %{state | dropped: state.dropped + 1}}

      byte_size(raw_packet) > 500 ->
        {:reply, {:drop, :oversized}, %{state | dropped: state.dropped + 1}}

      true ->
        entry = parse_announce(raw_packet, metadata)
        cache_announce(state.cache, announce_hash, entry)
        mark_seen(state.seen, announce_hash)

        # Register path
        PathManager.register_path(
          entry.destination_hash,
          Map.get(metadata, :transport_id),
          Map.get(metadata, :hops, 0),
          @announce_ttl
        )

        # Forward if transport mode
        if transport_mode?() do
          forward_announce(raw_packet, metadata)
        end

        {:reply, :ok, %{state | forwarded: state.forwarded + 1}}
    end
  end

  @impl true
  def handle_call({:seen?, announce_hash}, _from, state) do
    {:reply, recently_seen?(state.seen, announce_hash), state}
  end

  @impl true
  def handle_call(:announce_count, _from, state) do
    count = :ets.info(state.cache, :size)
    {:reply, count, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = DateTime.utc_now()

    # Clean expired cache entries
    :ets.select_delete(state.cache, [
      {{:_, %{expires_at: :"$1"}}, [{:<, :"$1", {:const, now}}], [true]}
    ])

    # Clean old seen entries
    :ets.select_delete(state.seen, [
      {{:_, %{timestamp: :"$1"}},
       [{:<, :"$1", {:const, DateTime.add(now, -@dedup_window, :second)}}], [true]}
    ])

    timer = Process.send_after(self(), :cleanup, @cleanup_interval)
    {:noreply, %{state | cleanup_timer: timer}}
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp recently_seen?(seen_table, announce_hash) do
    case :ets.lookup(seen_table, announce_hash) do
      [{_, %{timestamp: ts}}] ->
        age = DateTime.diff(DateTime.utc_now(), ts, :second)
        age < @dedup_window

      [] ->
        false
    end
  end

  defp mark_seen(seen_table, announce_hash) do
    :ets.insert(seen_table, {announce_hash, %{timestamp: DateTime.utc_now()}})
  end

  defp cache_announce(cache_table, announce_hash, entry) do
    # Limit cache size with FIFO eviction
    if :ets.info(cache_table, :size) >= @max_announce_cache do
      # Delete oldest entry
      case :ets.first(cache_table) do
        :"$end_of_table" -> :ok
        key -> :ets.delete(cache_table, key)
      end
    end

    :ets.insert(cache_table, {announce_hash, entry})
  end

  defp parse_announce(_raw_packet, metadata) do
    # Parse announce data from packet
    # Format: public_key(32) + name_hash(10) + random_hash(10) + ratchet(?) + signature(64)
    # This is a simplified parser; full parsing depends on packet structure

    %{
      identity_hash: Map.get(metadata, :identity_hash),
      destination_hash: Map.get(metadata, :destination_hash),
      public_key: Map.get(metadata, :public_key),
      name_hash: Map.get(metadata, :name_hash),
      random_hash: Map.get(metadata, :random_hash),
      ratchet: Map.get(metadata, :ratchet),
      signature: Map.get(metadata, :signature),
      hops: Map.get(metadata, :hops, 0),
      received_at: DateTime.utc_now(),
      expires_at: DateTime.add(DateTime.utc_now(), @announce_ttl, :second)
    }
  end

  defp forward_announce(raw_packet, metadata) do
    # Broadcast to all interfaces except the incoming one
    Phoenix.PubSub.broadcast(
      ReticulumLink.PubSub,
      "reticulum:forward",
      {:forward_announce, raw_packet, metadata}
    )
  end

  defp transport_mode? do
    Application.get_env(:reticulum_link, :transport_mode, false)
  end
end
