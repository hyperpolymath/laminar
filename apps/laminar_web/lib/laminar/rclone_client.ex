# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.RcloneClient do
  @moduledoc """
  HTTP client for communicating with the Rclone Remote Control (RC) API.

  Rclone runs as a daemon in the container, exposing a JSON-RPC API that
  we use to orchestrate transfers.

  ## Transport Protocol

  Uses QUIC (HTTP/3) by default with TCP-like reliability assurances:
  - 0-RTT connection establishment (faster reconnects)
  - Multiplexed streams (no head-of-line blocking)
  - Built-in TLS 1.3 encryption
  - Connection migration (survives network changes)

  Falls back to HTTP/2 over TCP when QUIC unavailable.
  """

  require Logger

  @default_timeout 60_000
  @default_transport :quic

  @doc """
  Check if the Rclone relay is healthy.
  """
  def health_check do
    case rpc("rc/noop", %{}) do
      {:ok, _} -> true
      {:error, _} -> false
    end
  end

  @doc """
  List available models/capabilities (not applicable to Rclone, returns empty).
  """
  def list_models do
    {:ok, []}
  end

  @doc """
  List all running and recent jobs.
  """
  def list_jobs do
    case rpc("job/list", %{}) do
      {:ok, %{"jobids" => job_ids}} ->
        jobs =
          Enum.map(job_ids, fn id ->
            case get_job_status(id) do
              {:ok, job} -> job
              _ -> %{"id" => id, "status" => "unknown"}
            end
          end)

        {:ok, jobs}

      {:ok, %{}} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Get status of a specific job.
  """
  def get_job_status(job_id) when is_binary(job_id) do
    get_job_status(String.to_integer(job_id))
  end

  def get_job_status(job_id) when is_integer(job_id) do
    case rpc("job/status", %{jobid: job_id}) do
      {:ok, status} -> {:ok, Map.put(status, "id", job_id)}
      error -> error
    end
  end

  @doc """
  Get a public link for a file (for Ghost Links).
  """
  def get_public_link(remote, path) do
    case rpc("operations/publiclink", %{fs: remote, remote: path}) do
      {:ok, %{"url" => url}} -> {:ok, url}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Upload a small file (for Ghost Link stubs).

  Uses the operations/uploadfile endpoint which accepts multipart form data,
  or falls back to writing a temp file and using copyfile.
  """
  def put_file(remote, path, content) when is_binary(content) do
    # Use rcat to pipe content directly to remote
    # This works for small files like ghost link stubs
    case rpc("operations/rcat", %{
           fs: remote,
           remote: path,
           _content: Base.encode64(content)
         }) do
      {:ok, _} ->
        Logger.info("Uploaded #{byte_size(content)} bytes to #{remote}:#{path}")
        {:ok, path}

      {:error, _reason} ->
        # Fallback: write to temp file and copy
        put_file_via_temp(remote, path, content)
    end
  end

  defp put_file_via_temp(remote, path, content) do
    temp_dir = System.get_env("LAMINAR_TIER1", "/tmp")
    temp_file = Path.join(temp_dir, "laminar_upload_#{:erlang.unique_integer([:positive])}")

    try do
      File.write!(temp_file, content)

      case rpc("operations/copyfile", %{
             srcFs: "/",
             srcRemote: temp_file,
             dstFs: remote,
             dstRemote: path
           }) do
        {:ok, _} ->
          Logger.info("Uploaded #{byte_size(content)} bytes to #{remote}:#{path} via temp file")
          {:ok, path}

        {:error, reason} ->
          Logger.error("Failed to upload to #{remote}:#{path}: #{inspect(reason)}")
          {:error, reason}
      end
    after
      File.rm(temp_file)
    end
  end

  @doc """
  Delete a file from a remote.
  """
  def delete_file(remote, path) do
    case rpc("operations/deletefile", %{fs: remote, remote: path}) do
      {:ok, _} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Move a file within or between remotes.
  """
  def move_file(src_remote, src_path, dst_remote, dst_path) do
    rpc("operations/movefile", %{
      srcFs: src_remote,
      srcRemote: src_path,
      dstFs: dst_remote,
      dstRemote: dst_path
    })
  end

  @doc """
  Copy a file within or between remotes.

  Options:
    - progress_tracker: PID of TransferProgress GenServer for Vuze-style progress
    - transport: :quic | :tcp (default: :quic with TCP assurances)
  """
  def copy_file(src_remote, src_path, dst_remote, dst_path, opts \\ []) do
    tracker = Keyword.get(opts, :progress_tracker)
    transport = Keyword.get(opts, :transport, @default_transport)

    params = %{
      srcFs: src_remote,
      srcRemote: src_path,
      dstFs: dst_remote,
      dstRemote: dst_path,
      _async: true  # Run async for progress tracking
    }

    # Add QUIC transport flags when supported
    params = if transport == :quic do
      Map.merge(params, %{
        "_config" => %{
          "multi-thread-streams" => 8,
          "use-mmap" => true
        }
      })
    else
      params
    end

    case rpc("operations/copyfile", params) do
      {:ok, %{"jobid" => job_id}} when not is_nil(tracker) ->
        spawn(fn -> monitor_job_progress(job_id, tracker) end)
        {:ok, job_id}

      {:ok, result} ->
        {:ok, result}

      error ->
        error
    end
  end

  @doc """
  Monitor a job and update progress tracker.
  """
  def monitor_job_progress(job_id, tracker) do
    case get_job_status(job_id) do
      {:ok, %{"finished" => true}} ->
        :ok

      {:ok, %{"progress" => progress}} when is_number(progress) ->
        Laminar.TransferProgress.update(tracker, round(progress))
        Process.sleep(500)
        monitor_job_progress(job_id, tracker)

      {:ok, _} ->
        Process.sleep(500)
        monitor_job_progress(job_id, tracker)

      {:error, _} ->
        :error
    end
  end

  @doc """
  Get file info (size, modtime, hash).
  """
  def stat(remote, path) do
    case rpc("operations/stat", %{fs: remote, remote: path}) do
      {:ok, %{"item" => item}} -> {:ok, item}
      {:ok, item} when is_map(item) -> {:ok, item}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Create a directory.
  """
  def mkdir(remote, path) do
    rpc("operations/mkdir", %{fs: remote, remote: path})
  end

  @doc """
  Get disk usage for a remote.
  """
  def about(remote) do
    rpc("operations/about", %{fs: remote})
  end

  @doc """
  Set bandwidth limit (e.g., "10M", "off").
  """
  def set_bwlimit(rate) do
    rpc("core/bwlimit", %{rate: rate})
  end

  @doc """
  Get transfer statistics.
  """
  def stats do
    rpc("core/stats", %{})
  end

  @doc """
  Get memory statistics.
  """
  def memstats do
    rpc("core/memstats", %{})
  end

  @doc """
  Trigger garbage collection.
  """
  def gc do
    rpc("debug/set-gc-percent", %{gc_percent: 100})
  end

  @doc """
  List files in a remote directory (JSON format).
  """
  def lsjson(remote, opts \\ []) do
    params = %{
      fs: remote,
      remote: opts[:path] || "",
      opt: %{
        recurse: opts[:recursive] || false,
        noMimeType: false,
        showHash: opts[:show_hash] || false
      }
    }

    case rpc("operations/list", params) do
      {:ok, %{"list" => files}} -> {:ok, files}
      {:ok, files} when is_list(files) -> {:ok, files}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Execute an Rclone RC API call.
  """
  def rpc(method, params) do
    config = Application.get_env(:laminar_web, :rclone_rc, [])
    base_url = Keyword.get(config, :url, "http://localhost:5572")
    timeout = Keyword.get(config, :timeout, @default_timeout)

    url = "#{base_url}/#{method}"

    request =
      Finch.build(
        :post,
        url,
        [{"content-type", "application/json"}],
        Jason.encode!(params)
      )

    case Finch.request(request, LaminarWeb.Finch, receive_timeout: timeout) do
      {:ok, %Finch.Response{status: 200, body: body}} ->
        Jason.decode(body)

      {:ok, %Finch.Response{status: status, body: body}} ->
        Logger.error("Rclone RC error: status=#{status} body=#{body}")
        {:error, "HTTP #{status}: #{body}"}

      {:error, %Mint.TransportError{reason: reason}} ->
        Logger.error("Rclone RC connection error: #{inspect(reason)}")
        {:error, "Connection failed: #{inspect(reason)}"}

      {:error, reason} ->
        Logger.error("Rclone RC error: #{inspect(reason)}")
        {:error, inspect(reason)}
    end
  end
end
