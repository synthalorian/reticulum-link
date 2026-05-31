defmodule ReticulumLink.Lxmf.DeliveryTracker do
  @moduledoc """
  Tracks delivery receipts and propagation status for LXMF messages.

  Uses ETS to store per-message delivery state:
  - pending: message stored, awaiting propagation
  - propagated: sent to at least one peer
  - delivered: delivery receipt received
  - failed: max attempts exceeded or TTL expired

  Also tracks per-peer propagation status to avoid redundant sends.
  """

  use GenServer

  @default_max_attempts 3
  @cleanup_interval_ms 120_000

  defstruct [
    :table_status,
    :table_peers,
    :max_attempts,
    :cleanup_timer
  ]

  # ── Client API ──────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Register a message as pending delivery.
  """
  @spec register(GenServer.server(), binary(), keyword()) :: :ok
  def register(server \\ __MODULE__, message_hash, opts \\ []) do
    GenServer.call(server, {:register, message_hash, opts})
  end

  @doc """
  Mark a message as propagated to a specific peer.
  """
  @spec mark_propagated(GenServer.server(), binary(), binary()) :: :ok
  def mark_propagated(server \\ __MODULE__, message_hash, peer_hash) do
    GenServer.call(server, {:mark_propagated, message_hash, peer_hash})
  end

  @doc """
  Mark a message as delivered (receipt received).
  """
  @spec mark_delivered(GenServer.server(), binary()) :: :ok
  def mark_delivered(server \\ __MODULE__, message_hash) do
    GenServer.call(server, {:mark_delivered, message_hash})
  end

  @doc """
  Mark a message as failed.
  """
  @spec mark_failed(GenServer.server(), binary(), atom()) :: :ok
  def mark_failed(server \\ __MODULE__, message_hash, reason \\ :unknown) do
    GenServer.call(server, {:mark_failed, message_hash, reason})
  end

  @doc """
  Increment delivery attempts for a message.
  Returns {:ok, attempts} or {:error, :max_attempts_exceeded}.
  """
  @spec increment_attempt(GenServer.server(), binary()) ::
          {:ok, non_neg_integer()} | {:error, atom()}
  def increment_attempt(server \\ __MODULE__, message_hash) do
    GenServer.call(server, {:increment_attempt, message_hash})
  end

  @doc """
  Check if a message was already propagated to a peer.
  """
  @spec propagated_to_peer?(GenServer.server(), binary(), binary()) :: boolean()
  def propagated_to_peer?(server \\ __MODULE__, message_hash, peer_hash) do
    GenServer.call(server, {:propagated_to_peer?, message_hash, peer_hash})
  end

  @doc """
  Get delivery status for a message.
  """
  @spec status(GenServer.server(), binary()) ::
          {:ok, map()} | {:error, :not_found}
  def status(server \\ __MODULE__, message_hash) do
    GenServer.call(server, {:status, message_hash})
  end

  @doc """
  Get all pending messages (not yet delivered/failed).
  """
  @spec pending(GenServer.server()) :: [binary()]
  def pending(server \\ __MODULE__) do
    GenServer.call(server, :pending)
  end

  @doc """
  Get delivery statistics.
  """
  @spec stats(GenServer.server()) :: map()
  def stats(server \\ __MODULE__) do
    GenServer.call(server, :stats)
  end

  # ── Server Callbacks ────────────────────────────────────

  @impl true
  def init(opts) do
    max_attempts = Keyword.get(opts, :max_attempts, @default_max_attempts)

    status_table = :ets.new(:delivery_status, [:set, :protected, read_concurrency: true])
    peers_table = :ets.new(:delivery_peers, [:bag, :protected])

    timer = Process.send_after(self(), :cleanup, @cleanup_interval_ms)

    {:ok,
     %__MODULE__{
       table_status: status_table,
       table_peers: peers_table,
       max_attempts: max_attempts,
       cleanup_timer: timer
     }}
  end

  @impl true
  def handle_call({:register, message_hash, opts}, _from, state) do
    ttl = Keyword.get(opts, :ttl, 86_400)
    expires_at = System.system_time(:second) + ttl

    record = {
      message_hash,
      :pending,
      0,
      expires_at,
      nil,
      System.system_time(:second)
    }

    :ets.insert(state.table_status, record)
    {:reply, :ok, state}
  end

  def handle_call({:mark_propagated, message_hash, peer_hash}, _from, state) do
    :ets.insert(state.table_peers, {message_hash, peer_hash, System.system_time(:second)})

    # Update status to propagated if still pending
    case :ets.lookup(state.table_status, message_hash) do
      [{^message_hash, :pending, attempts, expires, _reason, created}] ->
        :ets.insert(
          state.table_status,
          {message_hash, :propagated, attempts, expires, nil, created}
        )

        {:reply, :ok, state}

      _ ->
        {:reply, :ok, state}
    end
  end

  def handle_call({:mark_delivered, message_hash}, _from, state) do
    case :ets.lookup(state.table_status, message_hash) do
      [{^message_hash, _status, attempts, expires, _reason, created}] ->
        :ets.insert(
          state.table_status,
          {message_hash, :delivered, attempts, expires, nil, created}
        )

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:mark_failed, message_hash, reason}, _from, state) do
    case :ets.lookup(state.table_status, message_hash) do
      [{^message_hash, _status, attempts, expires, _reason, created}] ->
        :ets.insert(
          state.table_status,
          {message_hash, :failed, attempts, expires, reason, created}
        )

        {:reply, :ok, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:increment_attempt, message_hash}, _from, state) do
    case :ets.lookup(state.table_status, message_hash) do
      [{^message_hash, status, attempts, expires, reason, created}] ->
        new_attempts = attempts + 1

        if new_attempts > state.max_attempts do
          :ets.insert(
            state.table_status,
            {message_hash, :failed, new_attempts, expires, :max_attempts, created}
          )

          {:reply, {:error, :max_attempts_exceeded}, state}
        else
          :ets.insert(
            state.table_status,
            {message_hash, status, new_attempts, expires, reason, created}
          )

          {:reply, {:ok, new_attempts}, state}
        end

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:propagated_to_peer?, message_hash, peer_hash}, _from, state) do
    result =
      case :ets.lookup(state.table_peers, message_hash) do
        [] -> false
        entries -> Enum.any?(entries, fn {_mh, ph, _ts} -> ph == peer_hash end)
      end

    {:reply, result, state}
  end

  def handle_call({:status, message_hash}, _from, state) do
    case :ets.lookup(state.table_status, message_hash) do
      [{^message_hash, status, attempts, expires, reason, created}] ->
        {:reply,
         {:ok,
          %{
            status: status,
            attempts: attempts,
            expires_at: expires,
            failed_reason: reason,
            created_at: created
          }}, state}

      [] ->
        {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call(:pending, _from, state) do
    pending =
      :ets.select(state.table_status, [
        {{:"$1", :"$2", :_, :_, :_, :_},
         [{:orelse, {:==, :"$2", :pending}, {:==, :"$2", :propagated}}], [:"$1"]}
      ])

    {:reply, pending, state}
  end

  def handle_call(:stats, _from, state) do
    all = :ets.tab2list(state.table_status)

    stats =
      Enum.reduce(
        all,
        %{pending: 0, propagated: 0, delivered: 0, failed: 0, total: length(all)},
        fn
          {_hash, :pending, _, _, _, _}, acc -> Map.update!(acc, :pending, &(&1 + 1))
          {_hash, :propagated, _, _, _, _}, acc -> Map.update!(acc, :propagated, &(&1 + 1))
          {_hash, :delivered, _, _, _, _}, acc -> Map.update!(acc, :delivered, &(&1 + 1))
          {_hash, :failed, _, _, _, _}, acc -> Map.update!(acc, :failed, &(&1 + 1))
        end
      )

    {:reply, stats, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)

    # Remove expired entries
    expired =
      :ets.select(state.table_status, [
        {{:"$1", :_, :_, :"$2", :_, :_}, [{:<, :"$2", now}], [:"$1"]}
      ])

    Enum.each(expired, fn hash ->
      :ets.delete(state.table_status, hash)
      :ets.match_delete(state.table_peers, {hash, :_, :_})
    end)

    timer = Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, %{state | cleanup_timer: timer}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.cleanup_timer, do: Process.cancel_timer(state.cleanup_timer)
    :ok
  end
end
