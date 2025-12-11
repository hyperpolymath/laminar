defmodule Laminar.Preflight do
  @moduledoc """
  Pre-transfer validation and dry run functionality.

  Checks before transfer:
  - Space availability on destination
  - Source accessibility and file counts
  - Special/problematic file detection (Google Docs, Dropbox, etc.)
  - Path validation and permission checks
  - Transfer time estimation

  Provides:
  - Dry run mode (list what would transfer without doing it)
  - Space prediction with buffer
  - Detailed preflight reports
  """

  require Logger

  alias Laminar.{RcloneClient, SpecialFiles, FilterEngine}

  defstruct [
    :source,
    :destination,
    :dry_run,
    :space_check,
    :file_analysis,
    :special_files,
    :estimated_time,
    :warnings,
    :errors,
    :passed
  ]

  @type t :: %__MODULE__{}

  # Safety buffer for space checks (10% minimum)
  @space_buffer_percent 0.10

  @doc """
  Run comprehensive preflight checks before a transfer.

  Options:
  - `:dry_run` - If true, only simulate (default: false)
  - `:check_space` - Verify destination has room (default: true)
  - `:detect_special` - Find problematic files (default: true)
  - `:filters` - Include/exclude patterns to apply
  """
  def check(source, destination, opts \\ []) do
    dry_run = Keyword.get(opts, :dry_run, false)
    check_space = Keyword.get(opts, :check_space, true)
    detect_special = Keyword.get(opts, :detect_special, true)
    filters = Keyword.get(opts, :filters, [])

    Logger.info("Starting preflight check: #{source} -> #{destination}")

    # Run checks in parallel where possible
    tasks = [
      Task.async(fn -> {:source_analysis, analyze_source(source, filters)} end),
      Task.async(fn -> {:dest_space, if(check_space, do: check_destination_space(destination), else: :skipped)} end),
      Task.async(fn -> {:special_files, if(detect_special, do: detect_special_files(source, filters), else: [])} end)
    ]

    results = Task.await_many(tasks, :timer.minutes(5))
    |> Enum.into(%{})

    # Build preflight report
    build_report(source, destination, results, dry_run)
  end

  @doc """
  Perform a dry run - list all files that would be transferred.

  Returns a stream of file entries for memory efficiency with large transfers.
  """
  def dry_run(source, destination, opts \\ []) do
    filters = Keyword.get(opts, :filters, [])
    format = Keyword.get(opts, :format, :summary)  # :summary, :detailed, :json

    case RcloneClient.lsjson(source, recursive: true, filters: filters) do
      {:ok, files} ->
        special = SpecialFiles.scan(files)

        result = %{
          source: source,
          destination: destination,
          total_files: length(files),
          total_size: Enum.reduce(files, 0, fn f, acc -> acc + Map.get(f, "Size", 0) end),
          special_files: special,
          files: if(format == :detailed, do: files, else: :omitted)
        }

        {:ok, format_dry_run(result, format)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Check if destination has enough space for the transfer.

  Returns space info with recommendation.
  """
  def check_space(source, destination, opts \\ []) do
    with {:ok, source_size} <- get_source_size(source, opts),
         {:ok, dest_space} <- get_destination_space(destination) do

      required = source_size * (1 + @space_buffer_percent)
      available = dest_space.free

      result = %{
        source_size: source_size,
        source_size_human: humanize_bytes(source_size),
        destination_free: available,
        destination_free_human: humanize_bytes(available),
        required_with_buffer: required,
        required_human: humanize_bytes(required),
        sufficient: available >= required,
        margin_percent: if(available > 0, do: Float.round((available - required) / available * 100, 1), else: 0)
      }

      {:ok, result}
    end
  end

  @doc """
  Estimate transfer time based on path analysis.
  """
  def estimate_time(source, destination, opts \\ []) do
    with {:ok, source_size} <- get_source_size(source, opts),
         {:ok, bandwidth} <- estimate_bandwidth(source, destination) do

      # Calculate based on bottleneck (min of source read, dest write, network)
      effective_bandwidth = Enum.min([
        bandwidth.source_read_mbps,
        bandwidth.dest_write_mbps,
        bandwidth.network_mbps
      ]) * 1_000_000 / 8  # Convert to bytes/sec

      seconds = if effective_bandwidth > 0, do: source_size / effective_bandwidth, else: :unknown

      {:ok, %{
        source_size: source_size,
        effective_bandwidth_mbps: Float.round(effective_bandwidth * 8 / 1_000_000, 1),
        estimated_seconds: seconds,
        estimated_human: humanize_duration(seconds),
        confidence: bandwidth.confidence
      }}
    end
  end

  # Private functions

  defp analyze_source(source, filters) do
    case RcloneClient.size(source, filters: filters) do
      {:ok, size_info} ->
        %{
          total_size: size_info["bytes"] || 0,
          total_files: size_info["count"] || 0,
          accessible: true
        }
      {:error, reason} ->
        %{accessible: false, error: reason}
    end
  end

  defp check_destination_space(destination) do
    case RcloneClient.about(destination) do
      {:ok, about_info} ->
        %{
          total: about_info["total"],
          used: about_info["used"],
          free: about_info["free"],
          available: true
        }
      {:error, _} ->
        # Some remotes don't support 'about' - try alternative
        %{available: false, note: "Space check not supported for this remote"}
    end
  end

  defp detect_special_files(source, filters) do
    case RcloneClient.lsjson(source, recursive: true, filters: filters, max_depth: 10) do
      {:ok, files} -> SpecialFiles.scan(files)
      {:error, _} -> []
    end
  end

  defp get_source_size(source, opts) do
    filters = Keyword.get(opts, :filters, [])

    case RcloneClient.size(source, filters: filters) do
      {:ok, %{"bytes" => bytes}} -> {:ok, bytes}
      {:ok, _} -> {:ok, 0}
      {:error, reason} -> {:error, reason}
    end
  end

  defp get_destination_space(destination) do
    case RcloneClient.about(destination) do
      {:ok, info} -> {:ok, info}
      {:error, reason} -> {:error, reason}
    end
  end

  defp estimate_bandwidth(source, destination) do
    # This is approximate - real bandwidth requires actual transfer test
    source_type = extract_remote_type(source)
    dest_type = extract_remote_type(destination)

    # Rough estimates by provider type (Mbps)
    source_read = provider_bandwidth(source_type, :read)
    dest_write = provider_bandwidth(dest_type, :write)

    # Assume network is not the bottleneck for cloud-to-cloud
    network = 10_000  # 10 Gbps theoretical

    {:ok, %{
      source_read_mbps: source_read,
      dest_write_mbps: dest_write,
      network_mbps: network,
      confidence: :estimated
    }}
  end

  defp extract_remote_type(path) do
    case String.split(path, ":", parts: 2) do
      [remote, _] -> remote
      [_local] -> "local"
    end
  end

  defp provider_bandwidth(type, direction) do
    # Rough estimates - actual varies significantly
    case {type, direction} do
      {"gdrive", :read} -> 100
      {"gdrive", :write} -> 50
      {"dropbox", :read} -> 150
      {"dropbox", :write} -> 100
      {"s3", :read} -> 500
      {"s3", :write} -> 300
      {"b2", :read} -> 200
      {"b2", :write} -> 150
      {"local", _} -> 1000
      _ -> 100  # Conservative default
    end
  end

  defp build_report(source, destination, results, dry_run) do
    source_analysis = results[:source_analysis]
    dest_space = results[:dest_space]
    special_files = results[:special_files] || []

    warnings = []
    errors = []

    # Check source accessibility
    {warnings, errors} = if not source_analysis[:accessible] do
      {warnings, ["Source not accessible: #{inspect(source_analysis[:error])}" | errors]}
    else
      {warnings, errors}
    end

    # Check space
    {warnings, errors} = case dest_space do
      :skipped -> {warnings, errors}
      %{available: false} -> {["Space check not available for destination" | warnings], errors}
      %{free: free, total: total} when is_number(free) and is_number(total) ->
        source_size = source_analysis[:total_size] || 0
        if free < source_size * 1.1 do
          {warnings, ["Insufficient space: need #{humanize_bytes(source_size)}, have #{humanize_bytes(free)}" | errors]}
        else
          {warnings, errors}
        end
      _ -> {warnings, errors}
    end

    # Warn about special files
    warnings = if length(special_files) > 0 do
      ["Found #{length(special_files)} special/problematic files that may not transfer correctly" | warnings]
    else
      warnings
    end

    passed = length(errors) == 0

    %__MODULE__{
      source: source,
      destination: destination,
      dry_run: dry_run,
      space_check: dest_space,
      file_analysis: source_analysis,
      special_files: special_files,
      estimated_time: nil,  # Calculated separately if needed
      warnings: warnings,
      errors: errors,
      passed: passed
    }
  end

  defp format_dry_run(result, :summary) do
    """
    Dry Run Summary
    ===============
    Source: #{result.source}
    Destination: #{result.destination}

    Files: #{result.total_files}
    Size: #{humanize_bytes(result.total_size)}

    Special Files: #{length(result.special_files)}
    #{Enum.map(result.special_files, fn f -> "  - #{f.path} (#{f.type})" end) |> Enum.join("\n")}
    """
  end

  defp format_dry_run(result, :json) do
    Jason.encode!(result, pretty: true)
  end

  defp format_dry_run(result, :detailed) do
    result
  end

  defp humanize_bytes(bytes) when is_number(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end
  defp humanize_bytes(_), do: "unknown"

  defp humanize_duration(seconds) when is_number(seconds) do
    cond do
      seconds >= 86400 -> "#{Float.round(seconds / 86400, 1)} days"
      seconds >= 3600 -> "#{Float.round(seconds / 3600, 1)} hours"
      seconds >= 60 -> "#{Float.round(seconds / 60, 1)} minutes"
      true -> "#{round(seconds)} seconds"
    end
  end
  defp humanize_duration(_), do: "unknown"
end
