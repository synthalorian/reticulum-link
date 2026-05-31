defmodule ReticulumLink.Lxmf.MessageStore do
  @moduledoc """
  ETS-backed message storage with TTL expiration and DETS persistence.

  Uses two ETS tables:
  - :messages — key: message_hash, value: {message, expires_at, priority}
  - :priority_index — ordered set for priority queue (priority, inserted_at, hash)

  DETS file provides crash recovery. Messages are persisted on store and
  loaded on init.
  """

  use GenServer

  alias ReticulumLink.Lxmf.Message

  @default_max_messages 10_000
  @default_ttl_seconds 86_400
  @default_max_message_size 65_536
  @cleanup_interval_ms 60_000

  defstruct [
    :table_messages,
    :table_priority,
    :dets_path,
    :max_messages,
    :default_ttl,
    :max_size,
    :cleanup_timer
  ]

  # ── Client API ──────────────────────────────────────────

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Store a message. Returns :ok or {:error, reason}.
  """
  @spec store(GenServer.server(), Message.t(), keyword()) ::
          :ok | {:error, atom()}
  def store(server \\ __MODULE__, %Message{} = msg, opts \\ []) do
    GenServer.call(server, {:store, msg, opts})
  end

  @doc """
  Lookup a message by hash.
  """
  @spec lookup(GenServer.server(), binary()) ::
          {:ok, Message.t()} | {:error, :not_found}
  def lookup(server \\ __MODULE__, hash) do
    GenServer.call(server, {:lookup, hash})
  end

  @doc """
  Delete a message by hash.
  """
  @spec delete(GenServer.server(), binary()) :: :ok
  def delete(server \\ __MODULE__, hash) do
    GenServer.call(server, {:delete, hash})
  end

  @doc """
  Get all stored messages.
  """
  @spec all(GenServer.server()) :: [Message.t()]
  def all(server \\ __MODULE__) do
    GenServer.call(server, :all)
  end

  @doc """
  Get messages sorted by priority (highest first).
  """
  @spec by_priority(GenServer.server(), non_neg_integer()) :: [Message.t()]
  def by_priority(server \\ __MODULE__, limit \\ 100) do
    GenServer.call(server, {:by_priority, limit})
  end

  @doc """
  Count stored messages.
  """
  @spec count(GenServer.server()) :: non_neg_integer()
  def count(server \\ __MODULE__) do
    GenServer.call(server, :count)
  end

  @doc """
  Purge expired messages immediately.
  """
  @spec purge_expired(GenServer.server()) :: non_neg_integer()
  def purge_expired(server \\ __MODULE__) do
    GenServer.call(server, :purge_expired)
  end

  # ── Server Callbacks ────────────────────────────────────

  @impl true
  def init(opts) do
    max_messages = Keyword.get(opts, :max_messages, @default_max_messages)
    default_ttl = Keyword.get(opts, :default_ttl, @default_ttl_seconds)
    max_size = Keyword.get(opts, :max_message_size, @default_max_message_size)
    dets_path = Keyword.get(opts, :dets_path, default_dets_path())

    # Ensure directory exists
    dets_path |> Path.dirname() |> File.mkdir_p!()

    # Open DETS
    {:ok, dets} = :dets.open_file(:message_store_dets, file: to_charlist(dets_path), type: :set)

    # Create ETS tables (unnamed, ref in state)
    messages_table = :ets.new(:messages, [:set, :protected, read_concurrency: true])
    priority_table = :ets.new(:priority_index, [:ordered_set, :protected])

    state = %__MODULE__{
      table_messages: messages_table,
      table_priority: priority_table,
      dets_path: dets_path,
      max_messages: max_messages,
      default_ttl: default_ttl,
      max_size: max_size,
      cleanup_timer: nil
    }

    # Load persisted messages from DETS
    state = load_from_dets(state, dets)

    :dets.close(dets)

    # Start cleanup timer
    timer = Process.send_after(self(), :cleanup, @cleanup_interval_ms)

    {:ok, %{state | cleanup_timer: timer}}
  end

  @impl true
  def handle_call({:store, %Message{} = msg, opts}, _from, state) do
    hash = msg.hash || Message.message_id(msg)

    cond do
      hash == nil ->
        {:reply, {:error, :no_hash}, state}

      byte_size(msg.packed || "") > state.max_size ->
        {:reply, {:error, :message_too_large}, state}

      true ->
        ttl = Keyword.get(opts, :ttl, state.default_ttl)
        priority = Keyword.get(opts, :priority, 0)
        expires_at = System.system_time(:second) + ttl

        # Evict oldest if at capacity
        state = maybe_evict_oldest(state)

        # Insert into ETS
        :ets.insert(state.table_messages, {hash, msg, expires_at, priority})
        :ets.insert(state.table_priority, {{priority, System.system_time(:millisecond), hash}})

        # Persist to DETS
        persist_message(state, hash, msg, expires_at, priority)

        {:reply, :ok, state}
    end
  end

  def handle_call({:lookup, hash}, _from, state) do
    case :ets.lookup(state.table_messages, hash) do
      [{^hash, msg, _expires_at, _priority}] -> {:reply, {:ok, msg}, state}
      [] -> {:reply, {:error, :not_found}, state}
    end
  end

  def handle_call({:delete, hash}, _from, state) do
    case :ets.lookup(state.table_messages, hash) do
      [{^hash, _msg, _expires_at, priority}] ->
        # Delete from both tables
        :ets.delete(state.table_messages, hash)

        # Delete from priority index (need to find the exact key)
        delete_from_priority(state.table_priority, hash, priority)

        # Delete from DETS
        delete_from_dets(state, hash)

        {:reply, :ok, state}

      [] ->
        {:reply, :ok, state}
    end
  end

  def handle_call(:all, _from, state) do
    messages =
      :ets.tab2list(state.table_messages)
      |> Enum.map(fn {_hash, msg, _expires_at, _priority} -> msg end)

    {:reply, messages, state}
  end

  def handle_call({:by_priority, limit}, _from, state) do
    messages =
      :ets.select(state.table_priority, [{{{:"$1", :"$2", :"$3"}}, [], [:"$3"]}], limit)
      |> elem(0)
      |> Enum.map(fn hash ->
        case :ets.lookup(state.table_messages, hash) do
          [{^hash, msg, _expires_at, _priority}] -> msg
          [] -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)

    {:reply, messages, state}
  end

  def handle_call(:count, _from, state) do
    count = :ets.info(state.table_messages, :size)
    {:reply, count, state}
  end

  def handle_call(:purge_expired, _from, state) do
    now = System.system_time(:second)
    deleted = do_purge_expired(state, now)
    {:reply, deleted, state}
  end

  @impl true
  def handle_info(:cleanup, state) do
    now = System.system_time(:second)
    _deleted = do_purge_expired(state, now)

    timer = Process.send_after(self(), :cleanup, @cleanup_interval_ms)
    {:noreply, %{state | cleanup_timer: timer}}
  end

  @impl true
  def terminate(_reason, state) do
    if state.cleanup_timer, do: Process.cancel_timer(state.cleanup_timer)
    :ok
  end

  # ── Private ─────────────────────────────────────────────

  defp default_dets_path do
    Path.join([System.user_home!(), ".reticulum_link", "messages.dets"])
  end

  defp maybe_evict_oldest(state) do
    count = :ets.info(state.table_messages, :size)

    if count >= state.max_messages do
      # Remove oldest (lowest priority, earliest inserted)
      case :ets.first(state.table_priority) do
        :"$end_of_table" ->
          state

        first_key ->
          {_priority, _ts, hash} = first_key
          :ets.delete(state.table_priority, first_key)
          :ets.delete(state.table_messages, hash)
          delete_from_dets(state, hash)
          state
      end
    else
      state
    end
  end

  defp do_purge_expired(state, now) do
    # Find all expired entries
    expired =
      :ets.select(state.table_messages, [
        {{:"$1", :_, :"$2", :_}, [{:<, :"$2", now}], [:"$1"]}
      ])

    Enum.each(expired, fn hash ->
      case :ets.lookup(state.table_messages, hash) do
        [{^hash, _msg, _expires_at, priority}] ->
          :ets.delete(state.table_messages, hash)
          delete_from_priority(state.table_priority, hash, priority)
          delete_from_dets(state, hash)

        [] ->
          :ok
      end
    end)

    length(expired)
  end

  defp delete_from_priority(table, hash, priority) do
    # Find and delete the exact key from ordered_set
    # Since we don't know the exact timestamp, we scan
    match_spec = [{{{:"$1", :"$2", :"$3"}}, [{:==, :"$1", priority}, {:==, :"$3", hash}], [true]}]
    :ets.select_delete(table, match_spec)
  end

  defp persist_message(state, hash, msg, expires_at, priority) do
    dets_path = to_charlist(state.dets_path)
    {:ok, dets} = :dets.open_file(:message_store_dets_write, file: dets_path, type: :set)
    record = {hash, :erlang.term_to_binary({msg, expires_at, priority})}
    :dets.insert(dets, record)
    :dets.close(dets)
  end

  defp delete_from_dets(state, hash) do
    dets_path = to_charlist(state.dets_path)
    {:ok, dets} = :dets.open_file(:message_store_dets_delete, file: dets_path, type: :set)
    :dets.delete(dets, hash)
    :dets.close(dets)
  end

  defp load_from_dets(state, dets) do
    case :dets.first(dets) do
      :"$end_of_table" ->
        state

      _first ->
        do_fold_dets(state, dets)
    end
  end

  defp do_fold_dets(state, dets) do
    :dets.foldl(
      fn {hash, binary}, acc_state ->
        {msg, expires_at, priority} = :erlang.binary_to_term(binary)
        maybe_insert_loaded(acc_state, hash, msg, expires_at, priority)
      end,
      state,
      dets
    )
  end

  defp maybe_insert_loaded(state, hash, msg, expires_at, priority) do
    now = System.system_time(:second)

    if expires_at > now do
      :ets.insert(state.table_messages, {hash, msg, expires_at, priority})
      :ets.insert(state.table_priority, {{priority, 0, hash}})
      state
    else
      state
    end
  end
end
