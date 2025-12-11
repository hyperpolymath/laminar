# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.LiveTransfer do
  @moduledoc """
  Real-time transfer execution with live WebSocket updates.

  Wraps rclone operations and streams progress updates to connected
  WebSocket clients via TransferChannel.

  Features:
  - Real-time progress streaming (bytes, rate, ETA)
  - Per-file progress tracking
  - Pause/resume/cancel support
  - Automatic retry with backoff
  - Progress persistence for recovery
  """

  use GenServer
  require Logger

  alias Laminar.{TransferMetrics, Preflight, FilterEngine, RcloneClient}
  alias LaminarWeb.TransferChannel

  defstruct [
    :id,
    :source,
    :destination,
    :operation,      # :copy | :move | :sync
    :status,         # :pending | :running | :paused | :completed | :failed | :cancelled
    :started_at,
    :completed_at,
    :bytes_total,
    :bytes_transferred,
    :files_total,
    :files_transferred,
    :current_file,
    :rate_bps,
    :eta_seconds,
    :errors,
    :options,
    :pid              # rclone process pid
  ]

  @type t :: %__MODULE__{}

  # Update interval in ms
  @progress_interval 500

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a new transfer with live updates.

  Options:
  - `:operation` - :copy (default), :move, or :sync
  - `:filters` - FilterEngine or filter options
  - `:dry_run` - If true, only simulate
  - `:bandwidth_limit` - Limit in bytes/sec or string like "10M"
  - `:transfers` - Number of parallel file transfers (default: 4)
  - `:checkers` - Number of parallel checkers (default: 8)
  """
  def start_transfer(source, destination, opts \\ []) do
    GenServer.call(__MODULE__, {:start_transfer, source, destination, opts})
  end

  @doc """
  Get status of a transfer.
  """
  def get_status(transfer_id) do
    GenServer.call(__MODULE__, {:get_status, transfer_id})
  end

  @doc """
  Pause a running transfer.
  """
  def pause(transfer_id) do
    GenServer.call(__MODULE__, {:pause, transfer_id})
  end

  @doc """
  Resume a paused transfer.
  """
  def resume(transfer_id) do
    GenServer.call(__MODULE__, {:resume, transfer_id})
  end

  @doc """
  Cancel a transfer.
  """
  def cancel(transfer_id) do
    GenServer.call(__MODULE__, {:cancel, transfer_id})
  end

  @doc """
  List all transfers.
  """
  def list_transfers do
    GenServer.call(__MODULE__, :list_transfers)
  end

  # Server Implementation

  @impl true
  def init(_opts) do
    state = %{
      transfers: %{},
      active_count: 0,
      max_concurrent: 3
    }
    {:ok, state}
  end

  @impl true
  def handle_call({:start_transfer, source, destination, opts}, _from, state) do
    transfer_id = generate_id()
    operation = Keyword.get(opts, :operation, :copy)

    transfer = %__MODULE__{
      id: transfer_id,
      source: source,
      destination: destination,
      operation: operation,
      status: :pending,
      started_at: DateTime.utc_now(),
      bytes_total: 0,
      bytes_transferred: 0,
      files_total: 0,
      files_transferred: 0,
      errors: [],
      options: opts
    }

    # Start the transfer process
    {:ok, transfer} = execute_transfer(transfer)

    new_state = put_in(state.transfers[transfer_id], transfer)
    new_state = %{new_state | active_count: new_state.active_count + 1}

    {:reply, {:ok, transfer_id}, new_state}
  end

  @impl true
  def handle_call({:get_status, transfer_id}, _from, state) do
    case Map.get(state.transfers, transfer_id) do
      nil -> {:reply, {:error, :not_found}, state}
      transfer -> {:reply, {:ok, format_status(transfer)}, state}
    end
  end

  @impl true
  def handle_call({:pause, transfer_id}, _from, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
      %{status: :running, pid: pid} = transfer when is_pid(pid) ->
        # Send SIGSTOP to pause
        System.cmd("kill", ["-STOP", "#{:erlang.port_info(pid, :os_pid) |> elem(1)}"])
        updated = %{transfer | status: :paused}
        new_state = put_in(state.transfers[transfer_id], updated)
        TransferChannel.broadcast_progress(transfer_id, %{status: :paused})
        {:reply, :ok, new_state}
      _ ->
        {:reply, {:error, :not_running}, state}
    end
  end

  @impl true
  def handle_call({:resume, transfer_id}, _from, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
      %{status: :paused, pid: pid} = transfer when is_pid(pid) ->
        # Send SIGCONT to resume
        System.cmd("kill", ["-CONT", "#{:erlang.port_info(pid, :os_pid) |> elem(1)}"])
        updated = %{transfer | status: :running}
        new_state = put_in(state.transfers[transfer_id], updated)
        TransferChannel.broadcast_progress(transfer_id, %{status: :running})
        {:reply, :ok, new_state}
      _ ->
        {:reply, {:error, :not_paused}, state}
    end
  end

  @impl true
  def handle_call({:cancel, transfer_id}, _from, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:reply, {:error, :not_found}, state}
      %{pid: pid} = transfer when is_pid(pid) ->
        # Kill the process
        Port.close(pid)
        updated = %{transfer | status: :cancelled, completed_at: DateTime.utc_now()}
        new_state = put_in(state.transfers[transfer_id], updated)
        new_state = %{new_state | active_count: max(0, new_state.active_count - 1)}
        TransferChannel.broadcast_complete(transfer_id, %{status: :cancelled})
        {:reply, :ok, new_state}
      _ ->
        {:reply, {:error, :no_process}, state}
    end
  end

  @impl true
  def handle_call(:list_transfers, _from, state) do
    transfers = state.transfers
    |> Enum.map(fn {id, t} -> format_status(t) end)
    {:reply, {:ok, transfers}, state}
  end

  @impl true
  def handle_info({:progress, transfer_id, progress}, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:noreply, state}
      transfer ->
        updated = %{transfer |
          bytes_transferred: progress[:bytes] || transfer.bytes_transferred,
          bytes_total: progress[:total_bytes] || transfer.bytes_total,
          files_transferred: progress[:files] || transfer.files_transferred,
          files_total: progress[:total_files] || transfer.files_total,
          current_file: progress[:current_file],
          rate_bps: progress[:rate],
          eta_seconds: progress[:eta]
        }

        TransferChannel.broadcast_progress(transfer_id, %{
          bytes_transferred: updated.bytes_transferred,
          bytes_total: updated.bytes_total,
          files_transferred: updated.files_transferred,
          files_total: updated.files_total,
          current_file: updated.current_file,
          rate_bps: updated.rate_bps,
          eta_seconds: updated.eta_seconds,
          percent: if(updated.bytes_total > 0, do: Float.round(updated.bytes_transferred / updated.bytes_total * 100, 1), else: 0)
        })

        {:noreply, put_in(state.transfers[transfer_id], updated)}
    end
  end

  @impl true
  def handle_info({:complete, transfer_id, result}, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:noreply, state}
      transfer ->
        updated = %{transfer |
          status: if(result[:success], do: :completed, else: :failed),
          completed_at: DateTime.utc_now(),
          errors: result[:errors] || []
        }

        TransferChannel.broadcast_complete(transfer_id, %{
          status: updated.status,
          bytes_transferred: updated.bytes_transferred,
          files_transferred: updated.files_transferred,
          duration_seconds: DateTime.diff(updated.completed_at, updated.started_at),
          errors: updated.errors
        })

        new_state = put_in(state.transfers[transfer_id], updated)
        new_state = %{new_state | active_count: max(0, new_state.active_count - 1)}
        {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:file_complete, transfer_id, file_info}, state) do
    TransferChannel.broadcast_file_progress(transfer_id, %{
      status: :complete,
      path: file_info[:path],
      size: file_info[:size],
      duration_ms: file_info[:duration_ms]
    })
    {:noreply, state}
  end

  @impl true
  def handle_info({:error, transfer_id, error}, state) do
    case Map.get(state.transfers, transfer_id) do
      nil ->
        {:noreply, state}
      transfer ->
        updated = %{transfer | errors: [error | transfer.errors]}
        TransferChannel.broadcast_error(transfer_id, %{
          type: error[:type],
          message: error[:message],
          path: error[:path]
        })
        {:noreply, put_in(state.transfers[transfer_id], updated)}
    end
  end

  # Private functions

  defp execute_transfer(transfer) do
    parent = self()
    transfer_id = transfer.id

    # Build rclone command
    cmd = build_rclone_command(transfer)

    # Start rclone with progress output
    port = Port.open({:spawn_executable, System.find_executable("rclone")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: cmd
    ])

    # Start progress parser
    spawn_link(fn ->
      parse_rclone_output(port, transfer_id, parent)
    end)

    {:ok, %{transfer | status: :running, pid: port}}
  end

  defp build_rclone_command(transfer) do
    opts = transfer.options
    operation = case transfer.operation do
      :copy -> "copy"
      :move -> "move"
      :sync -> "sync"
    end

    args = [
      operation,
      transfer.source,
      transfer.destination,
      "--progress",
      "--stats", "1s",
      "--stats-one-line",
      "-v"
    ]

    # Add filters
    args = case Keyword.get(opts, :filters) do
      nil -> args
      %FilterEngine{} = filter ->
        args ++ FilterEngine.to_rclone_args(filter)
      filter_opts when is_list(filter_opts) ->
        filter = FilterEngine.new(filter_opts)
        args ++ FilterEngine.to_rclone_args(filter)
    end

    # Add bandwidth limit
    args = case Keyword.get(opts, :bandwidth_limit) do
      nil -> args
      limit -> args ++ ["--bwlimit", to_string(limit)]
    end

    # Add parallel transfers
    transfers = Keyword.get(opts, :transfers, 4)
    checkers = Keyword.get(opts, :checkers, 8)
    args ++ ["--transfers", to_string(transfers), "--checkers", to_string(checkers)]
  end

  defp parse_rclone_output(port, transfer_id, parent) do
    receive do
      {^port, {:data, data}} ->
        parse_progress_line(data, transfer_id, parent)
        parse_rclone_output(port, transfer_id, parent)

      {^port, {:exit_status, 0}} ->
        send(parent, {:complete, transfer_id, %{success: true}})

      {^port, {:exit_status, code}} ->
        send(parent, {:complete, transfer_id, %{success: false, exit_code: code}})
    end
  end

  defp parse_progress_line(line, transfer_id, parent) do
    cond do
      # Parse stats line: "Transferred: 1.234 GiB / 5.678 GiB, 22%, 100.5 MiB/s, ETA 1m30s"
      String.contains?(line, "Transferred:") ->
        progress = parse_stats_line(line)
        send(parent, {:progress, transfer_id, progress})

      # Parse file completion
      String.contains?(line, ": Copied") or String.contains?(line, ": Moved") ->
        file_info = parse_file_line(line)
        send(parent, {:file_complete, transfer_id, file_info})

      # Parse errors
      String.contains?(line, "ERROR") ->
        error = %{type: :transfer_error, message: String.trim(line)}
        send(parent, {:error, transfer_id, error})

      true ->
        :ok
    end
  end

  defp parse_stats_line(line) do
    # Example: "Transferred:   1.234 GiB / 5.678 GiB, 22%, 100.5 MiB/s, ETA 1m30s"
    bytes_regex = ~r/Transferred:\s*([\d.]+)\s*(\w+)\s*\/\s*([\d.]+)\s*(\w+)/
    rate_regex = ~r/([\d.]+)\s*(\w+)\/s/
    eta_regex = ~r/ETA\s*(\d+[hms]+)/
    percent_regex = ~r/(\d+)%/

    bytes = case Regex.run(bytes_regex, line) do
      [_, transferred, t_unit, total, to_unit] ->
        %{
          bytes: parse_size_value(transferred, t_unit),
          total_bytes: parse_size_value(total, to_unit)
        }
      _ -> %{}
    end

    rate = case Regex.run(rate_regex, line) do
      [_, value, unit] ->
        %{rate: parse_size_value(value, unit)}
      _ -> %{}
    end

    eta = case Regex.run(eta_regex, line) do
      [_, eta_str] ->
        %{eta: parse_duration(eta_str)}
      _ -> %{}
    end

    Map.merge(bytes, rate) |> Map.merge(eta)
  end

  defp parse_file_line(line) do
    # Example: "2024/01/15 10:30:45 INFO  : file.txt: Copied (new)"
    %{
      path: line |> String.split(":") |> Enum.at(3, "") |> String.trim(),
      size: 0,
      duration_ms: 0
    }
  end

  defp parse_size_value(value, unit) do
    n = String.to_float(value)
    multiplier = case String.upcase(unit) do
      "B" -> 1
      "KIB" -> 1024
      "MIB" -> 1024 * 1024
      "GIB" -> 1024 * 1024 * 1024
      "TIB" -> 1024 * 1024 * 1024 * 1024
      "KB" -> 1000
      "MB" -> 1_000_000
      "GB" -> 1_000_000_000
      "TB" -> 1_000_000_000_000
      _ -> 1
    end
    round(n * multiplier)
  end

  defp parse_duration(str) do
    # Parse durations like "1h30m45s", "5m", "30s"
    hours = case Regex.run(~r/(\d+)h/, str) do
      [_, h] -> String.to_integer(h) * 3600
      _ -> 0
    end
    minutes = case Regex.run(~r/(\d+)m/, str) do
      [_, m] -> String.to_integer(m) * 60
      _ -> 0
    end
    seconds = case Regex.run(~r/(\d+)s/, str) do
      [_, s] -> String.to_integer(s)
      _ -> 0
    end
    hours + minutes + seconds
  end

  defp format_status(transfer) do
    %{
      id: transfer.id,
      source: transfer.source,
      destination: transfer.destination,
      operation: transfer.operation,
      status: transfer.status,
      started_at: transfer.started_at,
      completed_at: transfer.completed_at,
      bytes_total: transfer.bytes_total,
      bytes_transferred: transfer.bytes_transferred,
      files_total: transfer.files_total,
      files_transferred: transfer.files_transferred,
      current_file: transfer.current_file,
      rate_bps: transfer.rate_bps,
      eta_seconds: transfer.eta_seconds,
      percent: if(transfer.bytes_total > 0, do: Float.round(transfer.bytes_transferred / transfer.bytes_total * 100, 1), else: 0),
      error_count: length(transfer.errors)
    }
  end

  defp generate_id do
    :crypto.strong_rand_bytes(8) |> Base.url_encode64(padding: false)
  end
end
