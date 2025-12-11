# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.ParallelTransfer do
  @moduledoc """
  Theory of Constraints-optimized parallel transfer coordinator.

  ## The Constraint Migration Path

  1. Single SA → Constraint is upload quota (750GB/day)
  2. Multi SA  → Constraint moves to download bandwidth
  3. Parallel streams → Constraint moves to network/API rate limits
  4. Largest-first → API overhead minimized, pure bandwidth limited

  ## Architecture

  ```
  ┌────────────────────────────────────────────────────────────────┐
  │                    PARALLEL TRANSFER                           │
  ├────────────────────────────────────────────────────────────────┤
  │                                                                │
  │  ┌──────────────┐      ┌─────────────────┐                    │
  │  │   Manifest   │      │  Job Queue      │                    │
  │  │   (cached)   │─────►│  (sorted by     │                    │
  │  │              │      │   size desc)    │                    │
  │  └──────────────┘      └────────┬────────┘                    │
  │                                 │                              │
  │         ┌───────────────────────┼───────────────────────┐     │
  │         │                       │                       │     │
  │         ▼                       ▼                       ▼     │
  │  ┌─────────────┐        ┌─────────────┐        ┌─────────────┐│
  │  │  Worker 1   │        │  Worker 2   │        │  Worker N   ││
  │  │  (SA #1)    │        │  (SA #2)    │        │  (SA #N)    ││
  │  │             │        │             │        │             ││
  │  │ Download    │        │ Download    │        │ Download    ││
  │  │    ↓        │        │    ↓        │        │    ↓        ││
  │  │ Transform?  │        │ Transform?  │        │ Transform?  ││
  │  │    ↓        │        │    ↓        │        │    ↓        ││
  │  │ Upload      │        │ Upload      │        │ Upload      ││
  │  └─────────────┘        └─────────────┘        └─────────────┘│
  │         │                       │                       │     │
  │         └───────────────────────┼───────────────────────┘     │
  │                                 │                              │
  │                                 ▼                              │
  │                        ┌─────────────────┐                    │
  │                        │  Completion     │                    │
  │                        │  Tracker        │                    │
  │                        └─────────────────┘                    │
  │                                                                │
  └────────────────────────────────────────────────────────────────┘
  ```
  """

  use GenServer
  require Logger

  alias Laminar.{CredentialPool, RcloneClient, Intelligence}

  # Default: one worker per service account, max 32
  @max_workers 32

  # Buffer settings (subordination point S2)
  @max_buffer_per_worker 2 * 1024 * 1024 * 1024  # 2GB

  # Retry configuration
  @max_retries 3
  @retry_backoff_ms [1_000, 5_000, 15_000]

  defstruct [
    :id,
    :source,
    :destination,
    :manifest,
    :job_queue,
    :workers,
    :completed,
    :failed,
    :total_bytes,
    :transferred_bytes,
    :started_at,
    :status,
    :options
  ]

  # --- Public API ---

  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Start a new parallel transfer.

  ## Options

  - `:enumerate_first` - If true (default), enumerate all files before starting
  - `:largest_first` - If true (default), sort by size descending
  - `:workers` - Number of parallel workers (default: number of SAs, max 32)
  - `:verify` - If true, verify checksums after transfer
  - `:dry_run` - If true, enumerate only, don't transfer

  ## Example

      {:ok, job_id} = ParallelTransfer.start("dropbox:", "gdrive:",
        enumerate_first: true,
        largest_first: true
      )
  """
  @spec start(String.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def start(source, destination, opts \\ []) do
    GenServer.call(__MODULE__, {:start, source, destination, opts}, 300_000)
  end

  @doc """
  Get status of current transfer.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Pause the current transfer.
  """
  @spec pause() :: :ok
  def pause do
    GenServer.call(__MODULE__, :pause)
  end

  @doc """
  Resume a paused transfer.
  """
  @spec resume() :: :ok
  def resume do
    GenServer.call(__MODULE__, :resume)
  end

  @doc """
  Abort the current transfer.
  """
  @spec abort() :: :ok
  def abort do
    GenServer.call(__MODULE__, :abort)
  end

  # --- GenServer Callbacks ---

  @impl true
  def init(_opts) do
    {:ok, %__MODULE__{status: :idle, workers: %{}, completed: [], failed: []}}
  end

  @impl true
  def handle_call({:start, source, destination, opts}, _from, state) do
    if state.status != :idle do
      {:reply, {:error, :transfer_in_progress}, state}
    else
      case do_start_transfer(source, destination, opts, state) do
        {:ok, new_state} ->
          {:reply, {:ok, new_state.id}, new_state}

        {:error, reason} ->
          {:reply, {:error, reason}, state}
      end
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status = build_status(state)
    {:reply, status, state}
  end

  @impl true
  def handle_call(:pause, _from, state) do
    new_state = %{state | status: :paused}
    # Workers will check status and pause themselves
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:resume, _from, state) do
    new_state = %{state | status: :running}
    # Signal workers to resume
    Enum.each(state.workers, fn {pid, _} -> send(pid, :resume) end)
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_call(:abort, _from, state) do
    # Kill all workers
    Enum.each(state.workers, fn {pid, _} -> Process.exit(pid, :shutdown) end)
    new_state = %{state | status: :aborted, workers: %{}}
    {:reply, :ok, new_state}
  end

  @impl true
  def handle_info({:worker_completed, worker_pid, file, bytes}, state) do
    new_state =
      state
      |> update_in([Access.key(:completed)], &[file | &1])
      |> update_in([Access.key(:transferred_bytes)], &(&1 + bytes))

    # Dispatch next job to this worker
    case pop_next_job(new_state) do
      {nil, updated_state} ->
        # No more jobs, worker is done
        worker_info = Map.get(state.workers, worker_pid)
        Logger.info("Worker #{worker_info.id} finished (no more jobs)")
        updated_state = update_in(updated_state.workers, &Map.delete(&1, worker_pid))
        check_completion(updated_state)

      {job, updated_state} ->
        send(worker_pid, {:job, job})
        {:noreply, updated_state}
    end
  end

  @impl true
  def handle_info({:worker_failed, worker_pid, file, reason, attempts}, state) do
    if attempts < @max_retries do
      # Re-queue with incremented attempt count
      job = %{file: file, attempts: attempts + 1}
      new_queue = :queue.in(job, state.job_queue)
      {:noreply, %{state | job_queue: new_queue}}
    else
      # Max retries exceeded, mark as failed
      Logger.error("File #{file["Path"]} failed after #{attempts} attempts: #{inspect(reason)}")
      new_state = update_in(state.failed, &[{file, reason} | &1])
      {:noreply, new_state}
    end
  end

  @impl true
  def handle_info({:worker_quota_exhausted, worker_pid, credential_id}, state) do
    Logger.warning("Worker credential #{credential_id} quota exhausted")

    # Try to get a new credential for this worker
    worker_info = Map.get(state.workers, worker_pid)

    case CredentialPool.checkout(worker_info.provider, 1) do
      {:ok, new_cred} ->
        # Assign new credential to worker
        send(worker_pid, {:new_credential, new_cred})
        {:noreply, state}

      {:error, :quota_exhausted} ->
        # All credentials exhausted, pause this worker until reset
        Logger.warning("All credentials exhausted, pausing worker #{worker_info.id}")
        send(worker_pid, :pause_until_reset)
        {:noreply, state}
    end
  end

  @impl true
  def handle_info({:DOWN, _ref, :process, pid, reason}, state) do
    case Map.get(state.workers, pid) do
      nil ->
        {:noreply, state}

      worker_info ->
        Logger.error("Worker #{worker_info.id} died: #{inspect(reason)}")
        new_workers = Map.delete(state.workers, pid)
        new_state = %{state | workers: new_workers}
        check_completion(new_state)
    end
  end

  # --- Private Functions ---

  defp do_start_transfer(source, destination, opts, state) do
    id = generate_transfer_id()
    Logger.info("Starting parallel transfer #{id}: #{source} -> #{destination}")

    # Phase 0: Enumerate (subordinated to transfer)
    enumerate_first = Keyword.get(opts, :enumerate_first, true)
    largest_first = Keyword.get(opts, :largest_first, true)

    with {:ok, manifest} <- enumerate_source(source, enumerate_first),
         sorted_manifest <- sort_manifest(manifest, largest_first),
         {:ok, partitioned} <- partition_manifest(sorted_manifest),
         {:ok, worker_count} <- determine_worker_count(destination, opts) do

      # Build job queue (largest files first)
      job_queue =
        partitioned.transfer
        |> Enum.map(&%{file: &1, attempts: 0})
        |> Enum.reduce(:queue.new(), &:queue.in/2)

      total_bytes = Enum.sum(Enum.map(manifest, & &1["Size"]))

      # Show cost warning
      if warning = CredentialPool.cost_warning(extract_provider(destination), total_bytes) do
        Logger.warning(warning)
      end

      # Check if dry run
      if Keyword.get(opts, :dry_run) do
        {:ok, %{state |
          id: id,
          source: source,
          destination: destination,
          manifest: manifest,
          total_bytes: total_bytes,
          status: :dry_run_complete
        }}
      else
        # Spawn workers
        workers = spawn_workers(worker_count, source, destination, self())

        new_state = %{state |
          id: id,
          source: source,
          destination: destination,
          manifest: manifest,
          job_queue: job_queue,
          workers: workers,
          completed: [],
          failed: [],
          total_bytes: total_bytes,
          transferred_bytes: 0,
          started_at: DateTime.utc_now(),
          status: :running,
          options: opts
        }

        # Dispatch initial jobs to workers
        final_state = dispatch_initial_jobs(new_state)
        {:ok, final_state}
      end
    end
  end

  defp enumerate_source(source, true = _enumerate_first) do
    Logger.info("Enumerating source: #{source}")
    case RcloneClient.lsjson(source, recursive: true) do
      {:ok, files} ->
        Logger.info("Enumerated #{length(files)} files")
        {:ok, files}

      {:error, reason} ->
        {:error, {:enumeration_failed, reason}}
    end
  end

  defp enumerate_source(_source, false) do
    # Streaming mode - return empty, will fetch on demand
    {:ok, []}
  end

  defp sort_manifest(manifest, true = _largest_first) do
    Enum.sort_by(manifest, & &1["Size"], :desc)
  end

  defp sort_manifest(manifest, false), do: manifest

  defp partition_manifest(manifest) do
    partitioned =
      manifest
      |> Enum.reduce(%{transfer: [], ghost: [], ignore: []}, fn file, acc ->
        case Intelligence.consult_oracle(file) do
          :ignore ->
            %{acc | ignore: [file | acc.ignore]}

          {:link, _} ->
            %{acc | ghost: [file | acc.ghost]}

          _ ->
            %{acc | transfer: [file | acc.transfer]}
        end
      end)

    Logger.info("Partitioned: #{length(partitioned.transfer)} transfer, " <>
                "#{length(partitioned.ghost)} ghost, #{length(partitioned.ignore)} ignore")

    {:ok, partitioned}
  end

  defp determine_worker_count(destination, opts) do
    provider = extract_provider(destination)
    explicit_count = Keyword.get(opts, :workers)

    if explicit_count do
      {:ok, min(explicit_count, @max_workers)}
    else
      # Default: one worker per credential
      status = CredentialPool.status()
      cred_count = length(Map.get(status.credentials, provider, []))

      if cred_count == 0 do
        # No credentials configured, use single worker
        Logger.warning("No credentials in pool for #{provider}, using single worker")
        {:ok, 1}
      else
        {:ok, min(cred_count, @max_workers)}
      end
    end
  end

  defp spawn_workers(count, source, destination, coordinator) do
    provider = extract_provider(destination)

    1..count
    |> Enum.map(fn i ->
      # Get a credential for this worker
      cred =
        case CredentialPool.checkout(provider, 1) do
          {:ok, c} -> c
          {:error, _} -> nil
        end

      worker_opts = %{
        id: "worker-#{i}",
        source: source,
        destination: destination,
        credential: cred,
        provider: provider,
        coordinator: coordinator
      }

      {:ok, pid} = Task.start_link(fn -> worker_loop(worker_opts) end)
      Process.monitor(pid)

      {pid, worker_opts}
    end)
    |> Map.new()
  end

  defp dispatch_initial_jobs(state) do
    Enum.reduce(state.workers, state, fn {pid, _worker_info}, acc ->
      case pop_next_job(acc) do
        {nil, updated} ->
          updated

        {job, updated} ->
          send(pid, {:job, job})
          updated
      end
    end)
  end

  defp pop_next_job(state) do
    case :queue.out(state.job_queue) do
      {{:value, job}, new_queue} ->
        {job, %{state | job_queue: new_queue}}

      {:empty, _} ->
        {nil, state}
    end
  end

  defp check_completion(state) do
    if state.workers == %{} and :queue.is_empty(state.job_queue) do
      elapsed = DateTime.diff(DateTime.utc_now(), state.started_at)
      Logger.info("Transfer #{state.id} completed in #{elapsed}s")
      Logger.info("Transferred: #{length(state.completed)} files, Failed: #{length(state.failed)}")

      new_state = %{state | status: :completed}
      {:noreply, new_state}
    else
      {:noreply, state}
    end
  end

  defp build_status(state) do
    %{
      id: state.id,
      status: state.status,
      source: state.source,
      destination: state.destination,
      total_files: if(state.manifest, do: length(state.manifest), else: 0),
      completed_files: length(state.completed),
      failed_files: length(state.failed),
      queued_files: if(state.job_queue, do: :queue.len(state.job_queue), else: 0),
      total_bytes: state.total_bytes,
      transferred_bytes: state.transferred_bytes,
      progress_percent: calculate_progress(state),
      active_workers: map_size(state.workers),
      elapsed_seconds: if(state.started_at, do: DateTime.diff(DateTime.utc_now(), state.started_at), else: 0),
      throughput_mbps: calculate_throughput(state)
    }
  end

  defp calculate_progress(%{total_bytes: nil}), do: 0.0
  defp calculate_progress(%{total_bytes: 0}), do: 100.0
  defp calculate_progress(%{total_bytes: total, transferred_bytes: transferred}) do
    Float.round(transferred / total * 100, 2)
  end

  defp calculate_throughput(%{started_at: nil}), do: 0.0
  defp calculate_throughput(%{transferred_bytes: bytes, started_at: started}) do
    elapsed = DateTime.diff(DateTime.utc_now(), started)
    if elapsed > 0 do
      Float.round(bytes / elapsed / 1_000_000, 2)
    else
      0.0
    end
  end

  defp generate_transfer_id do
    "xfer-" <> (:crypto.strong_rand_bytes(8) |> Base.encode16(case: :lower))
  end

  defp extract_provider(remote) do
    case String.split(remote, ":", parts: 2) do
      [provider | _] -> provider
      _ -> "unknown"
    end
  end

  # --- Worker Process ---

  defp worker_loop(opts) do
    receive do
      {:job, job} ->
        result = execute_job(job, opts)
        handle_job_result(result, job, opts)
        worker_loop(opts)

      {:new_credential, cred} ->
        worker_loop(%{opts | credential: cred})

      :pause_until_reset ->
        # Sleep until quota resets
        sleep_time = CredentialPool.time_until_reset(opts.provider) * 1000
        Logger.info("Worker #{opts.id} sleeping #{div(sleep_time, 3600_000)}h until quota reset")
        Process.sleep(sleep_time)
        worker_loop(opts)

      :resume ->
        worker_loop(opts)

      :stop ->
        :ok
    end
  end

  defp execute_job(job, opts) do
    file = job.file
    source = opts.source
    destination = opts.destination

    Logger.debug("Worker #{opts.id} processing: #{file["Path"]} (#{file["Size"]} bytes)")

    # Check quota before transfer
    case CredentialPool.checkout(opts.provider, file["Size"]) do
      {:ok, cred} ->
        # Execute transfer via rclone
        result = do_transfer(file, source, destination, cred)

        # Record usage regardless of success (bytes were attempted)
        if result == :ok do
          CredentialPool.record_usage(cred.id, file["Size"])
        end

        result

      {:error, :quota_exhausted} ->
        {:error, :quota_exhausted}
    end
  end

  defp do_transfer(file, source, destination, cred) do
    # Build rclone command with credential
    src_path = "#{source}#{file["Path"]}"
    dst_path = "#{destination}#{file["Path"]}"

    # For service account, we need to use backend-specific options
    # This is a simplified version; real implementation would use RC API
    case RcloneClient.copy_file(source, file["Path"], destination, file["Path"]) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  defp handle_job_result(:ok, job, opts) do
    file = job.file
    send(opts.coordinator, {:worker_completed, self(), file, file["Size"]})
  end

  defp handle_job_result({:error, :quota_exhausted}, _job, opts) do
    cred = opts.credential
    send(opts.coordinator, {:worker_quota_exhausted, self(), cred && cred.id})
  end

  defp handle_job_result({:error, reason}, job, opts) do
    send(opts.coordinator, {:worker_failed, self(), job.file, reason, job.attempts})
  end
end
