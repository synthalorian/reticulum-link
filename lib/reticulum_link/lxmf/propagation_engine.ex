defmodule ReticulumLink.Lxmf.PropagationEngine do
  @moduledoc """
  Store-and-forward propagation engine for LXMF messages.

  Receives messages, stores them in MessageStore, tracks delivery via
  DeliveryTracker, and propagates to known peers via PubSub.

  Features:
  - Deduplication: hash-based, prevents relay storms
  - Priority queue: urgent messages propagate first
  - Configurable limits: max storage, TTL, max message size
  - Batch propagation: groups messages for efficient relay
  """

  use GenServer

  alias ReticulumLink.Lxmf.{DeliveryTracker, Message, MessageStore}

  @default_batch_size 10
  @default_batch_interval_ms 5_000
  @default_max_hops 8
  @propagation_topic "lxmf:propagate"

  defstruct [
    :message_store,
    :delivery_tracker,
    :batch_size,
    :batch_interval,
    :max_hops,
    :batch_timer,
    :seen_hashes,
    :enabled
  ]

  # ── Client API ──────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Receive an incoming LXMF message. Stores, dedups, and queues for propagation.
  Returns :ok | {:error, reason}.
  """
  @spec receive_message(GenServer.server(), Message.t(), keyword()) ::
          :ok | {:error, atom()}
  def receive_message(server \\ __MODULE__, %Message{} = msg, opts \\ []) do
    GenServer.call(server, {:receive, msg, opts})
  end

  @doc """
  Receive raw packed bytes, unpack and process.
  """
  @spec receive_bytes(GenServer.server(), binary(), keyword()) ::
          :ok | {:error, atom()}
  def receive_bytes(server \\ __MODULE__, bytes, opts \\ []) when is_binary(bytes) do
    case Message.unpack(bytes) do
      {:ok, msg} -> receive_message(server, msg, opts)
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Enable propagation.
  """
  @spec enable(GenServer.server()) :: :ok
  def enable(server \\ __MODULE__) do
    GenServer.call(server, :enable)
  end

  @doc """
  Disable propagation (store only, don't forward).
  """
  @spec disable(GenServer.server()) :: :ok
  def disable(server \\ __MODULE__) do
    GenServer.call(server, :disable)
  end

  @doc """
  Trigger immediate propagation of pending messages.
  """
  @spec propagate_now(GenServer.server()) :: :ok
  def propagate_now(server \\ __MODULE__) do
    GenServer.call(server, :propagate_now)
  end

  @doc """
  Get engine status.
  """
  @spec status(GenServer.server()) :: map()
  def status(server \\ __MODULE__) do
    GenServer.call(server, :status)
  end

  # ── Server Callbacks ────────────────────────────────────

  @impl true
  def init(opts) do
    message_store = Keyword.get(opts, :message_store, ReticulumLink.Lxmf.MessageStore)
    delivery_tracker = Keyword.get(opts, :delivery_tracker, ReticulumLink.Lxmf.DeliveryTracker)
    batch_size = Keyword.get(opts, :batch_size, @default_batch_size)
    batch_interval = Keyword.get(opts, :batch_interval, @default_batch_interval_ms)
    max_hops = Keyword.get(opts, :max_hops, @default_max_hops)

    # Rolling dedup window: {hash, timestamp} bag
    seen_table = :ets.new(:propagation_seen, [:bag, :protected])

    # Start batch timer
    timer = Process.send_after(self(), :batch_propagate, batch_interval)

    {:ok,
     %__MODULE__{
       message_store: message_store,
       delivery_tracker: delivery_tracker,
       batch_size: batch_size,
       batch_interval: batch_interval,
       max_hops: max_hops,
       batch_timer: timer,
       seen_hashes: seen_table,
       enabled: true
     }}
  end

  @impl true
  def handle_call({:receive, %Message{} = msg, opts}, _from, state) do
    hash = msg.hash

    cond do
      hash == nil ->
        {:reply, {:error, :no_hash}, state}

      already_seen?(state, hash) ->
        {:reply, {:error, :duplicate}, state}

      true ->
        # Mark as seen
        :ets.insert(state.seen_hashes, {hash, System.system_time(:second)})

        # Clean old dedup entries
        clean_seen_window(state)

        # Determine priority
        priority = Keyword.get(opts, :priority, 0)
        ttl = Keyword.get(opts, :ttl, 86_400)

        # Store message
        store_result = MessageStore.store(state.message_store, msg, priority: priority, ttl: ttl)

        case store_result do
          :ok ->
            # Register with delivery tracker
            DeliveryTracker.register(state.delivery_tracker, hash, ttl: ttl)

            # If enabled, message will be picked up by batch timer
            {:reply, :ok, state}

          {:error, reason} ->
            {:reply, {:error, reason}, state}
        end
    end
  end

  def handle_call(:enable, _from, state) do
    {:reply, :ok, %{state | enabled: true}}
  end

  def handle_call(:disable, _from, state) do
    {:reply, :ok, %{state | enabled: false}}
  end

  def handle_call(:propagate_now, _from, state) do
    if state.enabled do
      do_propagate(state)
    end

    # Reset timer
    if state.batch_timer, do: Process.cancel_timer(state.batch_timer)
    timer = Process.send_after(self(), :batch_propagate, state.batch_interval)
    {:reply, :ok, %{state | batch_timer: timer}}
  end

  def handle_call(:status, _from, state) do
    seen_count = :ets.info(state.seen_hashes, :size)

    {:reply,
     %{
       enabled: state.enabled,
       seen_count: seen_count,
       batch_size: state.batch_size,
       batch_interval: state.batch_interval,
       max_hops: state.max_hops
     }, state}
  end

  @impl true
  def handle_info(:batch_propagate, state) do
    if state.enabled do
      do_propagate(state)
    end

    timer = Process.send_after(self(), :batch_propagate, state.batch_interval)
    {:noreply, %{state | batch_timer: timer}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.batch_timer, do: Process.cancel_timer(state.batch_timer)
    :ok
  end

  # ── Private ─────────────────────────────────────────────

  defp already_seen?(state, hash) do
    case :ets.lookup(state.seen_hashes, hash) do
      [] -> false
      _ -> true
    end
  end

  defp clean_seen_window(state) do
    now = System.system_time(:second)
    cutoff = now - 300

    old =
      :ets.select(state.seen_hashes, [
        {{:"$1", :"$2"}, [{:<, :"$2", cutoff}], [:"$1"]}
      ])

    Enum.each(old, fn hash ->
      :ets.delete(state.seen_hashes, hash)
    end)
  end

  defp do_propagate(state) do
    # Get pending messages sorted by priority
    pending = DeliveryTracker.pending(state.delivery_tracker)

    # Limit batch size
    batch = Enum.take(pending, state.batch_size)

    Enum.each(batch, fn hash ->
      case MessageStore.lookup(state.message_store, hash) do
        {:ok, msg} ->
          # Mark as propagated
          DeliveryTracker.mark_propagated(state.delivery_tracker, hash, "broadcast")

          # Publish to propagation topic
          # Subscribers (peer links) will receive and forward
          Phoenix.PubSub.broadcast(
            ReticulumLink.PubSub,
            @propagation_topic,
            {:lxmf_propagate, msg, state.max_hops}
          )

        {:error, :not_found} ->
          :ok
      end
    end)
  end
end
