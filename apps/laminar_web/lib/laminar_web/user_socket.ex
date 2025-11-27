# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.UserSocket do
  @moduledoc """
  WebSocket handler for GraphQL subscriptions.
  """

  use Phoenix.Socket
  use Absinthe.Phoenix.Socket, schema: LaminarWeb.Schema

  @impl true
  def connect(_params, socket, _connect_info) do
    {:ok, socket}
  end

  @impl true
  def id(_socket), do: nil
end
