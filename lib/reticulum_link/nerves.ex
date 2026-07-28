defmodule ReticulumLink.Nerves do
  @moduledoc """
  Nerves-specific runtime configuration and hardware integration.

  This module is loaded only on embedded targets (not :host). It handles:
  - LED status indication
  - Hardware interface initialization (RNode, LoRa HAT)
  - Network configuration application
  - Firmware update checks
  """

  require Logger

  alias Nerves.Runtime.KV

  @doc """
  Initialize Nerves-specific subsystems.

  Called by the application supervisor on startup when running on
  a Nerves target.
  """
  def init do
    Logger.info("Reticulum Link Nerves init")

    # Start LED heartbeat
    spawn(fn -> led_heartbeat() end)

    # Log system info
    log_system_info()

    :ok
  end

  @doc """
  Get system information for diagnostics.
  """
  def system_info do
    %{
      board: KV.get_active("nerves_fw_board_name"),
      version: KV.get_active("nerves_fw_version"),
      architecture: KV.get_active("nerves_fw_architecture"),
      platform: KV.get_active("nerves_fw_platform"),
      uptime: :erlang.system_info(:uptime),
      memory: :erlang.memory(:total),
      storage: get_storage_info()
    }
  end

  @doc """
  Reboot the device.
  """
  @dialyzer {:no_return, reboot: 0}
  def reboot do
    Nerves.Runtime.reboot()
  end

  @doc """
  Power off the device.
  """
  @dialyzer {:no_return, poweroff: 0}
  def poweroff do
    Nerves.Runtime.poweroff()
  end

  # ── Private ─────────────────────────────────────────────

  defp led_heartbeat do
    # Blink the onboard LED to show the system is alive
    # Uses sysfs LED interface on Raspberry Pi
    led_path = "/sys/class/leds/led0"

    if File.exists?(led_path) do
      loop_led(led_path)
    else
      # Try alternative LED paths
      alt_paths = [
        "/sys/class/leds/ACT",
        "/sys/class/leds/led1"
      ]

      case Enum.find(alt_paths, &File.exists?/1) do
        nil -> :ok
        path -> loop_led(path)
      end
    end
  end

  defp loop_led(path) do
    # Heartbeat pattern: on 100ms, off 900ms
    File.write!("#{path}/trigger", "none")
    File.write!("#{path}/brightness", "1")
    Process.sleep(100)
    File.write!("#{path}/brightness", "0")
    Process.sleep(900)
    loop_led(path)
  rescue
    _ ->
      # LED control failed, sleep and retry
      Process.sleep(5000)
      loop_led(path)
  end

  defp log_system_info do
    info = system_info()

    Logger.info("Board: #{info.board}")
    Logger.info("Firmware: #{info.version}")
    Logger.info("Platform: #{info.platform}")
    Logger.info("Memory: #{div(info.memory, 1024 * 1024)} MB")
  end

  defp get_storage_info do
    case File.read("/proc/mounts") do
      {:ok, data} ->
        data
        |> String.split("\n")
        |> Enum.filter(&String.contains?(&1, "/dev/mmcblk"))
        |> Enum.map(fn line ->
          [device, mountpoint, fs | _] = String.split(line)
          %{device: device, mountpoint: mountpoint, filesystem: fs}
        end)

      {:error, _} ->
        []
    end
  end
end
