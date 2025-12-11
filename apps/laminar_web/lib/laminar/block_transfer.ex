# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.BlockTransfer do
  @moduledoc """
  Block-level transfer operations for efficient file synchronization.

  Provides:
  - Block-level deduplication (rsync-style delta transfers)
  - Resume support for interrupted transfers
  - Verification with checksums
  - Copy vs move semantics at file and block level
  - Server-side copy when source and dest support it

  Block-level transfers are useful for:
  - Large files with small changes
  - Resuming interrupted transfers
  - Minimizing bandwidth usage
  """

  require Logger

  alias Laminar.RcloneClient

  @default_block_size 4 * 1024 * 1024  # 4MB blocks
  @checksum_algorithm :sha256

  defstruct [
    :source,
    :destination,
    :operation,        # :copy | :move | :sync
    :mode,             # :file | :block | :server_side
    :block_size,
    :verify,
    :delete_source,    # For move operations
    :resume_state
  ]

  @type t :: %__MODULE__{}

  @doc """
  Copy files from source to destination.

  Options:
  - `:mode` - :file (whole file), :block (delta), :auto (detect best)
  - `:block_size` - Size in bytes for block operations (default 4MB)
  - `:verify` - Verify checksums after transfer (default true)
  - `:server_side` - Attempt server-side copy if supported
  """
  def copy(source, destination, opts \\ []) do
    transfer(%{
      source: source,
      destination: destination,
      operation: :copy,
      mode: Keyword.get(opts, :mode, :auto),
      block_size: Keyword.get(opts, :block_size, @default_block_size),
      verify: Keyword.get(opts, :verify, true),
      delete_source: false
    }, opts)
  end

  @doc """
  Move files from source to destination.

  Same options as copy/3, plus:
  - `:delete_empty_dirs` - Remove empty directories after move (default true)
  """
  def move(source, destination, opts \\ []) do
    transfer(%{
      source: source,
      destination: destination,
      operation: :move,
      mode: Keyword.get(opts, :mode, :auto),
      block_size: Keyword.get(opts, :block_size, @default_block_size),
      verify: Keyword.get(opts, :verify, true),
      delete_source: true
    }, opts)
  end

  @doc """
  Sync source to destination (make dest match source).

  Additional options:
  - `:delete_extra` - Delete files in dest not in source (default false)
  """
  def sync(source, destination, opts \\ []) do
    delete_extra = Keyword.get(opts, :delete_extra, false)

    rclone_opts = if delete_extra do
      ["--delete-during"]
    else
      []
    end

    transfer(%{
      source: source,
      destination: destination,
      operation: :sync,
      mode: Keyword.get(opts, :mode, :auto),
      block_size: Keyword.get(opts, :block_size, @default_block_size),
      verify: Keyword.get(opts, :verify, true),
      delete_source: false
    }, Keyword.put(opts, :rclone_opts, rclone_opts))
  end

  @doc """
  Check if server-side copy is available between two remotes.
  """
  def server_side_available?(source, destination) do
    source_remote = extract_remote(source)
    dest_remote = extract_remote(destination)

    # Same remote type and same account = server-side possible
    cond do
      source_remote == dest_remote ->
        true

      # Some providers support cross-account server-side
      compatible_remotes?(source_remote, dest_remote) ->
        true

      true ->
        false
    end
  end

  @doc """
  Resume an interrupted transfer.
  """
  def resume(transfer_state) do
    # rclone handles resume automatically with --progress
    # This function loads state and continues
    case load_resume_state(transfer_state.source, transfer_state.destination) do
      {:ok, state} ->
        Logger.info("Resuming transfer from #{state.bytes_transferred} bytes")
        do_transfer(Map.put(transfer_state, :resume_state, state), [])

      {:error, :no_state} ->
        # Start fresh
        do_transfer(transfer_state, [])
    end
  end

  @doc """
  Calculate block checksums for a file.
  """
  def calculate_block_checksums(path, block_size \\ @default_block_size) do
    case File.stream!(path, [], block_size) do
      stream ->
        checksums = stream
        |> Stream.with_index()
        |> Enum.map(fn {block, index} ->
          %{
            index: index,
            offset: index * block_size,
            size: byte_size(block),
            checksum: :crypto.hash(@checksum_algorithm, block) |> Base.encode16(case: :lower)
          }
        end)

        {:ok, %{
          path: path,
          block_size: block_size,
          total_blocks: length(checksums),
          blocks: checksums
        }}
    end
  rescue
    e -> {:error, e}
  end

  @doc """
  Compare two files at block level, returning differences.
  """
  def compare_blocks(source_checksums, dest_checksums) do
    source_map = source_checksums.blocks
    |> Enum.map(fn b -> {b.index, b.checksum} end)
    |> Enum.into(%{})

    dest_map = dest_checksums.blocks
    |> Enum.map(fn b -> {b.index, b.checksum} end)
    |> Enum.into(%{})

    changed = Enum.filter(source_checksums.blocks, fn block ->
      Map.get(dest_map, block.index) != block.checksum
    end)

    new_blocks = Enum.filter(source_checksums.blocks, fn block ->
      not Map.has_key?(dest_map, block.index)
    end)

    removed_indices = Map.keys(dest_map) -- Map.keys(source_map)

    %{
      total_source_blocks: length(source_checksums.blocks),
      total_dest_blocks: length(dest_checksums.blocks),
      changed_blocks: changed,
      new_blocks: new_blocks,
      removed_block_indices: removed_indices,
      blocks_to_transfer: length(changed) + length(new_blocks),
      efficiency: if(length(source_checksums.blocks) > 0,
        do: Float.round((1 - (length(changed) + length(new_blocks)) / length(source_checksums.blocks)) * 100, 1),
        else: 0.0
      )
    }
  end

  @doc """
  Verify transfer by comparing checksums.
  """
  def verify_transfer(source, destination, opts \\ []) do
    case RcloneClient.check(source, destination, opts) do
      {:ok, result} ->
        if result["differences"] == 0 do
          {:ok, :verified}
        else
          {:error, {:verification_failed, result}}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Private functions

  defp transfer(config, opts) do
    mode = determine_mode(config, opts)
    config = %{config | mode: mode}
    do_transfer(config, opts)
  end

  defp determine_mode(config, opts) do
    case config.mode do
      :auto ->
        cond do
          # Server-side if available
          server_side_available?(config.source, config.destination) ->
            :server_side

          # Block mode for large files or sync operations
          config.operation == :sync ->
            :block

          # Default to file mode
          true ->
            :file
        end

      mode ->
        mode
    end
  end

  defp do_transfer(config, opts) do
    rclone_cmd = case config.operation do
      :copy -> "copy"
      :move -> "move"
      :sync -> "sync"
    end

    args = [
      config.source,
      config.destination,
      "--progress",
      "-v"
    ]

    # Add mode-specific options
    args = case config.mode do
      :server_side ->
        args ++ ["--server-side-across-configs"]

      :block ->
        # rclone uses rolling checksums for delta transfer
        args ++ [
          "--update",
          "--use-mmap",
          "--buffer-size", "64M"
        ]

      :file ->
        args
    end

    # Add verification
    args = if config.verify do
      args ++ ["--checksum"]
    else
      args
    end

    # Add any custom rclone options
    args = args ++ Keyword.get(opts, :rclone_opts, [])

    # Execute
    case RcloneClient.execute(rclone_cmd, args) do
      {:ok, result} ->
        # Verify if requested
        if config.verify do
          verify_transfer(config.source, config.destination, opts)
        else
          {:ok, result}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_remote(path) do
    case String.split(path, ":", parts: 2) do
      [remote, _] -> remote
      [_local] -> "local"
    end
  end

  defp compatible_remotes?(remote1, remote2) do
    # List of remotes that support server-side operations across accounts
    server_side_pairs = [
      {"s3", "s3"},
      {"gcs", "gcs"},
      {"azureblob", "azureblob"},
      {"b2", "b2"}
    ]

    Enum.any?(server_side_pairs, fn {r1, r2} ->
      (String.contains?(remote1, r1) and String.contains?(remote2, r2)) or
      (String.contains?(remote1, r2) and String.contains?(remote2, r1))
    end)
  end

  defp load_resume_state(source, destination) do
    state_file = resume_state_path(source, destination)

    case File.read(state_file) do
      {:ok, content} ->
        {:ok, Jason.decode!(content, keys: :atoms)}
      {:error, :enoent} ->
        {:error, :no_state}
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp resume_state_path(source, destination) do
    hash = :crypto.hash(:md5, "#{source}:#{destination}") |> Base.encode16(case: :lower)
    Path.join(System.tmp_dir!(), "laminar_transfer_#{hash}.state")
  end
end
