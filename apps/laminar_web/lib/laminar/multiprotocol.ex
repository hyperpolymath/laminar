# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.MultiProtocol do
  @moduledoc """
  Multi-protocol parallel transfer engine.

  ## Why BitTorrent/P2P is So Fast

  1. **Swarming** - Download different pieces from different peers simultaneously
  2. **Rarest-First** - Prioritize rare pieces to maximize swarm health
  3. **Tit-for-Tat** - Reward uploaders with faster downloads
  4. **Endgame Mode** - Request last pieces from ALL peers (race condition)
  5. **Distributed Hash Table (DHT)** - Decentralized peer discovery
  6. **µTP** - UDP-based protocol that yields to TCP (network-friendly)
  7. **Connection Saturation** - Hundreds of connections, each doing small work

  ## Protocol Performance Characteristics

  | Protocol | Parallel | Encrypt | Resume | Speed     | Use Case              |
  |----------|----------|---------|--------|-----------|----------------------|
  | HTTP/3   | ✓ QUIC   | TLS 1.3 | ✓      | Excellent | Primary, web-native   |
  | SFTP     | ✓        | SSH     | ✓      | Good      | Secure, firewall-ok   |
  | SCP      | Single   | SSH     | ✗      | Good      | Simple secure copy    |
  | FTP      | ✓        | ✗/TLS   | ✓      | Fast      | Legacy, low overhead  |
  | FTPS     | ✓        | TLS     | ✓      | Fast      | Secure FTP            |
  | rsync    | Single   | SSH     | ✓ diff | Excellent | Incremental sync      |
  | WebDAV   | ✓        | TLS     | ✓      | Good      | HTTP-based filesystem |
  | S3       | ✓ MPU    | TLS     | ✓      | Excellent | Cloud-native          |
  | NNTP     | ✓        | TLS     | ✓      | Fast      | Usenet (binary groups)|
  | Gopher   | Single   | ✗       | ✗      | Fast      | Ultra-low overhead    |

  ## Multi-Protocol Strategy

  Split file into chunks, send via multiple protocols simultaneously:
  - Chunks 0-25%:  HTTP/3 (QUIC) - fastest, most reliable
  - Chunks 25-50%: SFTP - encrypted, firewall-friendly
  - Chunks 50-75%: S3 multipart - cloud-optimized
  - Chunks 75-100%: rsync - handles final assembly

  ## Port Multiplexing

  Use multiple ports to bypass per-connection throttling:
  - Port 443:  HTTPS/HTTP3
  - Port 22:   SFTP/SCP
  - Port 21:   FTP control (passive data on high ports)
  - Port 873:  rsync daemon
  - Port 119:  NNTP (if available)
  - Port 70:   Gopher (minimal overhead fallback)
  """

  require Logger

  # Protocol definitions with their characteristics
  @protocols %{
    http3: %{
      port: 443,
      parallel: true,
      encrypted: true,
      resume: true,
      overhead: :low,
      speed_factor: 1.0
    },
    sftp: %{
      port: 22,
      parallel: true,
      encrypted: true,
      resume: true,
      overhead: :medium,
      speed_factor: 0.85
    },
    scp: %{
      port: 22,
      parallel: false,
      encrypted: true,
      resume: false,
      overhead: :low,
      speed_factor: 0.9
    },
    ftp: %{
      port: 21,
      parallel: true,
      encrypted: false,
      resume: true,
      overhead: :minimal,
      speed_factor: 0.95
    },
    ftps: %{
      port: 990,
      parallel: true,
      encrypted: true,
      resume: true,
      overhead: :low,
      speed_factor: 0.9
    },
    rsync: %{
      port: 873,
      parallel: false,
      encrypted: :optional,
      resume: :delta,
      overhead: :varies,
      speed_factor: 1.2  # Can be >1 for incremental
    },
    s3: %{
      port: 443,
      parallel: true,
      encrypted: true,
      resume: true,
      overhead: :low,
      speed_factor: 1.1
    },
    webdav: %{
      port: 443,
      parallel: true,
      encrypted: true,
      resume: true,
      overhead: :medium,
      speed_factor: 0.8
    },
    nntp: %{
      port: 563,  # NNTPS
      parallel: true,
      encrypted: true,
      resume: true,
      overhead: :low,
      speed_factor: 0.9
    },
    gopher: %{
      port: 70,
      parallel: false,
      encrypted: false,
      resume: false,
      overhead: :minimal,
      speed_factor: 1.0  # Very low overhead
    }
  }

  defstruct [
    :file_size,
    :chunk_size,
    :protocols_available,
    :protocol_allocation,
    :swarm_mode,
    :endgame_threshold
  ]

  @doc """
  Detect which protocols are available to the destination.
  """
  def detect_protocols(host, opts \\ []) do
    timeout = Keyword.get(opts, :timeout, 2000)

    @protocols
    |> Enum.map(fn {proto, config} ->
      Task.async(fn ->
        case probe_port(host, config.port, timeout) do
          :open -> {proto, config}
          :closed -> nil
        end
      end)
    end)
    |> Task.await_many(timeout + 1000)
    |> Enum.reject(&is_nil/1)
    |> Map.new()
  end

  @doc """
  Create optimal multi-protocol transfer plan.

  Allocates chunks to protocols based on:
  1. Available bandwidth per protocol
  2. Protocol speed characteristics
  3. Encryption requirements (security first)
  """
  def plan_transfer(file_size, available_protocols, opts \\ []) do
    require_encryption = Keyword.get(opts, :require_encryption, true)
    chunk_size = optimal_chunk_size(file_size)
    chunk_count = ceil(file_size / chunk_size)

    # Filter by encryption requirement
    usable = if require_encryption do
      Enum.filter(available_protocols, fn {_proto, config} ->
        config.encrypted == true
      end)
    else
      available_protocols
    end

    # Allocate chunks weighted by speed factor
    total_weight = usable
    |> Enum.map(fn {_proto, config} -> config.speed_factor end)
    |> Enum.sum()

    allocation = usable
    |> Enum.map(fn {proto, config} ->
      share = config.speed_factor / total_weight
      chunks = round(chunk_count * share)
      {proto, chunks}
    end)
    |> adjust_allocation(chunk_count)

    %__MODULE__{
      file_size: file_size,
      chunk_size: chunk_size,
      protocols_available: Map.keys(usable),
      protocol_allocation: allocation,
      swarm_mode: length(Map.keys(usable)) > 1,
      endgame_threshold: 0.95  # Last 5% from all protocols
    }
  end

  @doc """
  Execute multi-protocol parallel transfer (BitTorrent swarming style).
  """
  def execute_swarm(%__MODULE__{} = plan, src, dst, progress_tracker \\ nil) do
    # Create chunk list
    chunks = create_chunks(plan)

    # Start protocol workers
    workers = Enum.map(plan.protocol_allocation, fn {proto, _count} ->
      {proto, spawn_worker(proto, src, dst)}
    end)

    # Distribute chunks to workers (rarest-first simulation)
    distribute_chunks(chunks, workers, progress_tracker)
  end

  @doc """
  BitTorrent-style endgame mode.

  When 95% complete, request remaining chunks from ALL protocols.
  First response wins, cancel others.
  """
  def endgame(remaining_chunks, workers) do
    # Request each chunk from every worker
    tasks = for chunk <- remaining_chunks, {_proto, worker} <- workers do
      Task.async(fn ->
        send(worker, {:fetch_chunk, chunk, self()})
        receive do
          {:chunk_complete, ^chunk, data} -> {:ok, chunk, data}
        after
          30_000 -> {:timeout, chunk}
        end
      end)
    end

    # Collect first response for each chunk
    collect_endgame_results(tasks, remaining_chunks, %{})
  end

  @doc """
  Calculate effective bandwidth gain from multi-protocol.

  With N protocols of similar speed, gain approaches N
  (minus overhead for coordination).
  """
  def bandwidth_multiplier(protocol_count) do
    # Coordination overhead: ~5% per additional protocol
    base = protocol_count
    overhead = 1 - (protocol_count - 1) * 0.05
    base * max(0.5, overhead)
  end

  @doc """
  Gopher protocol handler (minimal overhead fallback).

  Gopher has almost zero protocol overhead - just send selector, get data.
  Useful for environments where every byte counts.
  """
  def gopher_fetch(host, selector) do
    case :gen_tcp.connect(String.to_charlist(host), 70, [:binary, active: false], 5000) do
      {:ok, socket} ->
        :gen_tcp.send(socket, selector <> "\r\n")
        data = recv_all(socket, [])
        :gen_tcp.close(socket)
        {:ok, IO.iodata_to_binary(data)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  NNTP binary download (Usenet style).

  Usenet uses yEnc encoding for binary efficiency.
  Can saturate connections with minimal protocol overhead.
  """
  def nntp_fetch(host, port, group, article_ids) do
    # NNTP parallel article fetching
    tasks = Enum.map(article_ids, fn article_id ->
      Task.async(fn ->
        fetch_nntp_article(host, port, group, article_id)
      end)
    end)

    Task.await_many(tasks, 60_000)
  end

  # Private helpers

  defp probe_port(host, port, timeout) do
    case :gen_tcp.connect(String.to_charlist(host), port, [], timeout) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :open
      {:error, _} ->
        :closed
    end
  end

  defp optimal_chunk_size(file_size) do
    cond do
      file_size < 10 * 1024 * 1024 -> 256 * 1024          # 256 KB
      file_size < 100 * 1024 * 1024 -> 1 * 1024 * 1024    # 1 MB
      file_size < 1024 * 1024 * 1024 -> 4 * 1024 * 1024   # 4 MB
      true -> 16 * 1024 * 1024                             # 16 MB
    end
  end

  defp adjust_allocation(allocation, target_chunks) do
    current_total = Enum.sum(Enum.map(allocation, fn {_p, c} -> c end))

    if current_total == target_chunks do
      allocation
    else
      # Add/remove from largest allocation
      {proto, count} = Enum.max_by(allocation, fn {_p, c} -> c end)
      diff = target_chunks - current_total
      List.keyreplace(allocation, proto, 0, {proto, count + diff})
    end
  end

  defp create_chunks(%{file_size: size, chunk_size: chunk_size}) do
    chunk_count = ceil(size / chunk_size)

    Enum.map(0..(chunk_count - 1), fn i ->
      %{
        id: i,
        start: i * chunk_size,
        end: min((i + 1) * chunk_size - 1, size - 1),
        status: :pending,
        protocol: nil
      }
    end)
  end

  defp spawn_worker(proto, src, dst) do
    spawn(fn -> protocol_worker_loop(proto, src, dst) end)
  end

  defp protocol_worker_loop(proto, src, dst) do
    receive do
      {:fetch_chunk, chunk, reply_to} ->
        result = fetch_chunk_via_protocol(proto, src, dst, chunk)
        send(reply_to, {:chunk_complete, chunk.id, result})
        protocol_worker_loop(proto, src, dst)

      :shutdown ->
        :ok
    end
  end

  defp fetch_chunk_via_protocol(proto, _src, _dst, chunk) do
    # In production, dispatch to actual protocol implementation
    Logger.debug("Fetching chunk #{chunk.id} via #{proto}")
    # Simulated - would call actual rclone backend
    {:ok, chunk.id}
  end

  defp distribute_chunks(chunks, workers, progress_tracker) do
    # Round-robin distribution with tracking
    {completed, _remaining} =
      chunks
      |> Enum.with_index()
      |> Enum.reduce({[], workers}, fn {chunk, idx}, {done, [{proto, worker} | rest]} ->
        send(worker, {:fetch_chunk, chunk, self()})

        receive do
          {:chunk_complete, _id, _data} ->
            if progress_tracker do
              Laminar.TransferProgress.update(progress_tracker, (idx + 1) * chunk.size)
            end
            {[chunk | done], rest ++ [{proto, worker}]}
        after
          60_000 ->
            {done, rest ++ [{proto, worker}]}
        end
      end)

    completed
  end

  defp collect_endgame_results([], _remaining, results), do: {:ok, results}
  defp collect_endgame_results(tasks, remaining, results) do
    case Task.yield_many(tasks, 1000) do
      [] ->
        {:partial, results, remaining}

      completed ->
        new_results = Enum.reduce(completed, results, fn
          {_task, {:ok, {:ok, chunk_id, data}}}, acc ->
            Map.put(acc, chunk_id, data)
          _, acc ->
            acc
        end)

        new_remaining = remaining -- Map.keys(new_results)

        if Enum.empty?(new_remaining) do
          {:ok, new_results}
        else
          active_tasks = Enum.reject(tasks, fn t ->
            Enum.any?(completed, fn {ct, _} -> ct == t end)
          end)
          collect_endgame_results(active_tasks, new_remaining, new_results)
        end
    end
  end

  defp recv_all(socket, acc) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, data} -> recv_all(socket, [data | acc])
      {:error, :closed} -> Enum.reverse(acc)
      {:error, _} -> Enum.reverse(acc)
    end
  end

  defp fetch_nntp_article(host, port, group, article_id) do
    # Simplified NNTP fetch
    case :gen_tcp.connect(String.to_charlist(host), port, [:binary, active: false], 5000) do
      {:ok, socket} ->
        # Select group and fetch article
        :gen_tcp.send(socket, "GROUP #{group}\r\n")
        {:ok, _} = :gen_tcp.recv(socket, 0, 5000)

        :gen_tcp.send(socket, "ARTICLE #{article_id}\r\n")
        data = recv_all(socket, [])

        :gen_tcp.send(socket, "QUIT\r\n")
        :gen_tcp.close(socket)

        {:ok, IO.iodata_to_binary(data)}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
