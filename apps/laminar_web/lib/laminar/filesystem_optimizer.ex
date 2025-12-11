# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.FilesystemOptimizer do
  @moduledoc """
  Filesystem-specific optimizations for transfer operations.

  Detects filesystem types and applies optimal settings for:
  - Local filesystems (ext4, btrfs, xfs, zfs, ntfs, apfs)
  - Network filesystems (nfs, cifs/smb, sshfs)
  - Cloud providers (S3, GCS, Azure Blob, B2, etc.)

  Optimizations include:
  - Chunk size tuning
  - Parallel transfer counts
  - Buffer sizes
  - Copy-on-write utilization
  - Compression recommendations
  - Deduplication hints
  """

  require Logger

  @doc """
  Detect filesystem type for a path.
  """
  def detect_filesystem(path) do
    cond do
      # Cloud remote (has : separator)
      String.contains?(path, ":") and not String.starts_with?(path, "/") ->
        detect_cloud_provider(path)

      # Local path
      true ->
        detect_local_filesystem(path)
    end
  end

  @doc """
  Get optimized rclone configuration for source/destination pair.
  """
  def get_optimized_config(source, destination) do
    source_fs = detect_filesystem(source)
    dest_fs = detect_filesystem(destination)

    base_config = %{
      transfers: 4,
      checkers: 8,
      buffer_size: "16M",
      chunk_size: "8M",
      use_mmap: false,
      checksum: true,
      streaming: false,
      low_level_retries: 10,
      retries: 3
    }

    # Apply source optimizations
    config = apply_source_optimizations(base_config, source_fs)

    # Apply destination optimizations
    config = apply_dest_optimizations(config, dest_fs)

    # Apply pair-specific optimizations
    apply_pair_optimizations(config, source_fs, dest_fs)
  end

  @doc """
  Get human-readable recommendations for a transfer.
  """
  def get_recommendations(source, destination) do
    source_fs = detect_filesystem(source)
    dest_fs = detect_filesystem(destination)

    recommendations = []

    # Source recommendations
    recommendations = recommendations ++ source_recommendations(source_fs)

    # Destination recommendations
    recommendations = recommendations ++ dest_recommendations(dest_fs)

    # Pair recommendations
    recommendations = recommendations ++ pair_recommendations(source_fs, dest_fs)

    %{
      source: %{
        path: source,
        filesystem: source_fs
      },
      destination: %{
        path: destination,
        filesystem: dest_fs
      },
      recommendations: recommendations
    }
  end

  @doc """
  Convert optimized config to rclone arguments.
  """
  def to_rclone_args(config) do
    args = [
      "--transfers", to_string(config.transfers),
      "--checkers", to_string(config.checkers),
      "--buffer-size", config.buffer_size,
      "--drive-chunk-size", config.chunk_size,
      "--low-level-retries", to_string(config.low_level_retries),
      "--retries", to_string(config.retries)
    ]

    args = if config.use_mmap, do: args ++ ["--use-mmap"], else: args
    args = if config.checksum, do: args ++ ["--checksum"], else: args
    args = if config.streaming, do: args ++ ["--streaming-upload-cutoff", "0"], else: args

    args
  end

  # Filesystem detection

  defp detect_local_filesystem(path) do
    # Use df -T to get filesystem type
    abs_path = Path.expand(path)

    case System.cmd("df", ["-T", abs_path], stderr_to_stdout: true) do
      {output, 0} ->
        # Parse the filesystem type from df output
        lines = String.split(output, "\n")
        if length(lines) > 1 do
          # Second line contains the info
          fields = Enum.at(lines, 1) |> String.split() |> Enum.filter(&(&1 != ""))
          fs_type = Enum.at(fields, 1, "unknown")
          normalize_filesystem_type(fs_type)
        else
          %{type: :local, subtype: :unknown}
        end

      _ ->
        # Fallback: try to read /etc/mtab or /proc/mounts
        detect_from_mounts(abs_path)
    end
  end

  defp detect_from_mounts(path) do
    mount_info = case File.read("/proc/mounts") do
      {:ok, content} -> content
      _ ->
        case File.read("/etc/mtab") do
          {:ok, content} -> content
          _ -> ""
        end
    end

    # Find the mount point for this path
    mounts = mount_info
    |> String.split("\n")
    |> Enum.map(&String.split/1)
    |> Enum.filter(fn parts -> length(parts) >= 3 end)
    |> Enum.map(fn [_device, mount_point, fs_type | _] -> {mount_point, fs_type} end)
    |> Enum.sort_by(fn {mp, _} -> -String.length(mp) end)

    match = Enum.find(mounts, fn {mount_point, _} ->
      String.starts_with?(path, mount_point)
    end)

    case match do
      {_, fs_type} -> normalize_filesystem_type(fs_type)
      nil -> %{type: :local, subtype: :unknown}
    end
  end

  defp normalize_filesystem_type(fs_type) do
    case String.downcase(fs_type) do
      "ext4" -> %{type: :local, subtype: :ext4, cow: false, compression: false}
      "ext3" -> %{type: :local, subtype: :ext3, cow: false, compression: false}
      "ext2" -> %{type: :local, subtype: :ext2, cow: false, compression: false}
      "btrfs" -> %{type: :local, subtype: :btrfs, cow: true, compression: true, dedup: true}
      "xfs" -> %{type: :local, subtype: :xfs, cow: false, compression: false, reflink: true}
      "zfs" -> %{type: :local, subtype: :zfs, cow: true, compression: true, dedup: true}
      "ntfs" -> %{type: :local, subtype: :ntfs, cow: false, compression: true}
      "apfs" -> %{type: :local, subtype: :apfs, cow: true, compression: true, cloning: true}
      "hfs+" -> %{type: :local, subtype: :hfsplus, cow: false, compression: false}
      "exfat" -> %{type: :local, subtype: :exfat, cow: false, compression: false}
      "fat32" -> %{type: :local, subtype: :fat32, cow: false, compression: false}
      "vfat" -> %{type: :local, subtype: :fat32, cow: false, compression: false}
      "nfs" <> _ -> %{type: :network, subtype: :nfs, streaming: true}
      "cifs" -> %{type: :network, subtype: :smb, streaming: false}
      "smbfs" -> %{type: :network, subtype: :smb, streaming: false}
      "fuse.sshfs" -> %{type: :network, subtype: :sshfs, streaming: true}
      "tmpfs" -> %{type: :memory, subtype: :tmpfs, fast: true}
      "ramfs" -> %{type: :memory, subtype: :ramfs, fast: true}
      _ -> %{type: :local, subtype: :unknown}
    end
  end

  defp detect_cloud_provider(path) do
    [remote | _] = String.split(path, ":", parts: 2)

    case String.downcase(remote) do
      r when r in ["gdrive", "drive", "google"] ->
        %{type: :cloud, subtype: :gdrive, provider: :google, api_limit: true, chunk_size: "8M"}

      r when r in ["s3", "aws"] ->
        %{type: :cloud, subtype: :s3, provider: :aws, multipart: true, chunk_size: "5M"}

      r when r in ["gcs", "gs"] ->
        %{type: :cloud, subtype: :gcs, provider: :google, resumable: true, chunk_size: "8M"}

      r when r in ["azure", "azureblob"] ->
        %{type: :cloud, subtype: :azure, provider: :microsoft, chunk_size: "4M"}

      r when r in ["b2", "backblaze"] ->
        %{type: :cloud, subtype: :b2, provider: :backblaze, chunk_size: "96M"}

      r when r in ["dropbox"] ->
        %{type: :cloud, subtype: :dropbox, provider: :dropbox, chunk_size: "48M"}

      r when r in ["onedrive", "od"] ->
        %{type: :cloud, subtype: :onedrive, provider: :microsoft, chunk_size: "10M"}

      r when r in ["box"] ->
        %{type: :cloud, subtype: :box, provider: :box, chunk_size: "50M"}

      r when r in ["mega"] ->
        %{type: :cloud, subtype: :mega, provider: :mega, encrypted: true}

      r when r in ["sftp", "ssh"] ->
        %{type: :network, subtype: :sftp, streaming: true}

      r when r in ["ftp", "ftps"] ->
        %{type: :network, subtype: :ftp, streaming: false}

      r when r in ["webdav", "nextcloud", "owncloud"] ->
        %{type: :network, subtype: :webdav, streaming: false}

      _ ->
        %{type: :cloud, subtype: :unknown}
    end
  end

  # Optimization application

  defp apply_source_optimizations(config, source_fs) do
    case source_fs do
      %{type: :local, subtype: :btrfs} ->
        # Btrfs: Use larger reads, enable compression detection
        %{config | buffer_size: "64M", use_mmap: true}

      %{type: :local, subtype: :zfs} ->
        # ZFS: Align to recordsize, use large buffers
        %{config | buffer_size: "128M", use_mmap: true}

      %{type: :local, subtype: :xfs} ->
        # XFS: Good with parallel reads
        %{config | checkers: 16, use_mmap: true}

      %{type: :local, subtype: :ntfs} ->
        # NTFS: Lower parallelism to avoid lock contention
        %{config | transfers: 2, checkers: 4}

      %{type: :network, subtype: :nfs} ->
        # NFS: Use streaming, larger buffers
        %{config | buffer_size: "32M", streaming: true}

      %{type: :network, subtype: :smb} ->
        # SMB: Lower parallelism, careful with large files
        %{config | transfers: 2, buffer_size: "8M"}

      %{type: :cloud, subtype: :gdrive} ->
        # Google Drive: Respect API limits
        %{config | transfers: 3, chunk_size: "8M"}

      %{type: :cloud, subtype: :s3} ->
        # S3: High parallelism, multipart
        %{config | transfers: 8, checkers: 16, chunk_size: "16M"}

      %{type: :cloud, subtype: :b2} ->
        # B2: Large chunks, moderate parallelism
        %{config | transfers: 4, chunk_size: "96M"}

      %{type: :memory} ->
        # tmpfs/ramfs: Max speed
        %{config | transfers: 16, checkers: 32, use_mmap: true}

      _ ->
        config
    end
  end

  defp apply_dest_optimizations(config, dest_fs) do
    case dest_fs do
      %{type: :local, subtype: :btrfs} ->
        # Btrfs: Can use reflinks for local copies
        %{config | buffer_size: "64M"}

      %{type: :local, subtype: :zfs} ->
        # ZFS: Large writes, align to recordsize
        %{config | buffer_size: "128M"}

      %{type: :local, subtype: :ntfs} ->
        # NTFS: Lower parallelism
        %{config | transfers: min(config.transfers, 2)}

      %{type: :cloud, subtype: :gdrive} ->
        # Google Drive: Chunked uploads
        %{config | chunk_size: "8M", transfers: min(config.transfers, 3)}

      %{type: :cloud, subtype: :s3} ->
        # S3: Multipart uploads
        %{config | chunk_size: "16M"}

      %{type: :cloud, subtype: :b2} ->
        # B2: Large chunks (free up to 5GB/file)
        %{config | chunk_size: "96M"}

      %{type: :cloud, subtype: :dropbox} ->
        # Dropbox: Moderate chunk size
        %{config | chunk_size: "48M", transfers: min(config.transfers, 4)}

      _ ->
        config
    end
  end

  defp apply_pair_optimizations(config, source_fs, dest_fs) do
    cond do
      # Local to local with CoW filesystems
      source_fs[:type] == :local and dest_fs[:type] == :local and
      (source_fs[:cow] or dest_fs[:cow]) ->
        # Enable reflink copies if possible
        config

      # Cloud to cloud (same provider)
      source_fs[:type] == :cloud and dest_fs[:type] == :cloud and
      source_fs[:subtype] == dest_fs[:subtype] ->
        # Server-side copy is possible
        %{config | checksum: false}  # Skip checksum, server handles it

      # Local to cloud
      source_fs[:type] == :local and dest_fs[:type] == :cloud ->
        # Increase transfers for upload
        %{config | transfers: min(config.transfers * 2, 16)}

      # Cloud to local
      source_fs[:type] == :cloud and dest_fs[:type] == :local ->
        # Balance for download
        %{config | transfers: min(config.transfers * 2, 12)}

      # Network to network
      source_fs[:type] == :network and dest_fs[:type] == :network ->
        # Conservative settings
        %{config | transfers: 2, buffer_size: "8M"}

      true ->
        config
    end
  end

  # Recommendations

  defp source_recommendations(fs) do
    case fs do
      %{type: :local, subtype: :btrfs} ->
        [%{
          type: :optimization,
          title: "Btrfs source detected",
          description: "Using memory-mapped I/O and large buffers for optimal read performance.",
          tip: "Consider mounting with 'compress=zstd' for transparent compression."
        }]

      %{type: :local, subtype: :zfs} ->
        [%{
          type: :optimization,
          title: "ZFS source detected",
          description: "Aligned buffer sizes with ZFS recordsize for maximum throughput.",
          tip: "Run 'zpool iostat 1' to monitor pool performance during transfer."
        }]

      %{type: :cloud, subtype: :gdrive, api_limit: true} ->
        [%{
          type: :warning,
          title: "Google Drive API limits",
          description: "Transfers limited to 3 parallel streams to stay within API quotas.",
          tip: "For large transfers, consider using a service account or enabling 'Shared Drives'."
        }]

      %{type: :network, subtype: :nfs} ->
        [%{
          type: :info,
          title: "NFS source",
          description: "Streaming enabled for network efficiency.",
          tip: "Ensure NFS server has adequate I/O capacity."
        }]

      _ ->
        []
    end
  end

  defp dest_recommendations(fs) do
    case fs do
      %{type: :cloud, subtype: :b2} ->
        [%{
          type: :optimization,
          title: "Backblaze B2 destination",
          description: "Using 96MB chunks for optimal B2 performance (free transfers up to 5GB/file).",
          tip: "B2 charges for API calls, large chunks reduce costs."
        }]

      %{type: :cloud, subtype: :s3} ->
        [%{
          type: :info,
          title: "S3 destination",
          description: "Multipart uploads enabled for reliable large file transfers.",
          tip: "Consider using S3 Transfer Acceleration for cross-region transfers."
        }]

      %{type: :local, subtype: :ntfs} ->
        [%{
          type: :warning,
          title: "NTFS destination",
          description: "Reduced parallelism to avoid MFT contention.",
          tip: "NTFS performance degrades with many small files in one directory."
        }]

      _ ->
        []
    end
  end

  defp pair_recommendations(source_fs, dest_fs) do
    cond do
      # Same cloud provider
      source_fs[:type] == :cloud and dest_fs[:type] == :cloud and
      source_fs[:subtype] == dest_fs[:subtype] ->
        [%{
          type: :optimization,
          title: "Server-side copy available",
          description: "Files will be copied within #{source_fs[:provider]} without downloading.",
          tip: "This is the fastest and cheapest way to copy within a cloud provider."
        }]

      # CoW to CoW
      source_fs[:cow] == true and dest_fs[:cow] == true ->
        [%{
          type: :optimization,
          title: "Copy-on-write filesystems",
          description: "Reflink copies may be used for instant, space-efficient copies.",
          tip: "Use 'cp --reflink=auto' for local copies before transfer."
        }]

      # Slow to fast
      source_fs[:type] == :network and dest_fs[:type] == :local ->
        [%{
          type: :info,
          title: "Network to local transfer",
          description: "Buffering enabled to handle network latency.",
          tip: "Local disk speed should not be the bottleneck."
        }]

      true ->
        []
    end
  end
end
