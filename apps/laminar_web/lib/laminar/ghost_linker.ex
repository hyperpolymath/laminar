# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.GhostLinker do
  @moduledoc """
  Handles the creation of symbolic cloud links ("Ghost Links").

  Instead of transferring massive files, we create a small .url stub file
  that points back to the original location. This saves bandwidth and time
  for large archival files that don't need to be duplicated.

  ## Format

  Uses the Windows/Linux compatible URL shortcut format:

      [InternetShortcut]
      URL=https://dropbox.com/s/xyz/project_archive.zip
      IconIndex=0
  """

  alias Laminar.RcloneClient

  require Logger

  @doc """
  Create a ghost link stub for a file.

  Instead of copying the file, creates a small .url file at the destination
  that points to the original file's public URL.

  ## Parameters

    * `source_remote` - The source remote (e.g., "dropbox:")
    * `file_path` - Path to the file within the remote
    * `dest_remote` - The destination remote (e.g., "gdrive:")
    * `opts` - Options (`:link_target` can override the default behavior)

  ## Returns

    * `{:ok, stub_path}` - Successfully created the stub
    * `{:error, reason}` - Failed to create the stub
  """
  @spec create_stub(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def create_stub(source_remote, file_path, dest_remote, opts \\ []) do
    link_target = Keyword.get(opts, :link_target)

    with {:ok, link} <- get_link(source_remote, file_path, link_target),
         stub_content <- generate_stub_content(link, file_path),
         stub_path <- generate_stub_path(file_path),
         :ok <- upload_stub(dest_remote, stub_path, stub_content) do
      Logger.info("Created ghost link: #{dest_remote}#{stub_path}")
      {:ok, stub_path}
    else
      {:error, reason} ->
        Logger.error("Failed to create ghost link for #{file_path}: #{inspect(reason)}")
        {:error, reason}
    end
  end

  @doc """
  Batch create ghost links for multiple files.

  Processes files in parallel using Task.async_stream.
  """
  @spec create_stubs([map()], String.t(), String.t(), keyword()) :: [
          {:ok, String.t()} | {:error, term()}
        ]
  def create_stubs(files, source_remote, dest_remote, opts \\ []) do
    files
    |> Task.async_stream(
      fn file ->
        path = file["Path"] || file[:path] || file["path"]
        create_stub(source_remote, path, dest_remote, opts)
      end,
      max_concurrency: Keyword.get(opts, :concurrency, 10),
      timeout: Keyword.get(opts, :timeout, 30_000)
    )
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end

  # -- Private Helpers --

  defp get_link(_source_remote, _file_path, link_target) when is_binary(link_target) do
    # Use provided link target (e.g., cold storage URL)
    {:ok, link_target}
  end

  defp get_link(source_remote, file_path, nil) do
    # Get public link from source
    RcloneClient.get_public_link(source_remote, file_path)
  end

  defp get_link(_source_remote, file_path, :source_location) do
    # Create a relative reference (not a full URL)
    {:ok, "rclone://source/#{file_path}"}
  end

  defp get_link(_source_remote, file_path, :cold_storage) do
    # Placeholder for cold storage URL generation
    {:ok, "rclone://cold-storage/#{file_path}"}
  end

  defp generate_stub_content(url, original_path) do
    filename = Path.basename(original_path)
    size_hint = "Original file location stub - use Laminar to restore"

    """
    [InternetShortcut]
    URL=#{url}
    IconIndex=0
    [Laminar]
    OriginalPath=#{original_path}
    OriginalName=#{filename}
    Note=#{size_hint}
    CreatedAt=#{DateTime.utc_now() |> DateTime.to_iso8601()}
    """
  end

  defp generate_stub_path(file_path) do
    # Add .url extension to the original filename
    "#{file_path}.url"
  end

  defp upload_stub(dest_remote, stub_path, content) do
    case RcloneClient.put_file(dest_remote, stub_path, content) do
      {:ok, _} -> :ok
      error -> error
    end
  end
end
