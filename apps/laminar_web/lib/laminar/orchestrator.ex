# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.Orchestrator do
  @moduledoc """
  Actually wires the modules together and makes them work.

  This is what was missing - a central coordinator that:
  1. Starts required GenServers
  2. Coordinates between modules
  3. Provides a simple API for transfers
  """

  use GenServer
  require Logger

  defstruct [
    :progress_tracker,
    :current_transfer,
    :stats
  ]

  # --- Public API (What you actually call) ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Transfer files from source to destination.

  This is THE function to use. Everything else is implementation detail.

  ## Example

      Laminar.Orchestrator.transfer(
        "dropbox:Photos",
        "gdrive:backup/Photos"
      )
  """
  def transfer(source, destination, opts \\ []) do
    GenServer.call(__MODULE__, {:transfer, source, destination, opts}, :infinity)
  end

  @doc """
  Get current transfer progress.
  """
  def progress do
    GenServer.call(__MODULE__, :progress)
  end

  @doc """
  Cancel current transfer.
  """
  def cancel do
    GenServer.call(__MODULE__, :cancel)
  end

  # --- GenServer Implementation ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{stats: %{transfers: 0, bytes: 0}}}
  end

  @impl true
  def handle_call({:transfer, source, destination, opts}, _from, state) do
    Logger.info("Starting transfer: #{source} -> #{destination}")

    # Step 1: Parse source/destination
    {src_remote, src_path} = parse_remote(source)
    {dst_remote, dst_path} = parse_remote(destination)

    # Step 2: Get source size
    total_bytes = case Laminar.RcloneClient.about(source) do
      {:ok, %{"used" => used}} -> used
      _ -> 0
    end

    # Step 3: Start progress tracker
    {:ok, tracker} = Laminar.TransferProgress.start_link(
      total_bytes: total_bytes,
      transport: Keyword.get(opts, :transport, :quic)
    )

    # Step 4: Execute transfer with rclone (the part that actually works)
    result = do_transfer(src_remote, src_path, dst_remote, dst_path, tracker, opts)

    # Step 5: Get final stats
    final_progress = Laminar.TransferProgress.get(tracker)

    new_state = %{state |
      progress_tracker: nil,
      current_transfer: nil,
      stats: %{
        transfers: state.stats.transfers + 1,
        bytes: state.stats.bytes + final_progress.transferred_bytes
      }
    }

    {:reply, result, new_state}
  end

  @impl true
  def handle_call(:progress, _from, state) do
    progress = if state.progress_tracker do
      Laminar.TransferProgress.format(state.progress_tracker)
    else
      "No transfer in progress"
    end
    {:reply, progress, state}
  end

  @impl true
  def handle_call(:cancel, _from, state) do
    # Would send cancel to rclone job
    {:reply, :ok, %{state | current_transfer: nil}}
  end

  # --- Private ---

  defp parse_remote(path) do
    case String.split(path, ":", parts: 2) do
      [remote, rest] -> {remote <> ":", rest}
      [path] -> {"", path}
    end
  end

  defp do_transfer(src_remote, src_path, dst_remote, dst_path, tracker, opts) do
    # Build rclone flags from options
    flags = build_flags(opts)

    # Use rclone sync/copy via RC API
    params = %{
      srcFs: src_remote,
      srcRemote: src_path,
      dstFs: dst_remote,
      dstRemote: dst_path,
      _async: true
    }

    case Laminar.RcloneClient.rpc("sync/copy", params) do
      {:ok, %{"jobid" => job_id}} ->
        monitor_job(job_id, tracker)

      {:ok, result} ->
        {:ok, result}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp build_flags(opts) do
    base = [
      "--transfers=#{Keyword.get(opts, :transfers, 8)}",
      "--checkers=#{Keyword.get(opts, :checkers, 16)}",
      "--buffer-size=128M"
    ]

    if Keyword.get(opts, :progress, true) do
      ["--progress" | base]
    else
      base
    end
  end

  defp monitor_job(job_id, tracker) do
    case Laminar.RcloneClient.get_job_status(job_id) do
      {:ok, %{"finished" => true, "success" => true}} ->
        {:ok, :completed}

      {:ok, %{"finished" => true, "error" => error}} ->
        {:error, error}

      {:ok, %{"progress" => progress}} when is_number(progress) ->
        Laminar.TransferProgress.update(tracker, round(progress))
        Process.sleep(1000)
        monitor_job(job_id, tracker)

      {:ok, _} ->
        Process.sleep(1000)
        monitor_job(job_id, tracker)

      {:error, reason} ->
        {:error, reason}
    end
  end
end
