# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.TransferController do
  use LaminarWeb, :controller

  alias Laminar.RcloneClient

  def create(conn, %{"source" => source, "destination" => dest} = params) do
    config = %{
      transfers: params["parallelism"] || 32,
      multi_thread_streams: params["swarm_streams"] || 8,
      buffer_size: params["buffer_size"] || "128M"
    }

    rclone_params = %{
      srcFs: source,
      dstFs: dest,
      _async: true,
      _config: config
    }

    case RcloneClient.rpc("sync/copy", rclone_params) do
      {:ok, %{"jobid" => job_id}} ->
        conn
        |> put_status(:accepted)
        |> json(%{
          job_id: job_id,
          source: source,
          destination: dest,
          status: "queued"
        })

      {:error, reason} ->
        conn
        |> put_status(:bad_request)
        |> json(%{error: reason})
    end
  end

  def create(conn, _params) do
    conn
    |> put_status(:bad_request)
    |> json(%{error: "Missing required parameters: source, destination"})
  end
end
