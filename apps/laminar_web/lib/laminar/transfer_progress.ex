# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.TransferProgress do
  @moduledoc """
  Vuze/Azureus-style transfer progress tracking with:

  - Smoothed ETA estimation using exponential moving average
  - Speed trending detection (accelerating/stable/slowing)
  - Visual progress bar with Unicode blocks
  - QUIC transport stats (when available)

  ## Usage

      {:ok, tracker} = TransferProgress.start_link(total_bytes: 77_000_000_000)
      TransferProgress.update(tracker, bytes_transferred: 2_200_000_000)
      IO.puts(TransferProgress.format(tracker))
      # => "█████░░░░░░░░░░░░░░░ 2.9% | 2.2 GB / 77 GB | 11.2 MB/s ↗ | ETA: 1h 48m"
  """

  use GenServer
  require Logger

  # EMA smoothing factor (0.3 = responsive, 0.1 = more stable)
  @ema_alpha 0.3
  # Speed samples for trend detection
  @speed_window 10
  # Minimum interval between speed samples (ms)
  @sample_interval_ms 1000

  defstruct [
    :total_bytes,
    :transferred_bytes,
    :start_time,
    :last_sample_time,
    :speed_samples,
    :ema_speed,
    :peak_speed,
    :stall_count,
    :transport_type
  ]

  # --- Public API ---

  @doc """
  Start a progress tracker GenServer.

  Options:
    - total_bytes: Total bytes to transfer (required)
    - transport: :quic | :tcp (default: :quic)
  """
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts)
  end

  @doc """
  Update transfer progress with new byte count.
  """
  def update(tracker, bytes_transferred) when is_integer(bytes_transferred) do
    GenServer.cast(tracker, {:update, bytes_transferred})
  end

  @doc """
  Get current progress state.
  """
  def get(tracker) do
    GenServer.call(tracker, :get)
  end

  @doc """
  Format progress as Vuze-style string.
  """
  def format(tracker) when is_pid(tracker) do
    format(get(tracker))
  end

  def format(%__MODULE__{} = p) do
    pct = percentage(p)
    bar = progress_bar(pct, 20)
    size_str = "#{format_bytes(p.transferred_bytes)} / #{format_bytes(p.total_bytes)}"
    speed_str = format_speed(p.ema_speed)
    trend = speed_trend(p.speed_samples)
    eta_str = format_eta(p)
    transport = if p.transport_type == :quic, do: " [QUIC]", else: ""

    "#{bar} #{Float.round(pct, 1)}% | #{size_str} | #{speed_str} #{trend}#{transport} | ETA: #{eta_str}"
  end

  @doc """
  Get detailed stats map for JSON API.
  """
  def stats(tracker) when is_pid(tracker) do
    p = get(tracker)
    elapsed = System.monotonic_time(:millisecond) - p.start_time

    %{
      bytes_transferred: p.transferred_bytes,
      bytes_total: p.total_bytes,
      bytes_remaining: p.total_bytes - p.transferred_bytes,
      percentage: percentage(p),
      speed_current: p.ema_speed,
      speed_peak: p.peak_speed,
      speed_trend: speed_trend_atom(p.speed_samples),
      eta_seconds: eta_seconds(p),
      elapsed_seconds: div(elapsed, 1000),
      stall_count: p.stall_count,
      transport: p.transport_type
    }
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(opts) do
    total = Keyword.fetch!(opts, :total_bytes)
    transport = Keyword.get(opts, :transport, :quic)
    now = System.monotonic_time(:millisecond)

    state = %__MODULE__{
      total_bytes: total,
      transferred_bytes: 0,
      start_time: now,
      last_sample_time: now,
      speed_samples: [],
      ema_speed: 0.0,
      peak_speed: 0.0,
      stall_count: 0,
      transport_type: transport
    }

    {:ok, state}
  end

  @impl true
  def handle_cast({:update, bytes}, state) do
    now = System.monotonic_time(:millisecond)
    interval = now - state.last_sample_time

    new_state =
      if interval >= @sample_interval_ms do
        bytes_delta = bytes - state.transferred_bytes
        speed = bytes_delta / (interval / 1000)  # bytes/sec

        # Update EMA speed
        ema = if state.ema_speed == 0.0 do
          speed
        else
          @ema_alpha * speed + (1 - @ema_alpha) * state.ema_speed
        end

        # Track speed samples for trend
        samples = Enum.take([speed | state.speed_samples], @speed_window)

        # Detect stalls (speed < 1KB/s)
        stalls = if speed < 1024, do: state.stall_count + 1, else: state.stall_count

        %{state |
          transferred_bytes: bytes,
          last_sample_time: now,
          speed_samples: samples,
          ema_speed: ema,
          peak_speed: max(state.peak_speed, speed),
          stall_count: stalls
        }
      else
        %{state | transferred_bytes: bytes}
      end

    {:noreply, new_state}
  end

  @impl true
  def handle_call(:get, _from, state) do
    {:reply, state, state}
  end

  # --- Private Functions ---

  defp percentage(%{total_bytes: 0}), do: 0.0
  defp percentage(%{transferred_bytes: t, total_bytes: total}) do
    t / total * 100
  end

  defp progress_bar(pct, width) do
    filled = round(pct / 100 * width)
    empty = width - filled
    String.duplicate("█", filled) <> String.duplicate("░", empty)
  end

  defp format_bytes(bytes) when bytes < 1024, do: "#{bytes} B"
  defp format_bytes(bytes) when bytes < 1_048_576, do: "#{Float.round(bytes / 1024, 1)} KB"
  defp format_bytes(bytes) when bytes < 1_073_741_824, do: "#{Float.round(bytes / 1_048_576, 1)} MB"
  defp format_bytes(bytes), do: "#{Float.round(bytes / 1_073_741_824, 2)} GB"

  defp format_speed(nil), do: "-- MB/s"
  defp format_speed(0), do: "0 B/s"
  defp format_speed(0.0), do: "0 B/s"
  defp format_speed(bps) when bps < 1024, do: "#{round(bps)} B/s"
  defp format_speed(bps) when bps < 1_048_576, do: "#{Float.round(bps / 1024, 1)} KB/s"
  defp format_speed(bps), do: "#{Float.round(bps / 1_048_576, 1)} MB/s"

  defp speed_trend(samples) when length(samples) < 3, do: "→"
  defp speed_trend(samples) do
    [recent | rest] = samples
    older_avg = Enum.sum(Enum.take(rest, 5)) / min(5, length(rest))

    cond do
      recent > older_avg * 1.1 -> "↗"  # Accelerating (>10% faster)
      recent < older_avg * 0.9 -> "↘"  # Slowing (>10% slower)
      true -> "→"                       # Stable
    end
  end

  defp speed_trend_atom(samples) when length(samples) < 3, do: :stable
  defp speed_trend_atom(samples) do
    [recent | rest] = samples
    older_avg = Enum.sum(Enum.take(rest, 5)) / min(5, length(rest))

    cond do
      recent > older_avg * 1.1 -> :accelerating
      recent < older_avg * 0.9 -> :slowing
      true -> :stable
    end
  end

  defp eta_seconds(%{ema_speed: 0}), do: nil
  defp eta_seconds(%{ema_speed: 0.0}), do: nil
  defp eta_seconds(%{transferred_bytes: t, total_bytes: total, ema_speed: speed}) do
    remaining = total - t
    round(remaining / speed)
  end

  defp format_eta(%{ema_speed: s}) when s == 0 or s == 0.0, do: "calculating..."
  defp format_eta(progress) do
    case eta_seconds(progress) do
      nil -> "∞"
      secs when secs < 60 -> "#{secs}s"
      secs when secs < 3600 -> "#{div(secs, 60)}m #{rem(secs, 60)}s"
      secs ->
        hours = div(secs, 3600)
        mins = div(rem(secs, 3600), 60)
        "#{hours}h #{mins}m"
    end
  end
end
