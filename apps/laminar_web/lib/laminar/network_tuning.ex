defmodule Laminar.NetworkTuning do
  @moduledoc """
  Network tuning recommendations and automated configuration.

  Provides platform-specific tuning for:
  - Linux (sysctl settings, io_uring)
  - macOS (system settings)
  - Windows (netsh settings)

  Connection types:
  - Ethernet (jumbo frames, bonding)
  - WiFi (band selection, interference)
  - Cellular (buffer sizing)

  Transfer profiles:
  - High throughput (large files, cloud-to-cloud)
  - Low latency (interactive, small files)
  - Balanced (general purpose)
  """

  require Logger

  @linux_high_throughput_sysctl %{
    # TCP Buffer Sizes (for 10Gbps+)
    "net.core.rmem_max" => 134_217_728,        # 128MB
    "net.core.wmem_max" => 134_217_728,        # 128MB
    "net.ipv4.tcp_rmem" => "4096 87380 134217728",
    "net.ipv4.tcp_wmem" => "4096 65536 134217728",

    # TCP Congestion Control
    "net.ipv4.tcp_congestion_control" => "bbr",
    "net.core.default_qdisc" => "fq",

    # Connection handling
    "net.ipv4.tcp_max_syn_backlog" => 65535,
    "net.core.somaxconn" => 65535,
    "net.ipv4.tcp_max_tw_buckets" => 2_000_000,
    "net.ipv4.tcp_tw_reuse" => 1,

    # UDP (for QUIC)
    "net.core.rmem_default" => 31_457_280,
    "net.core.wmem_default" => 31_457_280,

    # Memory pressure
    "net.ipv4.tcp_mem" => "65536 131072 262144",
    "vm.swappiness" => 10
  }

  @linux_low_latency_sysctl %{
    # Smaller buffers, faster response
    "net.core.rmem_max" => 16_777_216,
    "net.core.wmem_max" => 16_777_216,

    # Disable Nagle's algorithm effect
    "net.ipv4.tcp_low_latency" => 1,

    # Quick ACKs
    "net.ipv4.tcp_slow_start_after_idle" => 0,

    # BBR for consistent latency
    "net.ipv4.tcp_congestion_control" => "bbr"
  }

  # Client API

  @doc """
  Get current system network settings.
  """
  def get_current_settings do
    case :os.type() do
      {:unix, :linux} -> get_linux_settings()
      {:unix, :darwin} -> get_macos_settings()
      {:win32, _} -> get_windows_settings()
      _ -> {:error, :unsupported_platform}
    end
  end

  @doc """
  Get recommended settings for a transfer profile.
  """
  def get_recommendations(profile \\ :high_throughput) do
    case :os.type() do
      {:unix, :linux} -> linux_recommendations(profile)
      {:unix, :darwin} -> macos_recommendations(profile)
      {:win32, _} -> windows_recommendations(profile)
      _ -> {:error, :unsupported_platform}
    end
  end

  @doc """
  Generate a script to apply recommended settings.
  Does NOT apply automatically - user must review and run.
  """
  def generate_tuning_script(profile \\ :high_throughput) do
    case :os.type() do
      {:unix, :linux} -> generate_linux_script(profile)
      {:unix, :darwin} -> generate_macos_script(profile)
      {:win32, _} -> generate_windows_script(profile)
      _ -> {:error, :unsupported_platform}
    end
  end

  @doc """
  Detect connection type and characteristics.
  """
  def detect_connection do
    case :os.type() do
      {:unix, :linux} -> detect_linux_connection()
      {:unix, :darwin} -> detect_macos_connection()
      {:win32, _} -> detect_windows_connection()
      _ -> {:error, :unsupported_platform}
    end
  end

  @doc """
  WiFi-specific recommendations.
  """
  def wifi_recommendations do
    %{
      band_selection: """
      5GHz vs 2.4GHz:
      - 5GHz: Faster (up to 1.3 Gbps), less interference, shorter range
      - 2.4GHz: Slower (up to 450 Mbps), more interference, longer range
      - For high-throughput transfers, use 5GHz if signal is adequate
      """,

      channel_optimization: """
      On Linux, check channel congestion:
        nmcli dev wifi list
        iwlist wlan0 scan | grep -E "Channel|Quality"

      Recommended channels:
      - 2.4GHz: 1, 6, or 11 (non-overlapping)
      - 5GHz: Prefer DFS channels (52-144) if available
      """,

      interference_reduction: """
      Common interference sources:
      - Microwave ovens (2.4GHz)
      - Bluetooth devices
      - Baby monitors
      - Neighboring WiFi networks

      Mitigations:
      - Use 5GHz band
      - Position router away from interference
      - Use directional antennas
      - Consider WiFi 6E (6GHz band)
      """,

      adapter_settings: """
      Linux WiFi power management (disable for transfers):
        sudo iwconfig wlan0 power off

      Check adapter capabilities:
        iw phy phy0 info | grep -A 20 "Supported interface modes"
      """
    }
  end

  @doc """
  Ethernet-specific recommendations.
  """
  def ethernet_recommendations do
    %{
      cable_requirements: """
      For maximum throughput:
      - 1 Gbps: Cat5e minimum
      - 2.5/5 Gbps: Cat5e (short runs) or Cat6
      - 10 Gbps: Cat6a or Cat7
      - 25/40 Gbps: Cat8 or fiber

      Cable length limits:
      - Copper: 100m maximum
      - Fiber: 300m (multimode) to 10km+ (singlemode)
      """,

      jumbo_frames: """
      Enable jumbo frames for 10Gbps+ networks:

      Linux:
        ip link set eth0 mtu 9000

      Verify path MTU:
        tracepath -n destination_host

      Note: All devices in path must support same MTU
      """,

      nic_offloading: """
      Enable hardware offloading:
        ethtool -K eth0 tso on gso on gro on lro on

      Check current settings:
        ethtool -k eth0

      For QUIC/UDP, enable UDP offloading:
        ethtool -K eth0 tx-udp-segmentation on
      """,

      bonding: """
      For multi-NIC aggregation:

      Linux bonding modes:
      - mode=0 (balance-rr): Round-robin, requires switch support
      - mode=4 (802.3ad): LACP, requires switch support
      - mode=6 (balance-alb): Adaptive load balancing, no switch config

      Example /etc/netplan config:
      bonds:
        bond0:
          interfaces: [eth0, eth1]
          parameters:
            mode: 802.3ad
            mii-monitor-interval: 100
      """
    }
  end

  # Linux Implementation

  defp get_linux_settings do
    settings = @linux_high_throughput_sysctl
    |> Map.keys()
    |> Enum.map(fn key ->
      case System.cmd("sysctl", ["-n", key], stderr_to_stdout: true) do
        {value, 0} -> {key, String.trim(value)}
        _ -> {key, :unknown}
      end
    end)
    |> Enum.into(%{})

    {:ok, settings}
  end

  defp linux_recommendations(profile) do
    sysctl = case profile do
      :high_throughput -> @linux_high_throughput_sysctl
      :low_latency -> @linux_low_latency_sysctl
      :balanced -> Map.merge(@linux_high_throughput_sysctl, %{
        "net.core.rmem_max" => 67_108_864,  # 64MB
        "net.core.wmem_max" => 67_108_864
      })
    end

    {:ok, %{
      profile: profile,
      platform: :linux,
      sysctl: sysctl,
      notes: [
        "These settings require root/sudo to apply",
        "Add to /etc/sysctl.d/99-laminar.conf for persistence",
        "Reboot or run 'sysctl --system' to apply"
      ]
    }}
  end

  defp generate_linux_script(:high_throughput) do
    script = """
    #!/bin/bash
    # Laminar High-Throughput Network Tuning
    # Review before running - requires root

    set -e

    echo "Applying high-throughput network settings..."

    # Create persistent config
    cat > /etc/sysctl.d/99-laminar-throughput.conf << 'EOF'
    # Laminar High-Throughput Settings
    # Generated: #{DateTime.utc_now() |> DateTime.to_iso8601()}

    # TCP Buffer Sizes (128MB for 10Gbps+)
    net.core.rmem_max = 134217728
    net.core.wmem_max = 134217728
    net.ipv4.tcp_rmem = 4096 87380 134217728
    net.ipv4.tcp_wmem = 4096 65536 134217728

    # BBR Congestion Control
    net.ipv4.tcp_congestion_control = bbr
    net.core.default_qdisc = fq

    # Connection Handling
    net.ipv4.tcp_max_syn_backlog = 65535
    net.core.somaxconn = 65535
    net.ipv4.tcp_tw_reuse = 1

    # UDP for QUIC
    net.core.rmem_default = 31457280
    net.core.wmem_default = 31457280
    EOF

    # Apply immediately
    sysctl --system

    # Enable BBR if not already loaded
    modprobe tcp_bbr 2>/dev/null || true

    echo "Done. Current congestion control:"
    sysctl net.ipv4.tcp_congestion_control
    """

    {:ok, script}
  end

  defp generate_linux_script(_profile) do
    generate_linux_script(:high_throughput)
  end

  defp detect_linux_connection do
    # Get default route interface
    {route_output, _} = System.cmd("ip", ["route", "get", "8.8.8.8"], stderr_to_stdout: true)
    interface = case Regex.run(~r/dev (\S+)/, route_output) do
      [_, iface] -> iface
      _ -> "unknown"
    end

    # Determine if WiFi or Ethernet
    {type_output, _} = System.cmd("cat", ["/sys/class/net/#{interface}/type"], stderr_to_stdout: true)
    type_code = String.trim(type_output)

    # Get link speed
    {speed_output, _} = System.cmd("cat", ["/sys/class/net/#{interface}/speed"],
      stderr_to_stdout: true)
    speed = case Integer.parse(String.trim(speed_output)) do
      {n, _} -> n
      _ -> :unknown
    end

    connection_type = cond do
      String.starts_with?(interface, "wl") -> :wifi
      String.starts_with?(interface, "eth") -> :ethernet
      String.starts_with?(interface, "en") -> :ethernet
      type_code == "1" -> :ethernet
      true -> :unknown
    end

    {:ok, %{
      interface: interface,
      type: connection_type,
      speed_mbps: speed,
      recommendations: case connection_type do
        :wifi -> wifi_recommendations()
        :ethernet -> ethernet_recommendations()
        _ -> %{}
      end
    }}
  end

  # macOS Implementation

  defp get_macos_settings do
    {:ok, %{note: "macOS settings require different approach via sysctl"}}
  end

  defp macos_recommendations(profile) do
    {:ok, %{
      profile: profile,
      platform: :macos,
      settings: %{
        "kern.ipc.maxsockbuf" => 16_777_216,
        "net.inet.tcp.sendspace" => 1_048_576,
        "net.inet.tcp.recvspace" => 1_048_576
      },
      notes: ["macOS has fewer tunable parameters than Linux"]
    }}
  end

  defp generate_macos_script(_profile) do
    {:ok, """
    #!/bin/bash
    # macOS network tuning (limited compared to Linux)

    sudo sysctl -w kern.ipc.maxsockbuf=16777216
    sudo sysctl -w net.inet.tcp.sendspace=1048576
    sudo sysctl -w net.inet.tcp.recvspace=1048576
    """}
  end

  defp detect_macos_connection do
    {:ok, %{note: "macOS connection detection not yet implemented"}}
  end

  # Windows Implementation

  defp get_windows_settings do
    {:ok, %{note: "Windows settings via netsh/PowerShell"}}
  end

  defp windows_recommendations(profile) do
    {:ok, %{
      profile: profile,
      platform: :windows,
      settings: [
        "netsh int tcp set global autotuninglevel=experimental",
        "netsh int tcp set global chimney=enabled",
        "netsh int tcp set global congestionprovider=ctcp"
      ]
    }}
  end

  defp generate_windows_script(_profile) do
    {:ok, """
    @echo off
    REM Windows network tuning for high throughput

    netsh int tcp set global autotuninglevel=experimental
    netsh int tcp set global chimney=enabled
    netsh int tcp set global congestionprovider=ctcp
    netsh int tcp set global ecncapability=enabled

    REM Increase network adapter buffers (requires admin)
    powershell -Command "Get-NetAdapterAdvancedProperty | Where-Object {$_.RegistryKeyword -like '*Buffer*'}"
    """}
  end

  defp detect_windows_connection do
    {:ok, %{note: "Windows connection detection not yet implemented"}}
  end
end
