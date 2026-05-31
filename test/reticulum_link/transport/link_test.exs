defmodule ReticulumLink.Transport.LinkTest do
  use ExUnit.Case, async: true

  alias ReticulumLink.Transport.{Link, LinkManager, PathManager}

  describe "Link lifecycle" do
    test "initiator link starts in pending state" do
      dst_hash = :crypto.strong_rand_bytes(16)
      {:ok, pid} = Link.start_link_initiator(dst_hash, name: :test_link_init)

      assert Link.status(pid) == :pending
      info = Link.info(pid)
      assert info.initiator == true
      assert info.destination_hash == dst_hash
      assert info.status == :pending

      Link.close(pid)
    end

    test "responder link starts in handshake state" do
      dst_hash = :crypto.strong_rand_bytes(16)
      peer_pub = :crypto.strong_rand_bytes(32)
      peer_sig_pub = :crypto.strong_rand_bytes(32)

      {:ok, pid} =
        Link.start_link_responder(dst_hash, peer_pub, peer_sig_pub, name: :test_link_resp)

      assert Link.status(pid) == :handshake
      info = Link.info(pid)
      assert info.initiator == false
      assert info.destination_hash == dst_hash

      Link.close(pid)
    end

    test "link info returns correct structure" do
      dst_hash = :crypto.strong_rand_bytes(16)
      {:ok, pid} = Link.start_link_initiator(dst_hash, name: :test_link_info)

      info = Link.info(pid)
      assert is_map(info)
      assert Map.has_key?(info, :status)
      assert Map.has_key?(info, :mtu)
      assert Map.has_key?(info, :mdu)
      assert Map.has_key?(info, :tx)
      assert Map.has_key?(info, :rx)
      assert info.tx == 0
      assert info.rx == 0

      Link.close(pid)
    end

    test "send_data fails when link is not active" do
      dst_hash = :crypto.strong_rand_bytes(16)
      {:ok, pid} = Link.start_link_initiator(dst_hash, name: :test_link_send)

      assert {:error, :link_not_active} = Link.send_data(pid, "hello")
      Link.close(pid)
    end

    test "close transitions link to closed" do
      dst_hash = :crypto.strong_rand_bytes(16)
      {:ok, pid} = Link.start_link_initiator(dst_hash, name: :test_link_close)

      assert :ok = Link.close(pid)
      # Process should be stopping
      refute Process.alive?(pid)
    end
  end

  describe "LinkManager" do
    test "starts and manages links" do
      {:ok, _lm} = LinkManager.start_link(name: :test_lm)

      dst_hash = :crypto.strong_rand_bytes(16)
      {:ok, link_pid} = LinkManager.start_link_initiator(dst_hash)

      assert is_pid(link_pid)
      assert LinkManager.link_count() >= 1

      DynamicSupervisor.stop(:test_lm)
    end

    test "terminates a link" do
      {:ok, _lm} = LinkManager.start_link(name: :test_lm2)

      dst_hash = :crypto.strong_rand_bytes(16)
      {:ok, link_pid} = LinkManager.start_link_initiator(dst_hash)

      assert :ok = LinkManager.terminate_link(link_pid)
      DynamicSupervisor.stop(:test_lm2)
    end
  end

  describe "PathManager" do
    test "registers and looks up paths" do
      {:ok, _pm} = PathManager.start_link(name: :test_pm)

      dst_hash = :crypto.strong_rand_bytes(16)
      transport_id = :crypto.strong_rand_bytes(16)

      :ok = PathManager.register_path(dst_hash, transport_id, 3, 3600)

      assert PathManager.has_path?(dst_hash)
      {:ok, entry} = PathManager.lookup_path(dst_hash)
      assert entry.hops == 3
      assert entry.transport_id == transport_id

      GenServer.stop(:test_pm)
    end

    test "returns error for unknown destination" do
      {:ok, _pm} = PathManager.start_link(name: :test_pm2)

      dst_hash = :crypto.strong_rand_bytes(16)
      assert {:error, :no_path} = PathManager.lookup_path(dst_hash)

      GenServer.stop(:test_pm2)
    end

    test "deletes a path" do
      {:ok, _pm} = PathManager.start_link(name: :test_pm3)

      dst_hash = :crypto.strong_rand_bytes(16)
      :ok = PathManager.register_path(dst_hash, nil, 1, 3600)
      assert PathManager.has_path?(dst_hash)

      :ok = PathManager.delete_path(dst_hash)
      refute PathManager.has_path?(dst_hash)

      GenServer.stop(:test_pm3)
    end
  end
end
