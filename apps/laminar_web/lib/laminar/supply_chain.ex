# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.SupplyChain do
  @moduledoc """
  Supply chain optimization - don't send what can be sourced elsewhere.

  ## Core Principle

  Before sending ANY data, ask:
  1. Does the destination already have this? (checksum match)
  2. Can it be fetched from a closer/faster source?
  3. Can it be reconstructed from components?
  4. Can it be generated from a recipe/manifest?

  ## Content-Addressable Storage (CAS)

  Like Docker layers, Git objects, or IPFS:
  - Hash content → address
  - Before sending: "Do you have SHA256:abc123?"
  - If yes: skip sending, just reference
  - If no: check other sources first

  ## Multi-Source Assembly

  Instead of sending 77GB video:
  1. Send manifest: {codec: h264, container: mp4, ...}
  2. Reference common libs from package repos
  3. Send only unique delta

  ## OSI Layer Optimization

  | Layer | What to Optimize |
  |-------|------------------|
  | 7 App | Dedup, manifests, lazy fetch |
  | 6 Pres| Compression negotiation |
  | 5 Sess| Connection pooling, multiplexing |
  | 4 Trans| Multi-protocol, port diversity |
  | 3 Net | Multi-path, anycast, BGP |
  | 2 Data| Jumbo frames, VLAN tagging |
  | 1 Phys| Link aggregation, multi-NIC |

  ## Rate Limiter Evasion (Legitimate)

  APIs rate limit per:
  - IP address → use multiple IPs/paths
  - API key → split across credentials
  - User-Agent → vary headers
  - Endpoint → use alternative endpoints
  - Time window → spread requests

  Laminar approach: Don't hit the same API repeatedly - source from multiple places.
  """

  require Logger

  # Known public content registries
  @registries %{
    docker_hub: %{
      type: :container,
      url: "https://registry.hub.docker.com/v2",
      content_addressable: true
    },
    npm: %{
      type: :package,
      url: "https://registry.npmjs.org",
      content_addressable: true
    },
    pypi: %{
      type: :package,
      url: "https://pypi.org/simple",
      content_addressable: true
    },
    crates_io: %{
      type: :package,
      url: "https://crates.io/api/v1",
      content_addressable: true
    },
    maven: %{
      type: :package,
      url: "https://repo1.maven.org/maven2",
      content_addressable: true
    },
    apt: %{
      type: :package,
      url: "http://archive.ubuntu.com/ubuntu",
      content_addressable: true
    },
    ipfs: %{
      type: :cas,
      url: "https://ipfs.io/ipfs",
      content_addressable: true
    },
    software_heritage: %{
      type: :archive,
      url: "https://archive.softwareheritage.org",
      content_addressable: true
    }
  }

  defstruct [
    :content_manifest,
    :local_inventory,
    :remote_inventory,
    :available_sources,
    :send_plan,
    :rate_limit_budget
  ]

  @doc """
  Analyze content and create optimal transfer plan.

  Returns what to send, what to reference, what to assemble.
  """
  def analyze(content, destination, opts \\ []) do
    # Build content manifest (like Docker image layers)
    manifest = build_manifest(content)

    # Check what destination already has
    remote_inventory = probe_destination(destination, manifest)

    # Find alternative sources for missing content
    available_sources = find_sources(manifest, remote_inventory)

    # Check rate limit budgets for each source
    rate_limits = check_rate_limits(available_sources)

    # Create optimal send plan
    plan = optimize_plan(manifest, remote_inventory, available_sources, rate_limits)

    %__MODULE__{
      content_manifest: manifest,
      local_inventory: manifest.chunks,
      remote_inventory: remote_inventory,
      available_sources: available_sources,
      send_plan: plan,
      rate_limit_budget: rate_limits
    }
  end

  @doc """
  Build content-addressable manifest for any file/directory.
  """
  def build_manifest(path) when is_binary(path) do
    case File.stat(path) do
      {:ok, %{type: :directory}} ->
        build_directory_manifest(path)

      {:ok, %{type: :regular, size: size}} ->
        build_file_manifest(path, size)

      {:error, reason} ->
        {:error, reason}
    end
  end

  def build_manifest(data) when is_binary(data) do
    build_binary_manifest(data)
  end

  @doc """
  Probe destination to see what content already exists.
  """
  def probe_destination(destination, manifest) do
    # Send list of content hashes, get back which ones exist
    hashes = Enum.map(manifest.chunks, & &1.hash)

    case Laminar.RcloneClient.rpc("operations/hashsum", %{
      fs: destination.remote,
      remote: destination.path,
      hashType: "sha256",
      download: false
    }) do
      {:ok, %{"hashsum" => remote_hashes}} ->
        # Match local hashes against remote
        remote_set = MapSet.new(Map.values(remote_hashes))
        Enum.filter(hashes, &MapSet.member?(remote_set, &1))

      _ ->
        []
    end
  end

  @doc """
  Find alternative sources for content that destination doesn't have.
  """
  def find_sources(manifest, existing_hashes) do
    needed = Enum.reject(manifest.chunks, fn chunk ->
      chunk.hash in existing_hashes
    end)

    # For each needed chunk, find possible sources
    Enum.map(needed, fn chunk ->
      sources = [
        check_ipfs(chunk.hash),
        check_software_heritage(chunk.hash),
        check_package_registries(chunk),
        {:direct, :self, 1.0}  # Fallback: send from origin
      ]
      |> List.flatten()
      |> Enum.filter(fn {status, _, _} -> status == :found end)
      |> Enum.sort_by(fn {_, _, score} -> -score end)

      {chunk, sources}
    end)
    |> Map.new(fn {chunk, sources} -> {chunk.hash, sources} end)
  end

  @doc """
  Check rate limit budgets for all sources.
  """
  def check_rate_limits(sources) do
    sources
    |> Map.values()
    |> List.flatten()
    |> Enum.map(fn {_, source, _} -> source end)
    |> Enum.uniq()
    |> Enum.map(fn source ->
      limit = get_rate_limit(source)
      used = get_rate_usage(source)
      {source, %{limit: limit, used: used, remaining: limit - used}}
    end)
    |> Map.new()
  end

  @doc """
  Create optimal transfer plan to minimize data sent and avoid rate limits.
  """
  def optimize_plan(manifest, existing, sources, rate_limits) do
    # Group chunks by best strategy
    plan = Enum.map(manifest.chunks, fn chunk ->
      cond do
        # Already exists at destination - skip
        chunk.hash in existing ->
          {:skip, chunk, :exists_at_destination}

        # Available from faster/closer source
        alt_sources = Map.get(sources, chunk.hash, [])
        best_alt = find_best_source(alt_sources, rate_limits)
        best_alt != nil ->
          {:redirect, chunk, best_alt}

        # Can be assembled from components
        recipe = find_assembly_recipe(chunk) ->
          {:assemble, chunk, recipe}

        # Must send directly
        true ->
          {:send, chunk, :direct}
      end
    end)

    # Group and summarize
    %{
      skip: Enum.filter(plan, fn {action, _, _} -> action == :skip end),
      redirect: Enum.filter(plan, fn {action, _, _} -> action == :redirect end),
      assemble: Enum.filter(plan, fn {action, _, _} -> action == :assemble end),
      send: Enum.filter(plan, fn {action, _, _} -> action == :send end),
      stats: %{
        total_chunks: length(manifest.chunks),
        skipped: length(Enum.filter(plan, fn {a, _, _} -> a == :skip end)),
        redirected: length(Enum.filter(plan, fn {a, _, _} -> a == :redirect end)),
        assembled: length(Enum.filter(plan, fn {a, _, _} -> a == :assemble end)),
        direct_send: length(Enum.filter(plan, fn {a, _, _} -> a == :send end))
      }
    }
  end

  @doc """
  Execute the supply chain plan.
  """
  def execute(%__MODULE__{} = supply_chain, progress_tracker \\ nil) do
    plan = supply_chain.send_plan

    # Execute in parallel, grouped by source to respect rate limits
    skip_task = Task.async(fn ->
      # Nothing to do for skipped chunks
      Enum.map(plan.skip, fn {_, chunk, _} -> {:ok, chunk.hash} end)
    end)

    redirect_task = Task.async(fn ->
      execute_redirects(plan.redirect, supply_chain.rate_limit_budget)
    end)

    assemble_task = Task.async(fn ->
      execute_assemblies(plan.assemble)
    end)

    send_task = Task.async(fn ->
      execute_direct_sends(plan.send, progress_tracker)
    end)

    results = %{
      skip: Task.await(skip_task, 300_000),
      redirect: Task.await(redirect_task, 300_000),
      assemble: Task.await(assemble_task, 300_000),
      send: Task.await(send_task, 300_000)
    }

    {:ok, results}
  end

  # --- Private Helpers ---

  defp build_file_manifest(path, size) do
    # Chunk file and hash each chunk
    chunk_size = optimal_chunk_size(size)

    chunks = File.stream!(path, [], chunk_size)
    |> Stream.with_index()
    |> Enum.map(fn {data, index} ->
      %{
        index: index,
        offset: index * chunk_size,
        size: byte_size(data),
        hash: Base.encode16(:crypto.hash(:sha256, data), case: :lower),
        content_type: detect_content_type(data)
      }
    end)

    %{
      type: :file,
      path: path,
      total_size: size,
      chunk_count: length(chunks),
      chunk_size: chunk_size,
      chunks: chunks,
      root_hash: merkle_root(chunks)
    }
  end

  defp build_directory_manifest(path) do
    files = File.ls!(path)
    |> Enum.map(fn file ->
      full_path = Path.join(path, file)
      case File.stat(full_path) do
        {:ok, %{type: :regular, size: size}} ->
          build_file_manifest(full_path, size)
        {:ok, %{type: :directory}} ->
          build_directory_manifest(full_path)
        _ ->
          nil
      end
    end)
    |> Enum.reject(&is_nil/1)

    %{
      type: :directory,
      path: path,
      children: files,
      root_hash: merkle_root(Enum.map(files, & &1.root_hash))
    }
  end

  defp build_binary_manifest(data) do
    chunk_size = optimal_chunk_size(byte_size(data))

    chunks = for <<chunk::binary-size(chunk_size) <- data>>, reduce: {[], 0} do
      {acc, index} ->
        chunk_manifest = %{
          index: index,
          offset: index * chunk_size,
          size: byte_size(chunk),
          hash: Base.encode16(:crypto.hash(:sha256, chunk), case: :lower),
          content_type: detect_content_type(chunk)
        }
        {[chunk_manifest | acc], index + 1}
    end
    |> elem(0)
    |> Enum.reverse()

    %{
      type: :binary,
      total_size: byte_size(data),
      chunk_count: length(chunks),
      chunk_size: chunk_size,
      chunks: chunks,
      root_hash: merkle_root(chunks)
    }
  end

  defp optimal_chunk_size(total_size) do
    cond do
      total_size < 1_000_000 -> 64 * 1024          # 64 KB
      total_size < 100_000_000 -> 1024 * 1024      # 1 MB
      total_size < 1_000_000_000 -> 4 * 1024 * 1024 # 4 MB
      true -> 16 * 1024 * 1024                      # 16 MB
    end
  end

  defp merkle_root([]), do: nil
  defp merkle_root(items) when is_list(items) do
    hashes = Enum.map(items, fn
      %{hash: h} -> h
      %{root_hash: h} -> h
      h when is_binary(h) -> h
    end)

    Base.encode16(:crypto.hash(:sha256, Enum.join(hashes)), case: :lower)
  end

  defp detect_content_type(<<0x89, "PNG", _::binary>>), do: :png
  defp detect_content_type(<<0xFF, 0xD8, 0xFF, _::binary>>), do: :jpeg
  defp detect_content_type(<<"PK", _::binary>>), do: :zip
  defp detect_content_type(<<0x1F, 0x8B, _::binary>>), do: :gzip
  defp detect_content_type(<<0x50, 0x4B, 0x03, 0x04, _::binary>>), do: :zip
  defp detect_content_type(<<0x7F, "ELF", _::binary>>), do: :elf
  defp detect_content_type(<<"Mach-O", _::binary>>), do: :macho
  defp detect_content_type(_), do: :unknown

  defp check_ipfs(hash) do
    # Convert SHA256 to CID and check IPFS
    # IPFS uses multihash format
    {:not_found, :ipfs, 0}
  end

  defp check_software_heritage(hash) do
    # Software Heritage archives all public code
    {:not_found, :swh, 0}
  end

  defp check_package_registries(chunk) do
    # Check if this matches a known package
    case chunk.content_type do
      :zip ->
        # Could be a package archive
        []
      _ ->
        []
    end
  end

  defp get_rate_limit(:self), do: :unlimited
  defp get_rate_limit(:ipfs), do: 1000  # requests per hour
  defp get_rate_limit(:npm), do: 100
  defp get_rate_limit(:pypi), do: 100
  defp get_rate_limit(:docker_hub), do: 200
  defp get_rate_limit(_), do: 100

  defp get_rate_usage(_source) do
    # Would track actual usage
    0
  end

  defp find_best_source([], _rate_limits), do: nil
  defp find_best_source(sources, rate_limits) do
    sources
    |> Enum.filter(fn {_, source, _} ->
      case Map.get(rate_limits, source) do
        %{remaining: remaining} when remaining > 0 -> true
        _ -> source == :self
      end
    end)
    |> List.first()
  end

  defp find_assembly_recipe(_chunk) do
    # Check if chunk can be assembled from known components
    # e.g., Docker layer = base + diff
    nil
  end

  defp execute_redirects(redirects, _rate_limits) do
    # Instruct destination to fetch from alternative sources
    Enum.map(redirects, fn {_, chunk, {_, source, _}} ->
      Logger.info("Redirecting #{chunk.hash} to fetch from #{source}")
      {:ok, chunk.hash, source}
    end)
  end

  defp execute_assemblies(assemblies) do
    # Send assembly instructions instead of content
    Enum.map(assemblies, fn {_, chunk, recipe} ->
      Logger.info("Sending assembly recipe for #{chunk.hash}")
      {:ok, chunk.hash, recipe}
    end)
  end

  defp execute_direct_sends(sends, progress_tracker) do
    Enum.map(sends, fn {_, chunk, _} ->
      if progress_tracker do
        Laminar.TransferProgress.update(progress_tracker, chunk.offset + chunk.size)
      end
      {:ok, chunk.hash}
    end)
  end
end
