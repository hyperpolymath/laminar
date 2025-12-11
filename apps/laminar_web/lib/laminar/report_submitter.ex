# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.ReportSubmitter do
  @moduledoc """
  Submit transfer reports to feedback-a-tron for analysis and improvement.

  Reports include:
  - Transfer performance metrics (throughput, duration, file counts)
  - Errors and warnings encountered
  - Filesystem and network characteristics
  - Optimization recommendations applied
  - User feedback (optional)

  All reports are anonymized - no file names or personal data are included.
  Only aggregate statistics and performance metrics are submitted.
  """

  use GenServer
  require Logger

  @feedback_endpoint "http://localhost:4001/api/reports"  # feedback-a-tron endpoint
  @batch_size 10
  @batch_interval_ms 60_000

  defstruct [
    :pending_reports,
    :submitted_count,
    :enabled,
    :endpoint
  ]

  # Client API

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Submit a transfer report.

  The report will be anonymized and batched before submission.
  """
  def submit(report) do
    GenServer.cast(__MODULE__, {:submit, report})
  end

  @doc """
  Build a report from a completed transfer.
  """
  def build_report(transfer, opts \\ []) do
    %{
      type: :transfer_report,
      version: "1.0",
      timestamp: DateTime.utc_now() |> DateTime.to_iso8601(),

      # Transfer metadata (anonymized)
      transfer: %{
        operation: transfer.operation,
        source_type: anonymize_remote(transfer.source),
        dest_type: anonymize_remote(transfer.destination),
        status: transfer.status
      },

      # Performance metrics
      metrics: %{
        duration_seconds: calculate_duration(transfer),
        bytes_total: transfer.bytes_total,
        bytes_transferred: transfer.bytes_transferred,
        files_total: transfer.files_total,
        files_transferred: transfer.files_transferred,
        avg_rate_bps: calculate_avg_rate(transfer),
        peak_rate_bps: transfer.peak_rate_bps || 0
      },

      # Filesystem info
      filesystems: %{
        source: Keyword.get(opts, :source_fs, %{}),
        destination: Keyword.get(opts, :dest_fs, %{})
      },

      # Error summary (no file names)
      errors: %{
        count: length(transfer.errors || []),
        types: categorize_errors(transfer.errors || [])
      },

      # Applied optimizations
      optimizations: Keyword.get(opts, :optimizations, []),

      # System info
      system: %{
        os: get_os_info(),
        elixir_version: System.version(),
        otp_version: :erlang.system_info(:otp_release) |> List.to_string()
      },

      # Optional user feedback
      feedback: Keyword.get(opts, :feedback)
    }
  end

  @doc """
  Enable or disable report submission.
  """
  def set_enabled(enabled) do
    GenServer.call(__MODULE__, {:set_enabled, enabled})
  end

  @doc """
  Get submission statistics.
  """
  def get_stats do
    GenServer.call(__MODULE__, :get_stats)
  end

  # Server Implementation

  @impl true
  def init(opts) do
    state = %__MODULE__{
      pending_reports: [],
      submitted_count: 0,
      enabled: Keyword.get(opts, :enabled, true),
      endpoint: Keyword.get(opts, :endpoint, @feedback_endpoint)
    }

    # Schedule batch submission
    schedule_batch()

    {:ok, state}
  end

  @impl true
  def handle_cast({:submit, report}, state) do
    if state.enabled do
      # Add to pending batch
      pending = [anonymize_report(report) | state.pending_reports]

      # Check if we should submit now
      if length(pending) >= @batch_size do
        submit_batch(pending, state.endpoint)
        {:noreply, %{state | pending_reports: [], submitted_count: state.submitted_count + length(pending)}}
      else
        {:noreply, %{state | pending_reports: pending}}
      end
    else
      {:noreply, state}
    end
  end

  @impl true
  def handle_call({:set_enabled, enabled}, _from, state) do
    {:reply, :ok, %{state | enabled: enabled}}
  end

  @impl true
  def handle_call(:get_stats, _from, state) do
    stats = %{
      enabled: state.enabled,
      pending_count: length(state.pending_reports),
      submitted_count: state.submitted_count,
      endpoint: state.endpoint
    }
    {:reply, stats, state}
  end

  @impl true
  def handle_info(:batch_submit, state) do
    if length(state.pending_reports) > 0 do
      submit_batch(state.pending_reports, state.endpoint)
      schedule_batch()
      {:noreply, %{state | pending_reports: [], submitted_count: state.submitted_count + length(state.pending_reports)}}
    else
      schedule_batch()
      {:noreply, state}
    end
  end

  # Private functions

  defp schedule_batch do
    Process.send_after(self(), :batch_submit, @batch_interval_ms)
  end

  defp submit_batch(reports, endpoint) do
    payload = %{
      batch: reports,
      submitted_at: DateTime.utc_now() |> DateTime.to_iso8601(),
      client: "laminar",
      client_version: Application.spec(:laminar, :vsn) |> to_string()
    }

    Task.start(fn ->
      case http_post(endpoint, payload) do
        {:ok, _response} ->
          Logger.debug("Submitted #{length(reports)} reports to feedback-a-tron")

        {:error, reason} ->
          Logger.warning("Failed to submit reports to feedback-a-tron: #{inspect(reason)}")
      end
    end)
  end

  defp http_post(url, payload) do
    body = Jason.encode!(payload)

    case :httpc.request(:post, {String.to_charlist(url), [], 'application/json', body}, [], []) do
      {:ok, {{_, status, _}, _headers, _body}} when status in 200..299 ->
        {:ok, status}

      {:ok, {{_, status, _}, _headers, body}} ->
        {:error, {:http_error, status, body}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp anonymize_report(report) do
    # Ensure no identifying information leaks
    report
    |> Map.drop([:source, :destination, :current_file])
    |> Map.update(:errors, [], fn errors ->
      # Strip file paths from errors
      Enum.map(errors, fn error ->
        error
        |> Map.drop([:path, :file])
        |> Map.update(:message, "", &sanitize_message/1)
      end)
    end)
  end

  defp sanitize_message(message) when is_binary(message) do
    # Remove potential file paths and usernames
    message
    |> String.replace(~r/\/[^\s]+/, "[path]")
    |> String.replace(~r/[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}/, "[email]")
    |> String.replace(~r/[A-Za-z]:\\[^\s]+/, "[path]")
  end
  defp sanitize_message(message), do: inspect(message)

  defp anonymize_remote(path) when is_binary(path) do
    case String.split(path, ":", parts: 2) do
      [remote, _] -> %{type: remote_type(remote)}
      [_local] -> %{type: "local"}
    end
  end
  defp anonymize_remote(_), do: %{type: "unknown"}

  defp remote_type(remote) do
    # Normalize remote type
    cond do
      String.contains?(remote, "drive") or String.contains?(remote, "gdrive") -> "gdrive"
      String.contains?(remote, "s3") -> "s3"
      String.contains?(remote, "gcs") -> "gcs"
      String.contains?(remote, "azure") -> "azure"
      String.contains?(remote, "b2") -> "b2"
      String.contains?(remote, "dropbox") -> "dropbox"
      String.contains?(remote, "onedrive") -> "onedrive"
      String.contains?(remote, "sftp") -> "sftp"
      String.contains?(remote, "ftp") -> "ftp"
      true -> "other"
    end
  end

  defp calculate_duration(transfer) do
    case {transfer.started_at, transfer.completed_at} do
      {start, finish} when not is_nil(start) and not is_nil(finish) ->
        DateTime.diff(finish, start)
      _ ->
        0
    end
  end

  defp calculate_avg_rate(transfer) do
    duration = calculate_duration(transfer)
    if duration > 0 do
      (transfer.bytes_transferred * 8) / duration  # bits per second
    else
      0
    end
  end

  defp categorize_errors(errors) do
    errors
    |> Enum.map(fn error ->
      cond do
        is_map(error) and Map.has_key?(error, :type) -> error.type
        is_binary(error) and String.contains?(error, "permission") -> :permission
        is_binary(error) and String.contains?(error, "timeout") -> :timeout
        is_binary(error) and String.contains?(error, "space") -> :disk_space
        is_binary(error) and String.contains?(error, "network") -> :network
        true -> :other
      end
    end)
    |> Enum.frequencies()
  end

  defp get_os_info do
    case :os.type() do
      {:unix, :linux} ->
        case File.read("/etc/os-release") do
          {:ok, content} ->
            id = case Regex.run(~r/^ID=(.+)$/m, content) do
              [_, id] -> String.trim(id, "\"")
              _ -> "linux"
            end
            %{family: "linux", distribution: id}
          _ ->
            %{family: "linux"}
        end

      {:unix, :darwin} ->
        %{family: "macos"}

      {:win32, _} ->
        %{family: "windows"}

      _ ->
        %{family: "unknown"}
    end
  end
end
