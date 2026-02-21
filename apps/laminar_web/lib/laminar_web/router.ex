# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.Router do
  @moduledoc """
  The primary request dispatcher for the Laminar web interface.

  Laminar uses a dual-interface strategy:
  1. **GraphQL (Absinthe)**: The preferred interface for complex, graph-based data retrieval.
  2. **REST (Phoenix)**: A fallback and administrative interface for simple CRUD operations.
  """

  use LaminarWeb, :router

  # PIPELINE: JSON-only REST interface.
  pipeline :api do
    plug :accepts, ["json"]
  end

  # PIPELINE: GraphQL-specific configuration.
  pipeline :graphql do
    plug :accepts, ["json"]
  end

  # GRAPHQL ENDPOINTS:
  # Includes the standard API endpoint and the interactive GraphiQL playground.
  scope "/api" do
    pipe_through :graphql

    forward "/graphql", Absinthe.Plug, schema: LaminarWeb.Schema
    forward "/graphiql", Absinthe.Plug.GraphiQL,
      schema: LaminarWeb.Schema,
      interface: :playground,
      socket: LaminarWeb.UserSocket
  end

  # REST API: Stable endpoints for health and status monitoring.
  scope "/api/v1", LaminarWeb do
    pipe_through :api

    get "/health", HealthController, :check
    get "/status", StatusController, :index
    get "/remotes", RemotesController, :index
    post "/transfer", TransferController, :create
  end
end
