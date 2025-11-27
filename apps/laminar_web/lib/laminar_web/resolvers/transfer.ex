# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.Resolvers.Transfer do
  @moduledoc """
  GraphQL resolvers for transfer operations.
  """

  alias Laminar.RcloneClient

  @default_parallelism 32
  @default_swarm_streams 8
  @default_buffer_size "128M"

  def list_active(_parent, _args, _resolution) do
    case RcloneClient.list_jobs() do
      {:ok, jobs} ->
        {:ok, Enum.map(jobs, &format_job/1)}

      {:error, reason} ->
        {:error, "Failed to list active streams: #{reason}"}
    end
  end

  def get_stream(_parent, %{id: job_id}, _resolution) do
    case RcloneClient.get_job_status(job_id) do
      {:ok, job} -> {:ok, format_job(job)}
      {:error, reason} -> {:error, "Failed to get stream: #{reason}"}
    end
  end

  def start_stream(_parent, args, _resolution) do
    config = build_config(args)

    rclone_params = %{
      srcFs: args.source,
      dstFs: args.destination,
      _async: true,
      _config: %{
        transfers: config.parallelism,
        multi_thread_streams: config.swarm_streams,
        buffer_size: config.buffer_size,
        drive_chunk_size: "128M"
      }
    }

    # Add filter if specified
    rclone_params =
      case args[:filter_mode] do
        :code_clean -> Map.put(rclone_params, :filter_from, "/config/rclone/filters.txt")
        :smart -> Map.put(rclone_params, :filter_from, "/config/rclone/filters-smart.txt")
        _ -> rclone_params
      end

    case RcloneClient.rpc("sync/copy", rclone_params) do
      {:ok, %{"jobid" => job_id}} ->
        {:ok,
         %{
           id: to_string(job_id),
           source: args.source,
           destination: args.destination,
           status: :queued,
           config: config
         }}

      {:error, reason} ->
        {:error, "Failed to ignite Laminar flow: #{reason}"}
    end
  end

  def abort(_parent, %{job_id: job_id}, _resolution) do
    case RcloneClient.rpc("job/stop", %{jobid: String.to_integer(job_id)}) do
      {:ok, _} -> {:ok, true}
      {:error, reason} -> {:error, "Failed to abort: #{reason}"}
    end
  end

  def pause(_parent, %{job_id: job_id}, _resolution) do
    case RcloneClient.rpc("core/bwlimit", %{rate: "0"}) do
      {:ok, _} ->
        # Return current job status
        get_stream(nil, %{id: job_id}, nil)

      {:error, reason} ->
        {:error, "Failed to pause: #{reason}"}
    end
  end

  def resume(_parent, %{job_id: job_id}, _resolution) do
    case RcloneClient.rpc("core/bwlimit", %{rate: "off"}) do
      {:ok, _} ->
        get_stream(nil, %{id: job_id}, nil)

      {:error, reason} ->
        {:error, "Failed to resume: #{reason}"}
    end
  end

  # -- Private Helpers --

  defp build_config(args) do
    %{
      parallelism: args[:parallelism] || @default_parallelism,
      swarm_streams: args[:swarm_streams] || @default_swarm_streams,
      buffer_size: args[:buffer_size] || @default_buffer_size,
      chunk_size: "128M"
    }
  end

  defp format_job(job) do
    %{
      id: to_string(job["id"] || job["jobid"]),
      source: job["srcFs"] || "unknown",
      destination: job["dstFs"] || "unknown",
      status: parse_status(job["status"] || job["finished"]),
      speed: job["speed"],
      percentage: job["percentage"],
      transferred: job["transferred"],
      eta: job["eta"]
    }
  end

  defp parse_status(nil), do: :streaming
  defp parse_status(true), do: :success
  defp parse_status(false), do: :streaming
  defp parse_status("running"), do: :streaming
  defp parse_status("finished"), do: :success
  defp parse_status("failed"), do: :failed
  defp parse_status(_), do: :queued
end
