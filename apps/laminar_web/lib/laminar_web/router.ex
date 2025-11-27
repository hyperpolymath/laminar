# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.Router do
  use LaminarWeb, :router

  pipeline :api do
    plug :accepts, ["json"]
  end

  pipeline :graphql do
    plug :accepts, ["json"]
  end

  # GraphQL API
  scope "/api" do
    pipe_through :graphql

    forward "/graphql", Absinthe.Plug, schema: LaminarWeb.Schema
    forward "/graphiql", Absinthe.Plug.GraphiQL,
      schema: LaminarWeb.Schema,
      interface: :playground,
      socket: LaminarWeb.UserSocket
  end

  # REST API (fallback)
  scope "/api/v1", LaminarWeb do
    pipe_through :api

    get "/health", HealthController, :check
    get "/status", StatusController, :index
    get "/remotes", RemotesController, :index
    post "/transfer", TransferController, :create
  end
end
