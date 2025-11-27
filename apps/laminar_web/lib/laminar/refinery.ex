# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.Refinery do
  @moduledoc """
  The Refinery - converts files to optimal formats during transit.

  Files are downloaded to the RAM buffer (Tier 1), converted using
  the appropriate tool (ffmpeg, imagemagick), and then uploaded.

  ## Conversion Lanes

    * Audio: WAV/AIFF → FLAC (lossless, ~50% size reduction)
    * Image: BMP/TIFF → WebP (lossless, ~30-80% size reduction)
    * Text: SQL/CSV/JSON → Zstd compressed

  ## Safety

  All operations occur in volatile RAM. If power cuts, data vanishes.
  Source files are never modified - only the destination receives
  the converted version.
  """

  require Logger

  @ram_buffer_path Application.compile_env(:laminar_web, [:pipeline, :tier1_path], "/mnt/laminar_tier1")

  @type format :: :flac | :webp | :zstd | :raw
  @type process_result :: {:ok, String.t()} | {:error, term()}

  @doc """
  Process a file according to the Intelligence engine's decision.

  ## Parameters

    * `file` - File metadata map
    * `action` - Action tuple from Intelligence.consult_oracle/2
    * `source_remote` - Source remote path
    * `dest_remote` - Destination remote path

  ## Returns

    * `{:ok, dest_path}` - Successfully processed and uploaded
    * `{:error, reason}` - Processing failed
  """
  @spec process(map(), tuple(), String.t(), String.t()) :: process_result()
  def process(file, {:convert, format, _priority}, source_remote, dest_remote) do
    file_path = file["Path"] || file[:path]
    file_name = file["Name"] || file[:name] || Path.basename(file_path)

    with {:ok, source_path} <- download_to_buffer(source_remote, file_path),
         {:ok, dest_path} <- convert(source_path, file_name, format),
         :ok <- cleanup_source(source_path),
         {:ok, _} <- upload_from_buffer(dest_path, dest_remote, file_path, format) do
      cleanup_dest(dest_path)
      {:ok, dest_path}
    end
  end

  def process(file, {:compress, algo, _priority}, source_remote, dest_remote) do
    file_path = file["Path"] || file[:path]
    file_name = file["Name"] || file[:name] || Path.basename(file_path)

    with {:ok, source_path} <- download_to_buffer(source_remote, file_path),
         {:ok, dest_path} <- compress(source_path, file_name, algo),
         :ok <- cleanup_source(source_path),
         {:ok, _} <- upload_from_buffer(dest_path, dest_remote, file_path <> compressed_ext(algo), :raw) do
      cleanup_dest(dest_path)
      {:ok, dest_path}
    end
  end

  def process(_file, {:transfer, :raw, _}, _source_remote, _dest_remote) do
    # Raw transfers are handled by the main Rclone stream, not the refinery
    {:ok, :passthrough}
  end

  # -- Conversion Functions --

  @doc false
  def convert(source_path, file_name, :flac) do
    dest_filename = Path.rootname(file_name) <> ".flac"
    dest_path = Path.join(@ram_buffer_path, dest_filename)

    case System.cmd("ffmpeg", [
           "-i", source_path,
           "-c:a", "flac",
           "-compression_level", "8",
           dest_path
         ], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("Converted #{file_name} to FLAC")
        {:ok, dest_path}

      {output, code} ->
        Logger.error("FFmpeg failed (code #{code}): #{output}")
        {:error, {:ffmpeg_failed, code}}
    end
  end

  def convert(source_path, file_name, :webp) do
    dest_filename = Path.rootname(file_name) <> ".webp"
    dest_path = Path.join(@ram_buffer_path, dest_filename)

    case System.cmd("convert", [
           source_path,
           "-define", "webp:lossless=true",
           dest_path
         ], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("Converted #{file_name} to WebP")
        {:ok, dest_path}

      {output, code} ->
        Logger.error("ImageMagick failed (code #{code}): #{output}")
        {:error, {:convert_failed, code}}
    end
  end

  # -- Compression Functions --

  @doc false
  def compress(source_path, file_name, :zstd) do
    dest_path = Path.join(@ram_buffer_path, file_name <> ".zst")

    case System.cmd("zstd", [
           "-19",
           "-o", dest_path,
           source_path
         ], stderr_to_stdout: true) do
      {_, 0} ->
        Logger.info("Compressed #{file_name} with Zstd")
        {:ok, dest_path}

      {output, code} ->
        Logger.error("Zstd failed (code #{code}): #{output}")
        {:error, {:zstd_failed, code}}
    end
  end

  def compress(source_path, file_name, :gzip) do
    dest_path = Path.join(@ram_buffer_path, file_name <> ".gz")

    case System.cmd("gzip", [
           "-9",
           "-c",
           source_path
         ], stderr_to_stdout: true) do
      {output, 0} ->
        File.write!(dest_path, output)
        Logger.info("Compressed #{file_name} with Gzip")
        {:ok, dest_path}

      {output, code} ->
        Logger.error("Gzip failed (code #{code}): #{output}")
        {:error, {:gzip_failed, code}}
    end
  end

  # -- Buffer Management --

  defp download_to_buffer(remote, file_path) do
    local_path = Path.join(@ram_buffer_path, Path.basename(file_path))

    # Use rclone copyto to download to buffer
    case System.cmd("rclone", [
           "copyto",
           "#{remote}#{file_path}",
           local_path,
           "--progress"
         ], stderr_to_stdout: true) do
      {_, 0} -> {:ok, local_path}
      {output, code} -> {:error, {:download_failed, code, output}}
    end
  end

  defp upload_from_buffer(local_path, remote, dest_path, format) do
    # Adjust destination path for format change
    final_dest =
      case format do
        :flac -> Path.rootname(dest_path) <> ".flac"
        :webp -> Path.rootname(dest_path) <> ".webp"
        :raw -> dest_path
      end

    case System.cmd("rclone", [
           "copyto",
           local_path,
           "#{remote}#{final_dest}",
           "--progress"
         ], stderr_to_stdout: true) do
      {_, 0} -> {:ok, final_dest}
      {output, code} -> {:error, {:upload_failed, code, output}}
    end
  end

  defp cleanup_source(path) do
    File.rm(path)
    :ok
  end

  defp cleanup_dest(path) do
    File.rm(path)
    :ok
  end

  defp compressed_ext(:zstd), do: ".zst"
  defp compressed_ext(:gzip), do: ".gz"
  defp compressed_ext(_), do: ""
end
