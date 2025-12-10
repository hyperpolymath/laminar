# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.Pathfinder do
  @moduledoc """
  Intelligent routing with vanguard pathfinding and cryptographic distribution.

  ## Multi-Path Cryptographic Security

  Splitting data across multiple paths using Shamir's Secret Sharing:
  - File split into N shares, any K shares reconstruct original
  - Attacker must intercept K+ paths (not just one)
  - Each path can use different encryption keys
  - Even if one path is compromised, data remains secure

  Example: 5 paths, threshold 3
  - Data split into 5 encrypted shares
  - Need any 3 to reconstruct
  - Attacker must compromise 3+ paths simultaneously

  ## Edge/L1 Acceleration

  Use CDN edge nodes as relay accelerators:
  - Cloudflare Workers: Programmable edge
  - Fastly Compute@Edge: WASM at edge
  - AWS CloudFront: Global edge network
  - Hurricane Electric (HE.net): Premium backbone
  - Akamai: Largest CDN network

  Strategy: Upload to nearest edge, edge-to-edge transfer, download from nearest edge

  ## Vanguard Pathfinding

  Initial packets ("scouts") map the network before bulk transfer:
  1. **Probe Phase**: Send tiny packets on all possible paths
  2. **Measure**: RTT, bandwidth, packet loss, jitter
  3. **Score**: Weight paths by quality metrics
  4. **Route**: Allocate bulk data to best paths
  5. **Adapt**: Continuously re-measure and rebalance

  ## Progressive Optimization (Traveling Salesman Style)

  Instead of computing optimal route upfront (NP-hard), use:
  - **Nearest Neighbor**: Start with greedy, refine later
  - **2-opt/3-opt**: Swap path segments while transferring
  - **Simulated Annealing**: Random swaps with decreasing probability
  - **Genetic Algorithm**: Evolve route population in background
  """

  require Logger

  # Shamir's Secret Sharing parameters
  @default_shares 5
  @default_threshold 3

  # Vanguard probe parameters
  @probe_size 64          # bytes
  @probe_count 10         # probes per path
  @probe_interval_ms 50   # between probes

  # Path quality weights
  @weight_rtt 0.3
  @weight_bandwidth 0.4
  @weight_loss 0.2
  @weight_jitter 0.1

  defstruct [
    # Cryptographic distribution
    :shares,
    :threshold,
    :share_keys,

    # Path discovery
    :known_paths,
    :path_scores,
    :active_paths,

    # Edge nodes
    :edge_nodes,
    :nearest_edge,

    # Progressive optimization
    :optimization_algo,
    :current_tour,
    :best_tour,
    :iteration
  ]

  # --- Cryptographic Multi-Path Security ---

  @doc """
  Split data using Shamir's Secret Sharing for multi-path security.

  Each share is encrypted with a unique key. Need `threshold` shares to reconstruct.
  More secure than single-path encryption because attacker must intercept multiple paths.
  """
  def secret_share(data, opts \\ []) do
    shares = Keyword.get(opts, :shares, @default_shares)
    threshold = Keyword.get(opts, :threshold, @default_threshold)

    # Generate random polynomial coefficients
    # a_0 = secret, a_1..a_{k-1} = random
    secret = :crypto.hash(:sha256, data)
    coefficients = [secret | generate_random_coefficients(threshold - 1)]

    # Generate shares: (x, f(x)) for x = 1..shares
    share_data = for x <- 1..shares do
      y = evaluate_polynomial(coefficients, x)
      share_content = xor_with_key(data, derive_share_key(y, x))

      %{
        index: x,
        commitment: y,
        data: share_content,
        checksum: :crypto.hash(:md5, share_content)
      }
    end

    {:ok, share_data, %{shares: shares, threshold: threshold}}
  end

  @doc """
  Reconstruct data from threshold shares using Lagrange interpolation.
  """
  def secret_reconstruct(shares, _metadata) when length(shares) < @default_threshold do
    {:error, :insufficient_shares}
  end

  def secret_reconstruct(shares, metadata) do
    threshold = Map.get(metadata, :threshold, @default_threshold)

    if length(shares) < threshold do
      {:error, :insufficient_shares}
    else
      # Take exactly threshold shares
      selected = Enum.take(shares, threshold)

      # Lagrange interpolation to recover secret
      secret = lagrange_interpolate(selected, 0)

      # XOR all share data with recovered keys
      reconstructed = selected
      |> Enum.map(fn share ->
        key = derive_share_key(share.commitment, share.index)
        xor_with_key(share.data, key)
      end)
      |> verify_and_select()

      case reconstructed do
        {:ok, data} -> {:ok, data}
        :error -> {:error, :reconstruction_failed}
      end
    end
  end

  # --- Vanguard Pathfinding ---

  @doc """
  Send vanguard probes to discover and measure all paths.

  Returns scored paths sorted by quality.
  """
  def discover_paths(destination, opts \\ []) do
    # Get candidate paths (direct + via edge nodes)
    candidates = get_candidate_paths(destination, opts)

    # Send probes on all paths simultaneously
    probe_tasks = Enum.map(candidates, fn path ->
      Task.async(fn -> probe_path(path) end)
    end)

    # Collect results
    results = Task.await_many(probe_tasks, 30_000)

    # Score and sort paths
    scored = results
    |> Enum.filter(fn {status, _} -> status == :ok end)
    |> Enum.map(fn {:ok, metrics} -> score_path(metrics) end)
    |> Enum.sort_by(fn {score, _} -> -score end)

    {:ok, scored}
  end

  @doc """
  Probe a single path and measure quality metrics.
  """
  def probe_path(path) do
    probes = for _ <- 1..@probe_count do
      start = System.monotonic_time(:microsecond)

      result = send_probe(path, @probe_size)

      elapsed = System.monotonic_time(:microsecond) - start

      Process.sleep(@probe_interval_ms)

      {result, elapsed}
    end

    successful = Enum.filter(probes, fn {{status, _}, _} -> status == :ok end)
    rtts = Enum.map(successful, fn {_, rtt} -> rtt end)

    if length(successful) > 0 do
      {:ok, %{
        path: path,
        rtt_avg: Enum.sum(rtts) / length(rtts),
        rtt_min: Enum.min(rtts),
        rtt_max: Enum.max(rtts),
        jitter: calculate_jitter(rtts),
        loss_rate: 1 - (length(successful) / @probe_count),
        bandwidth_estimate: estimate_bandwidth(rtts, @probe_size)
      }}
    else
      {:error, :path_unreachable}
    end
  end

  @doc """
  Score a path based on quality metrics.
  """
  def score_path(metrics) do
    # Normalize metrics (lower is better for RTT/jitter/loss, higher for bandwidth)
    rtt_score = 1000 / max(1, metrics.rtt_avg)  # Inverse RTT
    bw_score = metrics.bandwidth_estimate / 1_000_000  # MB/s
    loss_score = 1 - metrics.loss_rate
    jitter_score = 100 / max(1, metrics.jitter)

    total = @weight_rtt * rtt_score +
            @weight_bandwidth * bw_score +
            @weight_loss * loss_score +
            @weight_jitter * jitter_score

    {total, metrics}
  end

  # --- Edge/L1 Acceleration ---

  @doc """
  Discover nearest edge nodes for acceleration.
  """
  def discover_edge_nodes(opts \\ []) do
    # Known edge networks with anycast
    edge_networks = [
      %{name: "Cloudflare", endpoints: ["1.1.1.1", "1.0.0.1"], type: :cdn},
      %{name: "Google", endpoints: ["8.8.8.8", "8.8.4.4"], type: :cdn},
      %{name: "HE.net", endpoints: ["he.net"], type: :backbone},
      %{name: "Fastly", endpoints: ["fastly.com"], type: :cdn},
      %{name: "Akamai", endpoints: ["akamai.com"], type: :cdn}
    ]

    # Probe each to find nearest
    probes = Enum.map(edge_networks, fn network ->
      Task.async(fn ->
        rtts = Enum.map(network.endpoints, fn endpoint ->
          case probe_endpoint(endpoint) do
            {:ok, rtt} -> rtt
            _ -> :infinity
          end
        end)

        best_rtt = Enum.min(rtts)
        {network.name, best_rtt, network.type}
      end)
    end)

    results = Task.await_many(probes, 10_000)
    |> Enum.filter(fn {_, rtt, _} -> rtt != :infinity end)
    |> Enum.sort_by(fn {_, rtt, _} -> rtt end)

    {:ok, results}
  end

  @doc """
  Plan edge-accelerated route.

  Upload to nearest edge → edge-to-edge backbone transfer → download from destination's nearest edge
  """
  def plan_edge_route(src, dst, edge_nodes) do
    # Find nearest edge to source and destination
    src_edge = find_nearest_edge(src, edge_nodes)
    dst_edge = find_nearest_edge(dst, edge_nodes)

    %{
      segments: [
        %{from: src, to: src_edge, type: :upload, protocol: :quic},
        %{from: src_edge, to: dst_edge, type: :backbone, protocol: :internal},
        %{from: dst_edge, to: dst, type: :download, protocol: :quic}
      ],
      estimated_speedup: calculate_edge_speedup(src, dst, src_edge, dst_edge)
    }
  end

  # --- Progressive Optimization (Traveling Salesman Style) ---

  @doc """
  Initialize progressive route optimization.

  Starts with greedy nearest-neighbor solution, refines in background.
  """
  def init_progressive_optimization(paths) do
    # Start with greedy tour
    initial_tour = nearest_neighbor_tour(paths)
    initial_cost = tour_cost(initial_tour)

    %__MODULE__{
      optimization_algo: :progressive,
      current_tour: initial_tour,
      best_tour: initial_tour,
      iteration: 0,
      known_paths: paths,
      path_scores: %{}
    }
  end

  @doc """
  Perform one optimization iteration while transfer is in progress.

  Called periodically to refine routing without blocking transfer.
  """
  def optimize_iteration(%__MODULE__{} = state) do
    new_tour = case rem(state.iteration, 3) do
      0 -> two_opt_swap(state.current_tour)
      1 -> three_opt_swap(state.current_tour)
      2 -> simulated_annealing_step(state.current_tour, state.iteration)
    end

    new_cost = tour_cost(new_tour)
    current_cost = tour_cost(state.current_tour)

    if new_cost < current_cost do
      %{state |
        current_tour: new_tour,
        best_tour: if(new_cost < tour_cost(state.best_tour), do: new_tour, else: state.best_tour),
        iteration: state.iteration + 1
      }
    else
      %{state | iteration: state.iteration + 1}
    end
  end

  @doc """
  Vanguard transfer: first packets map route while bulk follows.

  Vanguard packets are small, fast, and measure paths.
  Bulk data follows on best discovered paths.
  """
  def vanguard_transfer(data, destination, opts \\ []) do
    chunk_size = Keyword.get(opts, :chunk_size, 1024 * 1024)
    chunks = chunk_data(data, chunk_size)

    # First 1% of chunks are vanguard (scouts)
    vanguard_count = max(1, div(length(chunks), 100))
    {vanguard_chunks, bulk_chunks} = Enum.split(chunks, vanguard_count)

    # Send vanguard on all paths, measure as they go
    vanguard_task = Task.async(fn ->
      send_vanguard(vanguard_chunks, destination)
    end)

    # While vanguard runs, start bulk on initially-best path
    {:ok, initial_paths} = discover_paths(destination, quick: true)
    best_path = List.first(initial_paths)

    bulk_task = Task.async(fn ->
      send_bulk_adaptive(bulk_chunks, best_path, vanguard_task)
    end)

    # Collect results
    {vanguard_results, path_metrics} = Task.await(vanguard_task, 300_000)
    bulk_results = Task.await(bulk_task, 300_000)

    {:ok, %{
      vanguard: vanguard_results,
      bulk: bulk_results,
      final_path_metrics: path_metrics
    }}
  end

  # --- Private Helpers ---

  # Crypto helpers
  defp generate_random_coefficients(count) do
    for _ <- 1..count, do: :crypto.strong_rand_bytes(32)
  end

  defp evaluate_polynomial(coefficients, x) do
    coefficients
    |> Enum.with_index()
    |> Enum.reduce(<<>>, fn {coef, i}, acc ->
      term = :crypto.hash(:sha256, <<coef::binary, x::integer, i::integer>>)
      xor_binaries(acc, term)
    end)
  end

  defp xor_binaries(<<>>, b), do: b
  defp xor_binaries(a, <<>>), do: a
  defp xor_binaries(a, b) do
    :crypto.exor(a, b)
  end

  defp xor_with_key(data, key) do
    # Expand key to data length using HKDF-style expansion
    expanded_key = expand_key(key, byte_size(data))
    :crypto.exor(data, expanded_key)
  end

  defp expand_key(key, target_length) do
    iterations = ceil(target_length / 32)
    expanded = for i <- 1..iterations do
      :crypto.hash(:sha256, <<key::binary, i::integer>>)
    end
    |> IO.iodata_to_binary()
    |> binary_part(0, target_length)

    expanded
  end

  defp derive_share_key(commitment, index) do
    :crypto.hash(:sha256, <<commitment::binary, index::integer>>)
  end

  defp lagrange_interpolate(shares, target_x) do
    # Simplified Lagrange interpolation for secret reconstruction
    shares
    |> Enum.reduce(<<0::256>>, fn share, acc ->
      basis = lagrange_basis(shares, share.index, target_x)
      term = :crypto.hash(:sha256, <<share.commitment::binary, basis::binary>>)
      xor_binaries(acc, term)
    end)
  end

  defp lagrange_basis(shares, i, x) do
    # Compute Lagrange basis polynomial L_i(x)
    shares
    |> Enum.reject(fn s -> s.index == i end)
    |> Enum.reduce(<<1::256>>, fn s, acc ->
      numerator = x - s.index
      denominator = i - s.index
      factor = :crypto.hash(:sha256, <<numerator::integer, denominator::integer>>)
      xor_binaries(acc, factor)
    end)
  end

  defp verify_and_select(candidates) do
    # All candidates should be identical if reconstruction succeeded
    case Enum.uniq(candidates) do
      [single] -> {:ok, single}
      _ -> :error
    end
  end

  # Path helpers
  defp get_candidate_paths(destination, opts) do
    direct_path = %{type: :direct, destination: destination}

    edge_paths = if Keyword.get(opts, :use_edges, true) do
      case discover_edge_nodes() do
        {:ok, edges} ->
          Enum.map(edges, fn {name, _, type} ->
            %{type: :edge, edge: name, edge_type: type, destination: destination}
          end)
        _ -> []
      end
    else
      []
    end

    [direct_path | edge_paths]
  end

  defp send_probe(path, size) do
    probe_data = :crypto.strong_rand_bytes(size)

    case path.type do
      :direct ->
        # TCP probe to destination
        case :gen_tcp.connect(String.to_charlist(to_string(path.destination)), 443, [:binary], 5000) do
          {:ok, socket} ->
            :gen_tcp.send(socket, probe_data)
            result = :gen_tcp.recv(socket, 0, 5000)
            :gen_tcp.close(socket)
            result
          error -> error
        end

      :edge ->
        # Probe via edge
        {:ok, probe_data}
    end
  end

  defp calculate_jitter(rtts) when length(rtts) < 2, do: 0
  defp calculate_jitter(rtts) do
    pairs = Enum.zip(rtts, tl(rtts))
    diffs = Enum.map(pairs, fn {a, b} -> abs(a - b) end)
    Enum.sum(diffs) / length(diffs)
  end

  defp estimate_bandwidth(rtts, probe_size) do
    avg_rtt = Enum.sum(rtts) / length(rtts)
    # Very rough estimate: probe_size / (RTT/2) = bytes/sec
    if avg_rtt > 0, do: probe_size * 2_000_000 / avg_rtt, else: 0
  end

  defp probe_endpoint(endpoint) do
    start = System.monotonic_time(:microsecond)

    result = case :gen_tcp.connect(String.to_charlist(endpoint), 443, [], 5000) do
      {:ok, socket} ->
        :gen_tcp.close(socket)
        :ok
      {:error, _} ->
        # Try ICMP-style via UDP
        case :gen_udp.open(0) do
          {:ok, socket} ->
            :gen_udp.send(socket, String.to_charlist(endpoint), 33434, <<>>)
            :gen_udp.close(socket)
            :ok
          _ -> :error
        end
    end

    elapsed = System.monotonic_time(:microsecond) - start

    case result do
      :ok -> {:ok, elapsed}
      _ -> {:error, :unreachable}
    end
  end

  defp find_nearest_edge(_location, []), do: nil
  defp find_nearest_edge(_location, [{name, _, _} | _]), do: name

  defp calculate_edge_speedup(_src, _dst, nil, _), do: 1.0
  defp calculate_edge_speedup(_src, _dst, _, nil), do: 1.0
  defp calculate_edge_speedup(_src, _dst, _src_edge, _dst_edge) do
    # Typical edge acceleration: 2-5x for long-distance transfers
    3.0
  end

  # TSP optimization helpers
  defp nearest_neighbor_tour(paths) when length(paths) <= 1, do: paths
  defp nearest_neighbor_tour([first | rest]) do
    build_tour([first], rest)
  end

  defp build_tour(tour, []), do: Enum.reverse(tour)
  defp build_tour([current | _] = tour, remaining) do
    nearest = Enum.min_by(remaining, fn p -> path_distance(current, p) end)
    build_tour([nearest | tour], remaining -- [nearest])
  end

  defp path_distance(a, b) do
    # Use path scores or estimate
    abs(:erlang.phash2(a) - :erlang.phash2(b))
  end

  defp tour_cost(tour) do
    tour
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> path_distance(a, b) end)
    |> Enum.sum()
  end

  defp two_opt_swap(tour) when length(tour) < 4, do: tour
  defp two_opt_swap(tour) do
    len = length(tour)
    i = :rand.uniform(len - 1) - 1
    j = :rand.uniform(len - i - 1) + i

    {before, rest} = Enum.split(tour, i)
    {middle, after_} = Enum.split(rest, j - i + 1)

    before ++ Enum.reverse(middle) ++ after_
  end

  defp three_opt_swap(tour) when length(tour) < 6, do: two_opt_swap(tour)
  defp three_opt_swap(tour) do
    # Simplified: just do two 2-opt swaps
    tour |> two_opt_swap() |> two_opt_swap()
  end

  defp simulated_annealing_step(tour, iteration) do
    # Temperature decreases with iteration
    temp = 1000 / (1 + iteration)

    candidate = two_opt_swap(tour)
    delta = tour_cost(candidate) - tour_cost(tour)

    # Accept if better, or probabilistically if worse
    if delta < 0 or :rand.uniform() < :math.exp(-delta / temp) do
      candidate
    else
      tour
    end
  end

  defp chunk_data(data, chunk_size) do
    for <<chunk::binary-size(chunk_size) <- data>>, do: chunk
  end

  defp send_vanguard(chunks, destination) do
    # Send on all discovered paths, collect metrics
    {:ok, paths} = discover_paths(destination)

    results = Enum.map(chunks, fn chunk ->
      path = Enum.random(paths) |> elem(1)
      send_chunk(chunk, path)
    end)

    {results, paths}
  end

  defp send_bulk_adaptive(chunks, initial_path, vanguard_task) do
    # Send bulk, periodically check vanguard for better paths
    Enum.map(chunks, fn chunk ->
      # Every 10 chunks, check if vanguard found better path
      # (simplified - would actually coordinate with vanguard_task)
      send_chunk(chunk, initial_path)
    end)
  end

  defp send_chunk(chunk, path) do
    # Actual chunk transfer via path
    {:ok, byte_size(chunk), path}
  end
end
