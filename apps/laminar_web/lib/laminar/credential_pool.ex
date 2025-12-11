# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.CredentialPool do
  @moduledoc """
  Manages a pool of cloud provider credentials for parallel quota utilization.

  ## The Multi-Credential Strategy

  Cloud providers like Google Drive impose per-credential quotas (750GB/day).
  By using multiple legitimately-provisioned service accounts, you can achieve
  higher aggregate throughput for bulk migrations.

  This is **explicitly supported** by Google for enterprise migrations:
  - Each GCP project has independent quotas
  - Service account rotation is a documented pattern
  - Google sells quota increases (they want your throughput, just managed)

  ## Usage

      # Import credentials from a folder
      CredentialPool.import_folder("/path/to/service-accounts/")

      # Get next available credential with quota
      {:ok, cred} = CredentialPool.checkout(:gdrive, bytes_needed)

      # After transfer completes
      CredentialPool.record_usage(cred.id, bytes_transferred)

  ## Cost Warning

  Using multiple service accounts means:
  - Multiple GCP projects (free tier available)
  - API calls counted per project (usually free for Drive)
  - Storage quota is per-destination-account, NOT per-SA

  The service accounts write TO your Drive; they don't each have separate storage.
  """

  use GenServer
  require Logger

  # Google Drive: 750GB/day upload limit per service account
  @gdrive_daily_limit_bytes 750 * 1024 * 1024 * 1024

  # Dropbox: 2GB/file for free, but API calls are the real limit
  @dropbox_daily_limit_bytes :unlimited

  # Default limits per provider
  @provider_limits %{
    "gdrive" => @gdrive_daily_limit_bytes,
    "drive" => @gdrive_daily_limit_bytes,
    "s3" => :unlimited,
    "b2" => :unlimited,
    "dropbox" => @dropbox_daily_limit_bytes,
    "onedrive" => 100 * 1024 * 1024 * 1024  # ~100GB practical limit
  }

  # Safety margin: stop at 95% to avoid hitting hard limit
  @quota_safety_margin 0.95

  # --- Public API ---

  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @doc """
  Import all service account JSON files from a folder.

  ## Example

      {:ok, count} = CredentialPool.import_folder("/secrets/gdrive-service-accounts/")
      # => {:ok, 10}  # Imported 10 service accounts

  """
  @spec import_folder(String.t(), keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def import_folder(path, opts \\ []) do
    GenServer.call(__MODULE__, {:import_folder, path, opts}, 30_000)
  end

  @doc """
  Add a single credential to the pool.

  ## Options

  - `:provider` - Provider name (e.g., "gdrive", "s3")
  - `:name` - Human-readable name for this credential
  - `:daily_limit` - Override default daily limit in bytes

  """
  @spec add_credential(String.t(), map(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add_credential(provider, credential_data, opts \\ []) do
    GenServer.call(__MODULE__, {:add_credential, provider, credential_data, opts})
  end

  @doc """
  Check out a credential with sufficient remaining quota.

  Returns the best available credential for the requested transfer size.
  Prefers credentials with the most remaining quota (load balancing).

  ## Example

      {:ok, cred} = CredentialPool.checkout("gdrive", 10_000_000_000)
      # => {:ok, %{id: "sa-001", path: "/path/to/sa.json", remaining: 740_000_000_000}}

  """
  @spec checkout(String.t(), non_neg_integer()) :: {:ok, map()} | {:error, atom()}
  def checkout(provider, bytes_needed) do
    GenServer.call(__MODULE__, {:checkout, provider, bytes_needed})
  end

  @doc """
  Record bytes transferred using a credential.

  Call this after each successful transfer to update quota tracking.
  """
  @spec record_usage(String.t(), non_neg_integer()) :: :ok
  def record_usage(credential_id, bytes_transferred) do
    GenServer.cast(__MODULE__, {:record_usage, credential_id, bytes_transferred})
  end

  @doc """
  Get current status of all credentials in the pool.
  """
  @spec status() :: map()
  def status do
    GenServer.call(__MODULE__, :status)
  end

  @doc """
  Get aggregate remaining quota for a provider across all credentials.
  """
  @spec total_remaining(String.t()) :: non_neg_integer() | :unlimited
  def total_remaining(provider) do
    GenServer.call(__MODULE__, {:total_remaining, provider})
  end

  @doc """
  Estimate how long until quota resets (next midnight Pacific for Google).
  """
  @spec time_until_reset(String.t()) :: non_neg_integer()
  def time_until_reset(provider) do
    GenServer.call(__MODULE__, {:time_until_reset, provider})
  end

  @doc """
  Check if there's sufficient aggregate quota for a transfer.

  Useful for pre-flight checks before starting a large migration.
  """
  @spec can_transfer?(String.t(), non_neg_integer()) :: boolean()
  def can_transfer?(provider, total_bytes) do
    case total_remaining(provider) do
      :unlimited -> true
      remaining -> remaining >= total_bytes
    end
  end

  @doc """
  Generate a warning message about costs and quotas.

  Returns nil if no warning needed, or a string to display to user.
  """
  @spec cost_warning(String.t(), non_neg_integer()) :: String.t() | nil
  def cost_warning(provider, total_bytes) do
    status = status()
    creds = Map.get(status.credentials, provider, [])
    cred_count = length(creds)
    total_quota = total_remaining(provider)

    cond do
      total_quota == :unlimited ->
        nil

      cred_count == 0 ->
        """
        ⚠️  NO CREDENTIALS CONFIGURED for #{provider}

        Add service accounts to enable transfers:
          laminar credentials import /path/to/service-accounts/
        """

      total_bytes > total_quota ->
        days_needed = ceil(total_bytes / @gdrive_daily_limit_bytes / cred_count)
        """
        ⚠️  QUOTA WARNING: Transfer exceeds daily limits

        Transfer size:     #{format_bytes(total_bytes)}
        Available today:   #{format_bytes(total_quota)}
        Credentials:       #{cred_count} service account(s)
        Quota per SA:      #{format_bytes(@gdrive_daily_limit_bytes)}/day

        Estimated time:    #{days_needed} day(s) with automatic pause/resume

        Options:
        1. Add more service accounts (each adds 750GB/day)
        2. Proceed and let Laminar auto-pause at quota limits
        3. Request quota increase from Google Cloud Console
        """

      cred_count > 1 ->
        """
        ℹ️  MULTI-CREDENTIAL MODE: #{cred_count} service accounts configured

        Aggregate quota:   #{format_bytes(total_quota)}/day
        Transfer size:     #{format_bytes(total_bytes)}

        Credentials will be rotated automatically for optimal throughput.
        API costs are per-GCP-project (usually free tier for Drive API).
        """

      true ->
        nil
    end
  end

  # --- GenServer Implementation ---

  @impl true
  def init(opts) do
    state = %{
      credentials: %{},      # provider => [%{id, path, name, daily_limit, used_today, last_reset}]
      rotation_index: %{},   # provider => current_index
      reset_schedule: %{}    # provider => DateTime of next reset
    }

    # Auto-import from configured path if present
    if path = Keyword.get(opts, :credentials_path) do
      send(self(), {:auto_import, path})
    end

    # Schedule daily reset check
    schedule_reset_check()

    {:ok, state}
  end

  @impl true
  def handle_call({:import_folder, path, opts}, _from, state) do
    case do_import_folder(path, opts, state) do
      {:ok, new_state, count} ->
        Logger.info("Imported #{count} credentials from #{path}")
        {:reply, {:ok, count}, new_state}

      {:error, reason} = error ->
        Logger.error("Failed to import credentials from #{path}: #{inspect(reason)}")
        {:reply, error, state}
    end
  end

  @impl true
  def handle_call({:add_credential, provider, credential_data, opts}, _from, state) do
    id = generate_credential_id(provider)
    name = Keyword.get(opts, :name, id)
    daily_limit = Keyword.get(opts, :daily_limit, Map.get(@provider_limits, provider, :unlimited))

    cred = %{
      id: id,
      provider: provider,
      name: name,
      data: credential_data,
      path: Keyword.get(opts, :path),
      daily_limit: daily_limit,
      used_today: 0,
      last_reset: DateTime.utc_now(),
      created_at: DateTime.utc_now()
    }

    new_creds = Map.update(state.credentials, provider, [cred], &[cred | &1])
    new_state = %{state | credentials: new_creds}

    Logger.info("Added credential #{id} for #{provider} (limit: #{format_limit(daily_limit)})")
    {:reply, {:ok, id}, new_state}
  end

  @impl true
  def handle_call({:checkout, provider, bytes_needed}, _from, state) do
    creds = Map.get(state.credentials, provider, [])

    # Find credentials with sufficient remaining quota, sorted by most available
    available =
      creds
      |> Enum.map(fn cred ->
        remaining = calculate_remaining(cred)
        {cred, remaining}
      end)
      |> Enum.filter(fn {_cred, remaining} ->
        remaining == :unlimited || remaining >= bytes_needed
      end)
      |> Enum.sort_by(fn {_cred, remaining} ->
        case remaining do
          :unlimited -> :infinity
          n -> -n  # Sort descending (most remaining first)
        end
      end)

    case available do
      [{cred, remaining} | _] ->
        result = %{
          id: cred.id,
          path: cred.path,
          data: cred.data,
          name: cred.name,
          remaining: remaining,
          provider: provider
        }
        {:reply, {:ok, result}, state}

      [] when creds == [] ->
        {:reply, {:error, :no_credentials}, state}

      [] ->
        {:reply, {:error, :quota_exhausted}, state}
    end
  end

  @impl true
  def handle_call(:status, _from, state) do
    status =
      state.credentials
      |> Enum.map(fn {provider, creds} ->
        cred_status =
          Enum.map(creds, fn cred ->
            remaining = calculate_remaining(cred)
            %{
              id: cred.id,
              name: cred.name,
              daily_limit: cred.daily_limit,
              used_today: cred.used_today,
              remaining: remaining,
              utilization: calculate_utilization(cred)
            }
          end)

        {provider, cred_status}
      end)
      |> Map.new()

    {:reply, %{credentials: status, reset_schedule: state.reset_schedule}, state}
  end

  @impl true
  def handle_call({:total_remaining, provider}, _from, state) do
    creds = Map.get(state.credentials, provider, [])

    total =
      Enum.reduce(creds, 0, fn cred, acc ->
        case calculate_remaining(cred) do
          :unlimited -> :unlimited
          n when acc == :unlimited -> :unlimited
          n -> acc + n
        end
      end)

    {:reply, total, state}
  end

  @impl true
  def handle_call({:time_until_reset, provider}, _from, state) do
    # Google resets at midnight Pacific Time
    next_reset = calculate_next_reset(provider)
    seconds = DateTime.diff(next_reset, DateTime.utc_now())
    {:reply, max(0, seconds), state}
  end

  @impl true
  def handle_cast({:record_usage, credential_id, bytes_transferred}, state) do
    new_creds =
      state.credentials
      |> Enum.map(fn {provider, creds} ->
        updated =
          Enum.map(creds, fn cred ->
            if cred.id == credential_id do
              %{cred | used_today: cred.used_today + bytes_transferred}
            else
              cred
            end
          end)

        {provider, updated}
      end)
      |> Map.new()

    {:noreply, %{state | credentials: new_creds}}
  end

  @impl true
  def handle_info({:auto_import, path}, state) do
    case do_import_folder(path, [], state) do
      {:ok, new_state, count} ->
        Logger.info("Auto-imported #{count} credentials from #{path}")
        {:noreply, new_state}

      {:error, reason} ->
        Logger.warning("Auto-import failed: #{inspect(reason)}")
        {:noreply, state}
    end
  end

  @impl true
  def handle_info(:reset_check, state) do
    # Check if any provider needs quota reset
    now = DateTime.utc_now()

    new_creds =
      state.credentials
      |> Enum.map(fn {provider, creds} ->
        reset_time = calculate_next_reset(provider)

        updated =
          if DateTime.compare(now, reset_time) == :gt do
            Enum.map(creds, fn cred ->
              %{cred | used_today: 0, last_reset: now}
            end)
          else
            creds
          end

        {provider, updated}
      end)
      |> Map.new()

    schedule_reset_check()
    {:noreply, %{state | credentials: new_creds}}
  end

  # --- Private Helpers ---

  defp do_import_folder(path, _opts, state) do
    with true <- File.dir?(path),
         {:ok, files} <- File.ls(path) do
      json_files =
        files
        |> Enum.filter(&String.ends_with?(&1, ".json"))
        |> Enum.map(&Path.join(path, &1))

      {new_state, count} =
        Enum.reduce(json_files, {state, 0}, fn file_path, {acc_state, acc_count} ->
          case import_json_credential(file_path, acc_state) do
            {:ok, updated_state} -> {updated_state, acc_count + 1}
            {:error, _} -> {acc_state, acc_count}
          end
        end)

      {:ok, new_state, count}
    else
      false -> {:error, :not_a_directory}
      error -> error
    end
  end

  defp import_json_credential(file_path, state) do
    with {:ok, content} <- File.read(file_path),
         {:ok, json} <- Jason.decode(content) do
      provider = detect_provider(json)
      name = json["project_id"] || Path.basename(file_path, ".json")

      id = generate_credential_id(provider)
      daily_limit = Map.get(@provider_limits, provider, :unlimited)

      cred = %{
        id: id,
        provider: provider,
        name: name,
        data: json,
        path: file_path,
        daily_limit: daily_limit,
        used_today: 0,
        last_reset: DateTime.utc_now(),
        created_at: DateTime.utc_now()
      }

      new_creds = Map.update(state.credentials, provider, [cred], &[cred | &1])
      {:ok, %{state | credentials: new_creds}}
    end
  end

  defp detect_provider(json) do
    cond do
      Map.has_key?(json, "type") && json["type"] == "service_account" ->
        "gdrive"

      Map.has_key?(json, "installed") || Map.has_key?(json, "web") ->
        "gdrive"

      Map.has_key?(json, "access_key_id") ->
        "s3"

      Map.has_key?(json, "accountId") && Map.has_key?(json, "applicationKey") ->
        "b2"

      true ->
        "unknown"
    end
  end

  defp generate_credential_id(provider) do
    suffix = :crypto.strong_rand_bytes(4) |> Base.encode16(case: :lower)
    "#{provider}-#{suffix}"
  end

  defp calculate_remaining(%{daily_limit: :unlimited}), do: :unlimited

  defp calculate_remaining(%{daily_limit: limit, used_today: used}) do
    safe_limit = trunc(limit * @quota_safety_margin)
    max(0, safe_limit - used)
  end

  defp calculate_utilization(%{daily_limit: :unlimited}), do: 0.0

  defp calculate_utilization(%{daily_limit: limit, used_today: used}) do
    Float.round(used / limit * 100, 1)
  end

  defp calculate_next_reset("gdrive"), do: next_midnight_pacific()
  defp calculate_next_reset("drive"), do: next_midnight_pacific()
  defp calculate_next_reset(_provider), do: next_midnight_utc()

  defp next_midnight_pacific do
    # Google resets at midnight Pacific Time (UTC-8 or UTC-7 DST)
    # Simplified: assume UTC-8 (PST)
    now = DateTime.utc_now()
    pacific_offset = -8 * 3600

    now
    |> DateTime.add(pacific_offset, :second)
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00])
    |> DateTime.add(-pacific_offset, :second)
  end

  defp next_midnight_utc do
    DateTime.utc_now()
    |> DateTime.to_date()
    |> Date.add(1)
    |> DateTime.new!(~T[00:00:00])
  end

  defp schedule_reset_check do
    # Check every hour
    Process.send_after(self(), :reset_check, 3_600_000)
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 2)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end

  defp format_bytes(:unlimited), do: "unlimited"

  defp format_limit(:unlimited), do: "unlimited"
  defp format_limit(bytes), do: format_bytes(bytes)
end
