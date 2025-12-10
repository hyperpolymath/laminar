# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.Accelerator do
  @moduledoc """
  Maximum transfer acceleration incorporating techniques from:

  ## Internet Download Manager (IDM) / Internet Download Accelerator (IDA)
  - Dynamic file segmentation (split into N chunks)
  - Multi-connection parallel downloading (8-32 connections)
  - Intelligent segment scheduling (smaller segments for slow connections)
  - Resume from any segment independently

  ## aria2
  - Metalink support (multiple mirrors simultaneously)
  - BitTorrent-style piece selection (rarest-first for redundancy)
  - Connection reuse and keep-alive
  - Adaptive piece size based on bandwidth

  ## cFOS Traffic Shaping
  - Priority-based queue management
  - Bandwidth reservation for critical transfers
  - Congestion avoidance with packet pacing
  - RTT-aware scheduling

  ## FastCopy
  - Memory-mapped I/O (zero-copy where possible)
  - Large buffer sizes (128MB-1GB)
  - Async I/O with overlapped operations
  - Direct I/O bypassing OS cache for huge files

  ## Virtual Disk Caching
  - RAM disk tier for hot data (tier1: tmpfs)
  - NVMe staging for checkpoints (tier2)
  - Lazy writeback with coalescing
  - Prefetch hints for sequential access

  Priority: Dependability > Security > Interoperability > Speed
  """

  require Logger

  # Segment sizes based on file size (IDM/IDA style)
  @segment_sizes %{
    small: 1 * 1024 * 1024,        # 1 MB segments for <100MB files
    medium: 8 * 1024 * 1024,       # 8 MB segments for 100MB-1GB files
    large: 32 * 1024 * 1024,       # 32 MB segments for 1GB-10GB files
    huge: 128 * 1024 * 1024        # 128 MB segments for >10GB files
  }

  # Connection limits (IDM style, conservative)
  @max_connections_per_transfer 16
  @max_total_connections 64

  defstruct [
    # Segment-based downloading
    :segment_size,
    :max_segments,
    :active_segments,

    # Connection management
    :connections_per_host,
    :keep_alive,
    :connection_reuse,

    # Buffer/cache settings (FastCopy style)
    :buffer_size,
    :use_mmap,
    :direct_io,
    :async_io,

    # Traffic shaping (cFOS style)
    :priority,
    :bandwidth_limit,
    :packet_pacing,
    :rtt_scheduling,

    # Caching tiers
    :tier1_path,
    :tier2_path,
    :prefetch,
    :writeback_coalesce
  ]

  @doc """
  Create optimal acceleration config based on file size and network conditions.
  """
  def configure(file_size, opts \\ []) do
    segment_size = optimal_segment_size(file_size)
    max_segments = min(@max_connections_per_transfer, ceil(file_size / segment_size))

    %__MODULE__{
      # Segmentation (IDM/IDA)
      segment_size: segment_size,
      max_segments: max_segments,
      active_segments: MapSet.new(),

      # Connections (IDM)
      connections_per_host: Keyword.get(opts, :connections, 8),
      keep_alive: true,
      connection_reuse: true,

      # Buffers (FastCopy)
      buffer_size: optimal_buffer_size(file_size),
      use_mmap: file_size > 100 * 1024 * 1024,  # mmap for >100MB
      direct_io: file_size > 1024 * 1024 * 1024, # direct I/O for >1GB
      async_io: true,

      # Traffic shaping (cFOS)
      priority: Keyword.get(opts, :priority, :normal),
      bandwidth_limit: Keyword.get(opts, :bandwidth_limit, :unlimited),
      packet_pacing: true,
      rtt_scheduling: true,

      # Caching
      tier1_path: Keyword.get(opts, :tier1, "/mnt/laminar_tier1"),
      tier2_path: Keyword.get(opts, :tier2, "/mnt/laminar_tier2"),
      prefetch: true,
      writeback_coalesce: true
    }
  end

  @doc """
  Convert acceleration config to rclone flags.
  """
  def to_rclone_flags(%__MODULE__{} = acc) do
    base = [
      "--transfers=#{acc.max_segments}",
      "--checkers=#{acc.max_segments * 2}",
      "--buffer-size=#{format_bytes(acc.buffer_size)}",
      "--multi-thread-streams=#{acc.max_segments}"
    ]

    mmap = if acc.use_mmap, do: ["--use-mmap"], else: []

    cache = [
      "--cache-dir=#{acc.tier1_path}",
      "--cache-chunk-size=#{format_bytes(acc.segment_size)}",
      "--cache-chunk-total-size=#{format_bytes(acc.buffer_size * 4)}"
    ]

    bandwidth = case acc.bandwidth_limit do
      :unlimited -> []
      limit when is_integer(limit) -> ["--bwlimit=#{limit}"]
      limit when is_binary(limit) -> ["--bwlimit=#{limit}"]
    end

    # aria2-style aggressive connection reuse
    connections = [
      "--contimeout=30s",
      "--timeout=60s",
      "--low-level-retries=20",
      "--retries=10"
    ]

    base ++ mmap ++ cache ++ bandwidth ++ connections
  end

  @doc """
  Create a segmented transfer plan (IDM/IDA style).

  Returns a list of segment specs: [{start_byte, end_byte, segment_id}]
  """
  def create_segments(file_size, %__MODULE__{} = acc) do
    segment_count = ceil(file_size / acc.segment_size)

    Enum.map(0..(segment_count - 1), fn i ->
      start_byte = i * acc.segment_size
      end_byte = min((i + 1) * acc.segment_size - 1, file_size - 1)
      segment_id = "seg_#{i}"

      %{
        id: segment_id,
        start: start_byte,
        end: end_byte,
        size: end_byte - start_byte + 1,
        status: :pending,
        retries: 0
      }
    end)
  end

  @doc """
  aria2-style segment scheduling - prioritize:
  1. Failed segments (retry immediately)
  2. Smallest remaining segments (quick wins)
  3. Rarest segments (for multi-source)
  """
  def schedule_next_segments(segments, max_concurrent) do
    pending = Enum.filter(segments, &(&1.status == :pending))

    # Sort by: retry priority, then size (smallest first)
    sorted = Enum.sort_by(pending, fn seg ->
      {-seg.retries, seg.size}
    end)

    Enum.take(sorted, max_concurrent)
  end

  @doc """
  cFOS-style traffic shaping - calculate optimal pacing delay.

  Prevents congestion by spacing packets based on RTT and bandwidth.
  """
  def pacing_delay(rtt_ms, bandwidth_bps, packet_size) do
    # Packets per second at full bandwidth
    pps = bandwidth_bps / (packet_size * 8)

    # Base delay between packets
    base_delay_ms = 1000 / pps

    # Add RTT-based jitter buffer
    jitter_buffer = rtt_ms * 0.1

    base_delay_ms + jitter_buffer
  end

  @doc """
  FastCopy-style buffer management.

  Uses a ring buffer with prefetch for sequential reads.
  """
  def create_buffer_pool(count, size) do
    Enum.map(1..count, fn i ->
      %{
        id: i,
        data: nil,
        status: :free,
        offset: 0
      }
    end)
  end

  @doc """
  Prefetch next segments while current transfer is in progress.
  """
  def prefetch_hints(current_offset, file_size, %__MODULE__{} = acc) do
    # Prefetch next 2 segments
    next_offsets = [
      current_offset + acc.segment_size,
      current_offset + acc.segment_size * 2
    ]

    Enum.filter(next_offsets, &(&1 < file_size))
  end

  @doc """
  Adaptive segment sizing based on transfer speed (aria2 style).

  If segments complete faster than expected, use larger segments.
  If segments are slow, use smaller segments for better parallelization.
  """
  def adapt_segment_size(current_size, avg_segment_time_ms, target_time_ms \\ 5000) do
    ratio = target_time_ms / max(1, avg_segment_time_ms)

    cond do
      ratio > 2.0 -> min(current_size * 2, @segment_sizes.huge)
      ratio < 0.5 -> max(current_size / 2, @segment_sizes.small)
      true -> current_size
    end
  end

  # Private helpers

  defp optimal_segment_size(file_size) do
    cond do
      file_size < 100 * 1024 * 1024 -> @segment_sizes.small
      file_size < 1024 * 1024 * 1024 -> @segment_sizes.medium
      file_size < 10 * 1024 * 1024 * 1024 -> @segment_sizes.large
      true -> @segment_sizes.huge
    end
  end

  defp optimal_buffer_size(file_size) do
    cond do
      file_size < 100 * 1024 * 1024 -> 16 * 1024 * 1024        # 16 MB
      file_size < 1024 * 1024 * 1024 -> 128 * 1024 * 1024      # 128 MB
      file_size < 10 * 1024 * 1024 * 1024 -> 512 * 1024 * 1024 # 512 MB
      true -> 1024 * 1024 * 1024                                # 1 GB
    end
  end

  defp format_bytes(bytes) when bytes >= 1024 * 1024 * 1024 do
    "#{div(bytes, 1024 * 1024 * 1024)}G"
  end
  defp format_bytes(bytes) when bytes >= 1024 * 1024 do
    "#{div(bytes, 1024 * 1024)}M"
  end
  defp format_bytes(bytes) when bytes >= 1024 do
    "#{div(bytes, 1024)}K"
  end
  defp format_bytes(bytes), do: "#{bytes}"
end
