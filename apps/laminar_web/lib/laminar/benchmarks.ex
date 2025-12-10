# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.Benchmarks do
  @moduledoc """
  Comparison with world's most demanding network applications.

  ## Netflix Open Connect

  **Scale**: ~400 Tbps peak, 15% of global internet traffic
  **Techniques**:
  - Custom CDN with 17,000+ servers in ISP networks
  - Per-title encoding (unique ladder per content)
  - Predictive pre-positioning (push content before demand)
  - QUIC/HTTP3 adaptive streaming
  - Dynamic Optimizer (ML-based bitrate selection)

  **What Laminar borrows**:
  - Adaptive streaming concepts → adaptive chunk sizing
  - Edge caching → tiered caching (RAM/NVMe)
  - Per-title optimization → per-file optimization strategy

  ## World of Warcraft / Online Gaming

  **Scale**: Millions concurrent, <50ms latency required
  **Techniques**:
  - UDP with custom reliability (selective retransmit)
  - Client-side prediction (act before server confirms)
  - Interest management (only sync nearby entities)
  - Delta compression (send changes, not full state)
  - Geographic server sharding

  **What Laminar borrows**:
  - Delta sync → rsync-style incremental
  - UDP with reliability → QUIC
  - Prediction → prefetch hints
  - Interest management → relevance filtering

  ## High-Frequency Trading (Goldman, Citadel, etc.)

  **Scale**: Nanosecond latency, millions TPS
  **Techniques**:
  - Kernel bypass (DPDK, RDMA)
  - FPGA/ASIC for packet processing
  - Co-location (servers in exchange datacenter)
  - Microwave/laser links (speed of light in air > fiber)
  - Custom TCP stacks (bypass OS entirely)
  - Direct market data feeds (no serialization)

  **What Laminar borrows**:
  - Kernel bypass → io_uring, mmap
  - Low-latency transport → QUIC 0-RTT
  - Co-location → edge node selection
  - Custom protocol → multi-protocol parallel

  ## Akamai / Cloudflare (CDN)

  **Scale**: 300+ Tbps capacity, 300+ PoPs
  **Techniques**:
  - Anycast routing (nearest server automatically)
  - Edge compute (process at edge, not origin)
  - HTTP/2 Server Push
  - Brotli/Zstd compression
  - TLS 1.3 with 0-RTT

  **What Laminar borrows**:
  - Anycast → vanguard pathfinding
  - Edge acceleration → L1 routing
  - 0-RTT → QUIC session resumption
  - Compression → intelligent compression routing

  ## BitTorrent

  **Scale**: 100M+ users, distributed
  **Techniques**:
  - Distributed hash table (DHT) - no central server
  - Swarming - pieces from multiple sources
  - Rarest-first piece selection
  - Tit-for-tat incentives
  - µTP (UDP-based, network-friendly)

  **What Laminar borrows**:
  - Swarming → multi-protocol parallel
  - Rarest-first → adaptive segment scheduling
  - Endgame mode → parallel finish
  - µTP concepts → QUIC congestion control

  ## Comparison Table

  | Feature              | Netflix | WoW  | HFT    | CDN  | BitTorrent | Laminar |
  |----------------------|---------|------|--------|------|------------|---------|
  | Latency target       | ~1s     | 50ms | 1µs    | 50ms | N/A        | 10ms    |
  | Throughput           | 400Tbps | 10G  | 1Gbps* | 300T | Varies     | 10Gbps  |
  | Parallel connections | 1-4     | 1    | 100s   | 6    | 100s       | 32-64   |
  | Encryption           | AES     | RC4  | None** | TLS  | Optional   | TLS 1.3 |
  | Protocol             | QUIC    | UDP  | Custom | H2   | µTP        | Multi   |
  | Edge caching         | ✓       | ✗    | ✗      | ✓    | ✗          | ✓       |
  | Adaptive routing     | ✓       | ✗    | ✓      | ✓    | ✓          | ✓       |

  *HFT optimizes for latency, not throughput
  **HFT uses private networks, security via isolation

  ## Theoretical Limits

  ```
  Physical limits:
  - Speed of light in fiber: 200,000 km/s (0.67c)
  - Speed of light in air: 299,792 km/s (microwave links)
  - Minimum RTT NYC↔London: ~28ms (fiber), ~20ms (microwave)

  Protocol overhead:
  - TCP handshake: 1.5 RTT
  - TLS 1.2 handshake: +2 RTT
  - TLS 1.3 handshake: +1 RTT
  - QUIC 0-RTT: +0 RTT (resumption)

  Laminar best case (QUIC 0-RTT):
  - Connection setup: 0 RTT
  - First byte: 0.5 RTT
  - Parallel streams: bandwidth × connections
  ```

  ## Where Laminar Excels

  1. **Bulk cloud-to-cloud transfers** - No local storage needed
  2. **Multi-cloud scenarios** - Single protocol to rule them all
  3. **Large file optimization** - Segmentation, parallel, resume
  4. **Security through distribution** - Shamir sharing across paths
  5. **Adaptive optimization** - Learns and improves during transfer

  ## Where Others Excel

  1. **Netflix**: Pre-positioned content (we're real-time)
  2. **Gaming**: Sub-50ms latency (we optimize throughput)
  3. **HFT**: Nanosecond precision (we're milliseconds)
  4. **CDN**: Massive scale (we're single-tenant)
  """

  @doc """
  Benchmark a transfer and compare to industry standards.
  """
  def benchmark_transfer(src, dst, file_size, opts \\ []) do
    start = System.monotonic_time(:millisecond)

    # Execute transfer
    result = Laminar.Transport.transfer_with_assurances(
      src.remote, src.path,
      dst.remote, dst.path,
      opts
    )

    elapsed_ms = System.monotonic_time(:millisecond) - start
    throughput_mbps = file_size / 1_000_000 / (elapsed_ms / 1000) * 8

    %{
      result: result,
      elapsed_ms: elapsed_ms,
      throughput_mbps: throughput_mbps,
      comparison: %{
        vs_netflix: throughput_mbps / 20_000,    # Netflix avg stream: ~20 Mbps
        vs_gaming: elapsed_ms / 50,              # Gaming target: 50ms
        vs_hft: elapsed_ms * 1_000_000,          # HFT target: nanoseconds
        vs_cdn: throughput_mbps / 1000,          # CDN target: ~1 Gbps per user
        vs_bittorrent: throughput_mbps / 100     # Good BT: ~100 Mbps
      }
    }
  end

  @doc """
  Estimate achievable throughput based on network conditions.
  """
  def estimate_throughput(rtt_ms, bandwidth_mbps, loss_rate) do
    # Mathis equation for TCP throughput
    # Throughput ≈ (MSS / RTT) × (1 / sqrt(loss))
    mss = 1460  # bytes

    tcp_estimate = (mss * 8 / rtt_ms) * (1 / :math.sqrt(max(0.0001, loss_rate)))

    # QUIC typically achieves 1.2-1.5x TCP in lossy conditions
    quic_multiplier = 1 + (loss_rate * 5)  # More gain with more loss

    %{
      tcp_mbps: min(tcp_estimate, bandwidth_mbps),
      quic_mbps: min(tcp_estimate * quic_multiplier, bandwidth_mbps),
      laminar_mbps: min(tcp_estimate * quic_multiplier * parallel_factor(), bandwidth_mbps)
    }
  end

  @doc """
  Calculate parallel connection efficiency factor.
  """
  def parallel_factor do
    # 32 connections with 5% coordination overhead each
    connections = 32
    overhead_per = 0.05
    connections * (1 - overhead_per * :math.log(connections))
  end

  @doc """
  Compare latency characteristics.
  """
  def latency_comparison do
    %{
      netflix: %{
        startup: 2000,      # ms to first frame
        seek: 500,          # ms to seek
        buffer: 30_000      # ms of buffer
      },
      gaming: %{
        input_to_server: 20,  # ms
        server_tick: 16,      # ms (60 Hz)
        acceptable: 100       # ms total
      },
      hft: %{
        tick_to_trade: 0.000_001,  # 1 microsecond
        network_hop: 0.000_000_1,  # 100 nanoseconds
        target: 0.000_000_010      # 10 nanoseconds
      },
      laminar: %{
        connection: 0,         # QUIC 0-RTT
        first_byte: 10,        # ms
        chunk_ack: 25,         # ms
        target: 100            # ms for responsiveness
      }
    }
  end
end
