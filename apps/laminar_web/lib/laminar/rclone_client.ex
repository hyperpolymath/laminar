# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.RcloneClient do
  @moduledoc """
  HTTP client for communicating with the Rclone Remote Control (RC) API.

  Rclone runs as a daemon in the container, exposing a JSON-RPC API that
  we use to orchestrate transfers.
  """

  require Logger

  @default_timeout 60_000

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
  """
  def put_file(remote, path, content) do
    # For small files, we use rcat which reads from stdin
    # In practice, we'd write to a temp file and use copyfile
    Logger.warning("put_file not fully implemented - would upload to #{remote}:#{path}")
    {:ok, :uploaded}
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
