defmodule ReticulumLink.Crypto.IdentityManager do
  @moduledoc """
  Identity manager — a GenServer that manages node identity, persistence,
  and lifecycle.

  Stores the Ed25519 keypair and X25519 keypair on disk (in the application
  data directory), with automatic recovery if the node is restarted.

  ## Process tree

  The IdentityManager is started as part of the application supervisor.
  It owns the node's cryptographic identity and provides access to keys
  for other modules.

  ## Configuration

  Configuration is read from the application environment:

      config :reticulum_link, ReticulumLink.Crypto.IdentityManager,
        data_dir: "/var/lib/reticulum-link",
        key_file: "identity.key",
        auto_generate: true

  If `auto_generate: true` (default), a new keypair is generated if no
  existing key file is found. Set to `false` to require pre-existing keys.
  """

  use GenServer

  @type identity() :: %{
          ed25519_secret: binary(),
          ed25519_public: binary(),
          x25519_secret: binary(),
          x25519_public: binary()
        }

  @default_data_dir "/var/lib/reticulum-link"
  @default_key_file "identity.key"
  @default_auto_generate true

  # ===========================================================================
  # Client API
  # ===========================================================================

  @doc """
  Start the IdentityManager GenServer.

  ## Options

  * `:data_dir` — Directory for storing identity keys (default: `/var/lib/reticulum-link`)
  * `:key_file` — Key file name (default: `identity.key`)
  * `:auto_generate` — Generate new keys if none exist (default: `true`)
  """
  @spec start_link(Keyword.t()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, opts, name: name)
  end

  @doc """
  Get the current node identity.

  Returns `{:ok, identity}` with all key material, or `{:error, reason}`
  if the identity hasn't been loaded yet.

  ## Examples

      iex> {:ok, identity} = ReticulumLink.Crypto.IdentityManager.identity()
      iex> Map.has_key?(identity, :ed25519_secret)
      true
      iex> byte_size(identity.ed25519_secret)
      32
  """
  @spec identity() :: {:ok, identity()} | {:error, atom()}
  def identity() do
    GenServer.call(__MODULE__, :identity)
  end

  @doc """
  Get the Ed25519 public key as a hex string.

  ## Examples

      iex> {:ok, pk_hex} = ReticulumLink.Crypto.IdentityManager.public_key_hex()
      iex> String.length(pk_hex)
      64
  """
  @spec public_key_hex() :: {:ok, String.t()} | {:error, atom()}
  def public_key_hex() do
    GenServer.call(__MODULE__, :public_key_hex)
  end

  @doc """
  Get the X25519 public key as a hex string.

  ## Examples

      iex> {:ok, xpk_hex} = ReticulumLink.Crypto.IdentityManager.x25519_public_key_hex()
      iex> String.length(xpk_hex)
      64
  """
  @spec x25519_public_key_hex() :: {:ok, String.t()} | {:error, atom()}
  def x25519_public_key_hex() do
    GenServer.call(__MODULE__, :x25519_public_key_hex)
  end

  @doc """
  Rotate the node's identity.

  Generates a new keypair and persists it. The old identity is discarded.

  ## Returns

  `{:ok, new_identity}` with the new key material.

  ## Examples

      iex> {:ok, old_id} = ReticulumLink.Crypto.IdentityManager.identity()
      iex> {:ok, new_id} = ReticulumLink.Crypto.IdentityManager.rotate()
      iex> old_id.ed25519_secret != new_id.ed25519_secret
      true
  """
  @spec rotate() :: {:ok, identity()} | {:error, atom()}
  def rotate() do
    GenServer.call(__MODULE__, :rotate)
  end

  # ===========================================================================
  # Server callbacks
  # ===========================================================================

  @impl true
  def init(opts) do
    data_dir = Keyword.get(opts, :data_dir, @default_data_dir)
    key_file = Keyword.get(opts, :key_file, @default_key_file)
    auto_generate = Keyword.get(opts, :auto_generate, @default_auto_generate)

    state = %{
      data_dir: data_dir,
      key_file: key_file,
      auto_generate: auto_generate,
      identity: nil
    }

    # Try to load existing identity
    case load_identity(state) do
      {:ok, identity} ->
        {:ok, Map.put(state, :identity, identity)}

      {:error, :no_key_file} when auto_generate ->
        init_generate_identity(state)

      {:error, :no_key_file} when not auto_generate ->
        {:stop, :no_key_file_and_auto_generate_disabled}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp init_generate_identity(state) do
    case generate_identity() do
      {:ok, identity} ->
        _ = save_identity(state, identity)
        {:ok, Map.put(state, :identity, identity)}
    end
  end

  @impl true
  def handle_call(:identity, _from, state) do
    case state.identity do
      nil ->
        {:reply, {:error, :identity_not_loaded}, state}

      identity ->
        {:reply, {:ok, identity}, state}
    end
  end

  @impl true
  def handle_call(:public_key_hex, _from, state) do
    case state.identity do
      nil ->
        {:reply, {:error, :identity_not_loaded}, state}

      identity ->
        hex = Base.encode16(identity.ed25519_public, case: :lower)
        {:reply, {:ok, hex}, state}
    end
  end

  @impl true
  def handle_call(:x25519_public_key_hex, _from, state) do
    case state.identity do
      nil ->
        {:reply, {:error, :identity_not_loaded}, state}

      identity ->
        hex = Base.encode16(identity.x25519_public, case: :lower)
        {:reply, {:ok, hex}, state}
    end
  end

  @impl true
  def handle_call(:rotate, _from, state) do
    case generate_identity() do
      {:ok, identity} ->
        _ = save_identity(state, identity)
        {:reply, {:ok, identity}, Map.put(state, :identity, identity)}
    end
  end

  @impl true
  def handle_cast(:reload, state) do
    case load_identity(state) do
      {:ok, identity} ->
        {:noreply, Map.put(state, :identity, identity)}

      {:error, _} ->
        {:noreply, state}
    end
  end

  # ===========================================================================
  # Internal helpers
  # ===========================================================================

  defp load_identity(%{data_dir: data_dir, key_file: key_file}) do
    key_path = Path.join(data_dir, key_file)

    case File.read(key_path) do
      {:ok, data} ->
        decode_identity(data)

      {:error, :enoent} ->
        {:error, :no_key_file}

      {:error, _} ->
        {:error, :file_read_error}
    end
  end

  defp save_identity(%{data_dir: data_dir, key_file: key_file}, identity) do
    key_path = Path.join(data_dir, key_file)

    # Ensure directory exists
    case File.mkdir_p(data_dir) do
      :ok ->
        # Write as JSON for portability
        json = encode_identity(identity)

        # Atomic write: write to temp file then rename
        temp_path = key_path <> ".tmp"

        case File.write(temp_path, json) do
          :ok ->
            File.rename(temp_path, key_path)
            :ok

          {:error, _} ->
            File.rm(temp_path)
            {:error, :file_write_error}
        end

      {:error, _} ->
        {:error, :mkdir_failed}
    end
  end

  defp generate_identity() do
    with {:ok, {ed_sk, ed_pk}} <- ReticulumLink.Crypto.Identity.generate_keypair(),
         {:ok, xsk} <- ReticulumLink.Crypto.Identity.to_curve25519(ed_sk, :secret),
         {:ok, xpk} <- ReticulumLink.Crypto.Identity.to_curve25519(ed_pk, :public) do
      {:ok,
       %{
         ed25519_secret: ed_sk,
         ed25519_public: ed_pk,
         x25519_secret: xsk,
         x25519_public: xpk
       }}
    else
      error -> error
    end
  end

  defp decode_identity(json) do
    case Jason.decode(json) do
      {:ok, map} ->
        ed_sk = Base.decode16!(map["ed25519_secret"], case: :lower)
        ed_pk = Base.decode16!(map["ed25519_public"], case: :lower)
        xsk = Base.decode16!(map["x25519_secret"], case: :lower)
        xpk = Base.decode16!(map["x25519_public"], case: :lower)

        identity = %{
          ed25519_secret: ed_sk,
          ed25519_public: ed_pk,
          x25519_secret: xsk,
          x25519_public: xpk
        }

        {:ok, identity}

      {:error, _} ->
        {:error, :json_decode_error}
    end
  end

  defp encode_identity(identity) do
    Jason.encode!(%{
      "ed25519_secret" => Base.encode16(identity.ed25519_secret, case: :lower),
      "ed25519_public" => Base.encode16(identity.ed25519_public, case: :lower),
      "x25519_secret" => Base.encode16(identity.x25519_secret, case: :lower),
      "x25519_public" => Base.encode16(identity.x25519_public, case: :lower)
    })
  end
end
