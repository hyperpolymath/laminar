# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.RemotesController do
  use LaminarWeb, :controller

  alias Laminar.RcloneClient

  def index(conn, _params) do
    case RcloneClient.rpc("config/listremotes", %{}) do
      {:ok, %{"remotes" => remotes}} ->
        json(conn, %{remotes: remotes})

      {:error, reason} ->
        conn
        |> put_status(:service_unavailable)
        |> json(%{error: reason})
    end
  end
end
