defmodule ReticulumLink.Transport.Link do
  @moduledoc """
  Reticulum encrypted link GenServer.

  Manages the lifecycle of a single encrypted link:

      PENDING → HANDSHAKE → ACTIVE → STALE → CLOSED

  ## Link establishment

  1. **Initiator** generates ephemeral X25519/Ed25519 keypair
  2. Sends LINKREQUEST packet with public keys + optional MTU signalling
  3. **Responder** validates request, generates own ephemeral keys
  4. Both sides perform X25519 ECDH → shared secret
  5. Derive AES keys via HKDF
  6. Exchange proofs (signed link_id + pubkeys)
  7. Link is ACTIVE — encrypted data can flow

  ## Keepalive

  Links send periodic keepalive packets. If no traffic received within
  `stale_time` seconds, the link transitions to STALE. If still no
  traffic after `timeout`, the link closes.

  ## State

  * `:pending`    — Link request sent, awaiting response
  * `:handshake`  — Keys exchanged, deriving shared secret
  * `:active`     — Link established, encrypted traffic flowing
  * `:stale`      — No recent traffic, may recover
  * `:closed`     — Link terminated
  """

  use GenServer

  alias ReticulumLink.Crypto.{Cipher, Hash, Identity, KeyExchange}

  require Logger

  # Timing constants (seconds)
  @keepalive 360
  @keepalive_min 5
  @stale_time 720
  @timeout 900
  @establishment_timeout_per_hop 6

  # Proof structure: <<link_id::16, peer_x25519_pub::32, peer_ed25519_pub::32, signature::64>>
  @proof_size 16 + 32 + 32 + 64

  @typedoc "Link state"
  @type status :: :pending | :handshake | :active | :stale | :closed

  @typedoc "Link struct / state"
  @type t :: %__MODULE__{
          link_id: binary() | nil,
          status: status(),
          initiator: boolean(),
          destination_hash: binary(),
          peer_pub: binary() | nil,
          peer_sig_pub: binary() | nil,
          shared_key: binary() | nil,
          derived_key: binary() | nil,
          mtu: non_neg_integer(),
          mdu: non_neg_integer(),
          rtt: float() | nil,
          last_inbound: DateTime.t() | nil,
          last_outbound: DateTime.t() | nil,
          establishment_timeout: non_neg_integer(),
          tx: non_neg_integer(),
          rx: non_neg_integer(),
          tx_bytes: non_neg_integer(),
          rx_bytes: non_neg_integer()
        }

  defstruct [
    :link_id,
    :status,
    :initiator,
    :destination_hash,
    :peer_pub,
    :peer_sig_pub,
    :shared_key,
    :derived_key,
    :mtu,
    :mdu,
    :rtt,
    :last_inbound,
    :last_outbound,
    :establishment_timeout,
    tx: 0,
    rx: 0,
    tx_bytes: 0,
    rx_bytes: 0
  ]

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start a link as initiator (outbound).

  ## Parameters

  * `destination_hash` — Target destination hash
  * `opts` — Options:
    * `:name` — Process name
    * `:mtu` — Link MTU (default: 500)
    * `:keys` — Pre-generated key bundle (see `generate_keys/0`).
      If not provided, keys are generated inside the process (slower, larger heap).
  """
  @spec start_link_initiator(binary(), Keyword.t()) :: GenServer.on_start()
  def start_link_initiator(destination_hash, opts \\ []) do
    name = Keyword.get(opts, :name, generate_link_name())
    keys = Keyword.get(opts, :keys)

    init_args =
      if keys do
        %{
          mode: :initiator,
          destination_hash: destination_hash,
          mtu: Keyword.get(opts, :mtu, 500),
          name: name,
          keys: keys
        }
      else
        %{
          mode: :initiator,
          destination_hash: destination_hash,
          mtu: Keyword.get(opts, :mtu, 500),
          name: name
        }
      end

    GenServer.start_link(__MODULE__, init_args, name: name)
  end

  @doc """
  Start a link as responder (inbound).

  Called when a LINKREQUEST packet is received.
  """
  @spec start_link_responder(binary(), binary(), binary(), Keyword.t()) :: GenServer.on_start()
  def start_link_responder(destination_hash, peer_pub, peer_sig_pub, opts \\ []) do
    name = Keyword.get(opts, :name, generate_link_name())
    keys = Keyword.get(opts, :keys)

    init_args =
      %{
        mode: :responder,
        destination_hash: destination_hash,
        peer_pub: peer_pub,
        peer_sig_pub: peer_sig_pub,
        mtu: Keyword.get(opts, :mtu, 500),
        name: name
      }

    init_args = if keys, do: Map.put(init_args, :keys, keys), else: init_args

    GenServer.start_link(__MODULE__, init_args, name: name)
  end

  @doc """
  Generate a key bundle for link creation.

  Returns a map with pre-derived keys that can be passed to
  `start_link_initiator/2` or `start_link_responder/4` via
  the `:keys` option to avoid heap bloat from in-process crypto.
  """
  @spec generate_keys() :: map()
  def generate_keys do
    {:ok, {ephemeral_sk, ephemeral_pk}} = Identity.generate_keypair()
    {:ok, {sig_sk, sig_pk}} = Identity.generate_keypair()
    {x25519_sk, x25519_pk} = KeyExchange.derive_keypair!(ephemeral_sk, ephemeral_pk)
    link_id = Hash.sha256(ephemeral_pk <> sig_pk) |> binary_part(0, 16)

    %{
      link_id: link_id,
      ephemeral_sk: ephemeral_sk,
      ephemeral_pk: ephemeral_pk,
      sig_sk: sig_sk,
      sig_pk: sig_pk,
      x25519_sk: x25519_sk,
      x25519_pk: x25519_pk
    }
  end

  @doc """
  Get link status.
  """
  @spec status(atom()) :: status()
  def status(name) do
    GenServer.call(name, :status)
  end

  @doc """
  Get link info (full state snapshot).
  """
  @spec info(atom()) :: map()
  def info(name) do
    GenServer.call(name, :info)
  end

  @doc """
  Send data over the link.

  Returns `:ok` on success, `{:error, reason}` if link not active.
  """
  @spec send_data(atom(), binary()) :: :ok | {:error, atom()}
  def send_data(name, data) when is_binary(data) do
    GenServer.call(name, {:send_data, data})
  end

  @doc """
  Receive data from the link (called by transport layer).
  """
  @spec receive_data(atom(), binary()) :: :ok
  def receive_data(name, data) when is_binary(data) do
    GenServer.cast(name, {:receive_data, data})
  end

  @doc """
  Generate a link proof (LRPROOF) for handshake completion.

  The proof is a signed attestation of the link_id and peer public keys,
  proving possession of the ephemeral signing key.

  ## Proof format

      <<link_id::binary-size(16),
        x25519_public::binary-size(32),
        ed25519_public::binary-size(32),
        signature::binary-size(64)>>

  Total: 144 bytes
  """
  @spec generate_proof(atom()) :: {:ok, binary()} | {:error, atom()}
  def generate_proof(name) do
    GenServer.call(name, :generate_proof)
  end

  @doc """
  Process a link proof (LRPROOF packet) from the peer.

  Validates the proof signature and transitions the link to ACTIVE
  if the proof is cryptographically valid.
  """
  @spec handle_proof(atom(), binary()) :: :ok | {:error, atom()}
  def handle_proof(name, proof_data) when is_binary(proof_data) do
    GenServer.call(name, {:handle_proof, proof_data})
  end

  @doc """
  Close the link.
  """
  @spec close(atom()) :: :ok
  def close(name) do
    GenServer.call(name, :close)
  end

  # ===========================================================================
  # Server callbacks
  # ===========================================================================

  @impl true
  def init(%{mode: :initiator, destination_hash: dst_hash} = args) do
    keys = Map.get(args, :keys)

    {link_id, ephemeral_sk, ephemeral_pk, sig_sk, sig_pk, x25519_sk, x25519_pk} =
      if keys do
        {
          keys.link_id,
          keys.ephemeral_sk,
          keys.ephemeral_pk,
          keys.sig_sk,
          keys.sig_pk,
          keys.x25519_sk,
          keys.x25519_pk
        }
      else
        {:ok, {esk, epk}} = Identity.generate_keypair()
        {:ok, {ssk, spk}} = Identity.generate_keypair()
        {xsk, xpk} = KeyExchange.derive_keypair!(esk, epk)
        lid = Hash.sha256(epk <> spk) |> binary_part(0, 16)
        {lid, esk, epk, ssk, spk, xsk, xpk}
      end

    state = %__MODULE__{
      link_id: link_id,
      status: :pending,
      initiator: true,
      destination_hash: dst_hash,
      mtu: args.mtu,
      mdu: calculate_mdu(args.mtu),
      establishment_timeout: @establishment_timeout_per_hop + @keepalive
    }

    # Store keys in process dictionary (sensitive, don't log)
    Process.put(:ephemeral_sk, ephemeral_sk)
    Process.put(:ephemeral_pk, ephemeral_pk)
    Process.put(:sig_sk, sig_sk)
    Process.put(:sig_pk, sig_pk)
    Process.put(:x25519_sk, x25519_sk)
    Process.put(:x25519_pk, x25519_pk)

    # Start watchdog timer
    schedule_watchdog(self())

    {:ok, state}
  end

  @impl true
  def init(
        %{
          mode: :responder,
          destination_hash: dst_hash,
          peer_pub: peer_pub,
          peer_sig_pub: peer_sig_pub
        } = args
      ) do
    keys = Map.get(args, :keys)

    {link_id, ephemeral_sk, ephemeral_pk, sig_sk, sig_pk, x25519_sk, x25519_pk} =
      if keys do
        {
          keys.link_id,
          keys.ephemeral_sk,
          keys.ephemeral_pk,
          keys.sig_sk,
          keys.sig_pk,
          keys.x25519_sk,
          keys.x25519_pk
        }
      else
        {:ok, {esk, epk}} = Identity.generate_keypair()
        {:ok, {ssk, spk}} = Identity.generate_keypair()
        {xsk, xpk} = KeyExchange.derive_keypair!(esk, epk)
        lid = Hash.sha256(epk <> spk) |> binary_part(0, 16)
        {lid, esk, epk, ssk, spk, xsk, xpk}
      end

    state = %__MODULE__{
      link_id: link_id,
      status: :handshake,
      initiator: false,
      destination_hash: dst_hash,
      peer_pub: peer_pub,
      peer_sig_pub: peer_sig_pub,
      mtu: args.mtu,
      mdu: calculate_mdu(args.mtu),
      establishment_timeout: @establishment_timeout_per_hop + @keepalive
    }

    Process.put(:ephemeral_sk, ephemeral_sk)
    Process.put(:ephemeral_pk, ephemeral_pk)
    Process.put(:sig_sk, sig_sk)
    Process.put(:sig_pk, sig_pk)
    Process.put(:x25519_sk, x25519_sk)
    Process.put(:x25519_pk, x25519_pk)

    # Perform handshake immediately
    new_state = perform_handshake(state)

    schedule_watchdog(self())
    {:ok, new_state}
  end

  @impl true
  def handle_call(:status, _from, state) do
    {:reply, state.status, state}
  end

  @impl true
  def handle_call(:info, _from, state) do
    info = %{
      link_id: state.link_id,
      status: state.status,
      initiator: state.initiator,
      destination_hash: state.destination_hash,
      mtu: state.mtu,
      mdu: state.mdu,
      rtt: state.rtt,
      tx: state.tx,
      rx: state.rx,
      tx_bytes: state.tx_bytes,
      rx_bytes: state.rx_bytes
    }

    {:reply, info, state}
  end

  @impl true
  def handle_call({:send_data, data}, _from, %{status: :active} = state) do
    # Encrypt data with derived key
    encrypted = encrypt_for_link(state, data)

    new_state = %{
      state
      | tx: state.tx + 1,
        tx_bytes: state.tx_bytes + byte_size(data),
        last_outbound: DateTime.utc_now()
    }

    {:reply, {:ok, encrypted}, new_state}
  end

  @impl true
  def handle_call({:send_data, _data}, _from, state) do
    {:reply, {:error, :link_not_active}, state}
  end

  @impl true
  def handle_call(:generate_proof, _from, %{status: status} = state)
      when status in [:pending, :handshake] do
    sig_sk = Process.get(:sig_sk)
    x25519_pk = Process.get(:x25519_pk)
    sig_pk = Process.get(:sig_pk)
    link_id = state.link_id

    if sig_sk && x25519_pk && sig_pk && link_id do
      # Sign: link_id || x25519_pk || ed25519_pk
      data_to_sign = link_id <> x25519_pk <> sig_pk
      signature = Identity.sign(data_to_sign, sig_sk)

      proof = link_id <> x25519_pk <> sig_pk <> signature
      {:reply, {:ok, proof}, state}
    else
      {:reply, {:error, :missing_keys}, state}
    end
  end

  @impl true
  def handle_call(:generate_proof, _from, state) do
    {:reply, {:error, :invalid_link_state}, state}
  end

  @impl true
  def handle_call({:handle_proof, proof_data}, _from, %{status: :handshake} = state) do
    case validate_proof(state, proof_data) do
      :ok ->
        new_state = %{state | status: :active, last_inbound: DateTime.utc_now()}
        Logger.debug("Link #{link_id_short(state.link_id)} established")
        {:reply, :ok, new_state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  @impl true
  def handle_call({:handle_proof, _proof_data}, _from, state) do
    {:reply, {:error, :invalid_link_state}, state}
  end

  @impl true
  def handle_call(:close, _from, state) do
    new_state = %{state | status: :closed}
    {:stop, :normal, :ok, new_state}
  end

  @impl true
  def handle_cast({:receive_data, data}, %{status: :active} = state) do
    case decrypt_from_link(state, data) do
      {:ok, plaintext} ->
        new_state = %{
          state
          | rx: state.rx + 1,
            rx_bytes: state.rx_bytes + byte_size(plaintext),
            last_inbound: DateTime.utc_now()
        }

        {:noreply, new_state}

      {:error, _reason} ->
        {:noreply, state}
    end
  end

  @impl true
  def handle_cast({:receive_data, _data}, state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:watchdog, %{status: :closed} = state) do
    {:noreply, state}
  end

  @impl true
  def handle_info(:watchdog, state) do
    now = DateTime.utc_now()

    stale_at =
      if state.last_inbound do
        DateTime.add(state.last_inbound, @stale_time, :second)
      else
        DateTime.add(now, @stale_time, :second)
      end

    timeout_at =
      if state.last_inbound do
        DateTime.add(state.last_inbound, @timeout, :second)
      else
        DateTime.add(now, @timeout, :second)
      end

    cond do
      DateTime.compare(now, timeout_at) == :gt ->
        Logger.debug("Link timed out, closing")
        {:stop, :normal, %{state | status: :closed}}

      DateTime.compare(now, stale_at) == :gt and state.status == :active ->
        {:noreply, %{state | status: :stale}}

      true ->
        schedule_watchdog(self())
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(_msg, state) do
    {:noreply, state}
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp perform_handshake(state) do
    x25519_sk = Process.get(:x25519_sk)
    peer_pub = state.peer_pub

    if x25519_sk && peer_pub do
      {:ok, shared_key} = KeyExchange.derive_shared_secret(x25519_sk, peer_pub)

      derived_key = derive_link_key(shared_key, state.link_id)

      %{state | shared_key: shared_key, derived_key: derived_key, status: :handshake}
    else
      state
    end
  end

  defp derive_link_key(shared_key, link_id) do
    salt = if link_id, do: link_id, else: :binary.copy(<<0>>, 16)
    Hash.hkdf(shared_key, salt, "reticulum-link", 32)
  end

  defp encrypt_for_link(%{derived_key: key}, data) when is_binary(key) do
    {:ok, encrypted} = Cipher.encrypt_with_nonce(data, key)
    encrypted
  end

  defp decrypt_from_link(%{derived_key: key}, data) when is_binary(key) do
    Cipher.decrypt_with_nonce(data, key)
  end

  defp validate_proof(state, proof_data) when byte_size(proof_data) == @proof_size do
    <<link_id::binary-size(16), peer_x25519_pub::binary-size(32),
      peer_ed25519_pub::binary-size(32), signature::binary-size(64)>> = proof_data

    # Verify link_id matches
    if link_id != state.link_id do
      {:error, :link_id_mismatch}
    else
      verify_proof_signature(state, link_id, peer_x25519_pub, peer_ed25519_pub, signature)
    end
  end

  defp validate_proof(_state, proof_data) do
    {:error, {:invalid_proof_size, byte_size(proof_data)}}
  end

  defp verify_proof_signature(state, link_id, peer_x25519_pub, peer_ed25519_pub, signature) do
    data = link_id <> peer_x25519_pub <> peer_ed25519_pub

    if Identity.verify(data, signature, peer_ed25519_pub) do
      store_peer_keys(peer_x25519_pub, peer_ed25519_pub)
      derive_shared_key(state.link_id, peer_x25519_pub)
      :ok
    else
      {:error, :invalid_signature}
    end
  end

  defp store_peer_keys(peer_x25519_pub, peer_ed25519_pub) do
    Process.put(:peer_x25519_pub, peer_x25519_pub)
    Process.put(:peer_ed25519_pub, peer_ed25519_pub)
  end

  defp derive_shared_key(link_id, peer_x25519_pub) do
    x25519_sk = Process.get(:x25519_sk)

    if x25519_sk && peer_x25519_pub do
      {:ok, shared_key} = KeyExchange.derive_shared_secret(x25519_sk, peer_x25519_pub)
      derived_key = derive_link_key(shared_key, link_id)
      Process.put(:shared_key, shared_key)
      Process.put(:derived_key, derived_key)
    end
  end

  defp calculate_mdu(mtu) do
    # Link MDU = MTU - header overhead
    max(mtu - 35 - 16, 0)
  end

  defp schedule_watchdog(pid) do
    Process.send_after(pid, :watchdog, @keepalive_min * 1000)
  end

  defp generate_link_name do
    :"link_#{System.unique_integer([:positive])}"
  end

  defp link_id_short(nil), do: "nil"

  defp link_id_short(link_id) when is_binary(link_id) do
    Base.encode16(binary_part(link_id, 0, min(4, byte_size(link_id))), case: :lower)
  end
end
