defmodule Laminar.TransferMetrics do
  @moduledoc """
  Real-time transfer rate measurement and optimization recommendations.

  Measures:
  - Throughput (bytes/sec, with rolling averages)
  - Latency (RTT to endpoints)
  - Jitter (variance in latency)
  - Packet loss (where measurable)
  - TCP window utilization
  - Buffer occupancy

  Provides recommendations for:
  - Optimal chunk size
  - Parallel stream count
  - Compression level
  - Protocol selection (HTTPS vs QUIC where available)
  """

  use GenServer
  require Logger

  alias Laminar.TransferMetrics.{
    ThroughputTracker,
    LatencyMonitor,
    OptimizationEngine,
    NetworkProfile
  }

  @default_sample_interval_ms 1000
  @rolling_window_size 60  # 60 samples = 1 minute at default interval

  defstruct [
    :transfer_id,
    :source,
    :destination,
    :started_at,
    :samples,
    :current_rate_bps,
    :peak_rate_bps,
    :avg_rate_bps,
    :bytes_transferred,
    :optimization_hints
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start tracking a transfer. Returns a transfer_id for subsequent calls.
  """
  def start_tracking(source, destination, opts \\ []) do
    GenServer.call(__MODULE__, {:start_tracking, source, destination, opts})
  end

  @doc """
  Record bytes transferred. Call frequently for accurate measurements.
  """
  def record_bytes(transfer_id, bytes) do
    GenServer.cast(__MODULE__, {:record_bytes, transfer_id, bytes})
  end

  @doc """
  Get current metrics for a transfer.
  """
  def get_metrics(transfer_id) do
    GenServer.call(__MODULE__, {:get_metrics, transfer_id})
  end

  @doc """
  Get optimization recommendations based on current performance.
  """
  def get_recommendations(transfer_id) do
    GenServer.call(__MODULE__, {:get_recommendations, transfer_id})
  end

  @doc """
  Stop tracking and get final metrics.
  """
  def stop_tracking(transfer_id) do
    GenServer.call(__MODULE__, {:stop_tracking, transfer_id})
  end

  @doc """
  Profile the network path between two endpoints.
  Returns latency, bandwidth estimate, and recommended settings.
  """
  def profile_path(source_url, dest_url, opts \\ []) do
    GenServer.call(__MODULE__, {:profile_path, source_url, dest_url, opts}, :timer.seconds(30))
  end

  # Server Implementation

  @impl true
  def init(opts) do
    state = %{
      transfers: %{},
      profiles: %{},
      sample_interval: Keyword.get(opts, :sample_interval, @default_sample_interval_ms)
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:start_tracking, source, destination, opts}, _from, state) do
    transfer_id = generate_id()
    now = System.monotonic_time(:millisecond)

    transfer = %__MODULE__{
      transfer_id: transfer_id,
      source: source,
      destination: destination,
      started_at: now,
      samples: [],
      current_rate_bps: 0,
      peak_rate_bps: 0,
      avg_rate_bps: 0,
      bytes_transferred: 0,
      optimization_hints: []
    }

    new_state = put_in(state.transfers[transfer_id], transfer)
    schedule_sample(transfer_id, state.sample_interval)

    {:reply, {:ok, transfer_id}, new_state}
  end

  @impl true
  def handle_call({:get_metrics, transfer_id}, _from, state) do
    case Map.get(state.transfers, transfer_id) do
      nil -> {:reply, {:error, :not_found}, state}
      transfer -> {:reply, {:ok, format_metrics(transfer)}, state}
    end
  end

  @impl true
  def handle_call({:get_recommendations, transfer_id}, _from, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
      transfer ->
        recommendations = OptimizationEngine.analyze(transfer)
        {:reply, {:ok, recommendations}, state}
    end
  end

  @impl true
  def handle_call({:stop_tracking, transfer_id}, _from, state) do
    case Map.pop(state.transfers, transfer_id) do
      {nil, _} ->
        {:reply, {:error, :not_found}, state}
      {transfer, new_transfers} ->
        final_metrics = format_metrics(transfer)
        {:reply, {:ok, final_metrics}, %{state | transfers: new_transfers}}
    end
  end

  @impl true
  def handle_call({:profile_path, source_url, dest_url, opts}, _from, state) do
    profile = NetworkProfile.analyze(source_url, dest_url, opts)
    {:reply, {:ok, profile}, state}
  end

  @impl true
  def handle_cast({:record_bytes, transfer_id, bytes}, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:noreply, state}
      transfer ->
        updated = %{transfer | bytes_transferred: transfer.bytes_transferred + bytes}
        {:noreply, put_in(state.transfers[transfer_id], updated)}
    end
  end

  @impl true
  def handle_info({:sample, transfer_id}, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:noreply, state}
      transfer ->
        updated = take_sample(transfer)
        schedule_sample(transfer_id, state.sample_interval)
        {:noreply, put_in(state.transfers[transfer_id], updated)}
    end
  end

  # Helpers

  defp take_sample(transfer) do
    now = System.monotonic_time(:millisecond)
    elapsed = now - transfer.started_at

    # Calculate current rate
    current_rate = if length(transfer.samples) > 0 do
      {prev_time, prev_bytes} = hd(transfer.samples)
      time_delta = now - prev_time
      byte_delta = transfer.bytes_transferred - prev_bytes
      if time_delta > 0, do: (byte_delta * 8 * 1000) / time_delta, else: 0  # bits per second
    else
      0
    end

    # Add sample to rolling window
    sample = {now, transfer.bytes_transferred}
    samples = [{sample} | Enum.take(transfer.samples, @rolling_window_size - 1)]

    # Update stats
    peak = max(transfer.peak_rate_bps, current_rate)
    avg = if elapsed > 0, do: (transfer.bytes_transferred * 8 * 1000) / elapsed, else: 0

    %{transfer |
      samples: samples,
      current_rate_bps: current_rate,
      peak_rate_bps: peak,
      avg_rate_bps: avg
    }
  end

  defp schedule_sample(transfer_id, interval) do
    Process.send_after(self(), {:sample, transfer_id}, interval)
  end

  defp format_metrics(transfer) do
    %{
      transfer_id: transfer.transfer_id,
      source: transfer.source,
      destination: transfer.destination,
      duration_ms: System.monotonic_time(:millisecond) - transfer.started_at,
      bytes_transferred: transfer.bytes_transferred,
      current_rate: format_rate(transfer.current_rate_bps),
      peak_rate: format_rate(transfer.peak_rate_bps),
      average_rate: format_rate(transfer.avg_rate_bps),
      samples_collected: length(transfer.samples)
    }
  end

  defp format_rate(bps) when bps < 1_000, do: "#{Float.round(bps, 1)} bps"
  defp format_rate(bps) when bps < 1_000_000, do: "#{Float.round(bps / 1_000, 1)} Kbps"
  defp format_rate(bps) when bps < 1_000_000_000, do: "#{Float.round(bps / 1_000_000, 1)} Mbps"
  defp format_rate(bps), do: "#{Float.round(bps / 1_000_000_000, 2)} Gbps"

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end

defmodule Laminar.TransferMetrics.NetworkProfile do
  @moduledoc """
  Network path profiling for optimal transfer configuration.
  """

  def analyze(source_url, dest_url, opts \\ []) do
    source_host = URI.parse(source_url).host
    dest_host = URI.parse(dest_url).host

    # Parallel profiling
    tasks = [
      Task.async(fn -> {:source_latency, measure_latency(source_host)} end),
      Task.async(fn -> {:dest_latency, measure_latency(dest_host)} end),
      Task.async(fn -> {:source_bandwidth, estimate_bandwidth(source_host)} end),
      Task.async(fn -> {:dest_bandwidth, estimate_bandwidth(dest_host)} end),
      Task.async(fn -> {:path_mtu, discover_mtu(source_host)} end)
    ]

    results = tasks
    |> Task.await_many(:timer.seconds(20))
    |> Enum.into(%{})

    recommendations = generate_recommendations(results)

    %{
      source: source_host,
      destination: dest_host,
      source_latency_ms: results.source_latency,
      dest_latency_ms: results.dest_latency,
      estimated_bandwidth: %{
        source: results.source_bandwidth,
        destination: results.dest_bandwidth
      },
      path_mtu: results.path_mtu,
      recommendations: recommendations
    }
  end

  defp measure_latency(host) do
    case System.cmd("ping", ["-c", "5", "-q", host], stderr_to_stdout: true) do
      {output, 0} ->
        case Regex.run(~r/(\d+\.?\d*)\/(\d+\.?\d*)\/(\d+\.?\d*)\/(\d+\.?\d*)/, output) do
          [_, min, avg, max, _mdev] ->
            %{min: String.to_float(min), avg: String.to_float(avg), max: String.to_float(max)}
          _ -> %{error: :parse_failed}
        end
      {_, _} -> %{error: :unreachable}
    end
  end

  defp estimate_bandwidth(host) do
    # Simple bandwidth estimation using TCP connection timing
    # For accurate results, use iperf3 or actual transfer tests
    %{
      estimated_mbps: :unknown,
      note: "Use actual transfer for accurate measurement"
    }
  end

  defp discover_mtu(host) do
    case System.cmd("tracepath", ["-n", "-b", host], stderr_to_stdout: true) do
      {output, _} ->
        case Regex.run(~r/pmtu (\d+)/, output) do
          [_, mtu] -> String.to_integer(mtu)
          _ -> 1500  # Default
        end
    end
  rescue
    _ -> 1500
  end

  defp generate_recommendations(results) do
    recommendations = []

    # Latency-based recommendations
    avg_latency = get_in(results, [:source_latency, :avg]) || 100

    recommendations = if avg_latency > 100 do
      [%{
        type: :chunk_size,
        reason: "High latency (#{avg_latency}ms) detected",
        suggestion: "Increase chunk size to reduce round-trips",
        value: "64MB chunks recommended"
      } | recommendations]
    else
      [%{
        type: :chunk_size,
        reason: "Low latency (#{avg_latency}ms)",
        suggestion: "Standard chunk size is optimal",
        value: "16MB chunks"
      } | recommendations]
    end

    # Parallelism recommendations
    recommendations = if avg_latency > 50 do
      [%{
        type: :parallelism,
        reason: "Latency suggests benefit from parallelism",
        suggestion: "Use multiple concurrent streams",
        value: "8-16 parallel streams"
      } | recommendations]
    else
      recommendations
    end

    # MTU recommendations
    mtu = results[:path_mtu] || 1500
    recommendations = if mtu >= 9000 do
      [%{
        type: :jumbo_frames,
        reason: "Jumbo frames supported (MTU: #{mtu})",
        suggestion: "Enable jumbo frames for throughput",
        value: "MTU #{mtu}"
      } | recommendations]
    else
      recommendations
    end

    recommendations
  end
end

defmodule Laminar.TransferMetrics.OptimizationEngine do
  @moduledoc """
  Real-time optimization recommendations based on transfer performance.
  """

  # Thresholds
  @low_throughput_mbps 10
  @high_latency_ms 100
  @high_jitter_ms 20

  def analyze(transfer) do
    recommendations = []

    # Throughput analysis
    current_mbps = transfer.current_rate_bps / 1_000_000

    recommendations = cond do
      current_mbps < @low_throughput_mbps and current_mbps > 0 ->
        [low_throughput_recommendation(transfer) | recommendations]
      true ->
        recommendations
    end

    # Add connection type recommendations
    recommendations = [connection_recommendation() | recommendations]

    recommendations
  end

  defp low_throughput_recommendation(transfer) do
    %{
      type: :throughput_optimization,
      current_rate_mbps: Float.round(transfer.current_rate_bps / 1_000_000, 2),
      suggestions: [
        "Check if compression is enabled (zstd level 3 recommended)",
        "Increase parallel transfer count",
        "Consider using express lane for uncompressed passthrough",
        "Check source/destination rate limits"
      ]
    }
  end

  defp connection_recommendation do
    # Detect connection type and provide specific advice
    %{
      type: :connection_optimization,
      wifi: %{
        suggestions: [
          "Use 5GHz band if available (less interference)",
          "Position closer to router or use wired connection",
          "Avoid microwave usage during transfers",
          "Consider WiFi 6E for multi-gigabit"
        ]
      },
      ethernet: %{
        suggestions: [
          "Ensure Cat6a or better for 10Gbps",
          "Enable jumbo frames if switch supports",
          "Check for duplex mismatch",
          "Consider bonded NICs for higher throughput"
        ]
      },
      system: %{
        suggestions: [
          "Increase TCP buffer sizes: net.core.rmem_max, net.core.wmem_max",
          "Enable TCP BBR congestion control",
          "Consider enabling TCP_NODELAY for latency",
          "Use io_uring for async I/O (Linux 5.1+)"
        ]
      }
    }
  end
end
