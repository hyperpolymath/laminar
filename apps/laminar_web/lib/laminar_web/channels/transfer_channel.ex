# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.TransferChannel do
  @moduledoc """
  Phoenix Channel for real-time transfer updates.

  Provides live progress updates including:
  - Transfer progress (bytes, percentage, rate)
  - File-by-file status
  - Errors and warnings
  - Completion notifications
  - ETA updates

  Clients can subscribe to specific transfers or all transfers.
  """

  use Phoenix.Channel
  require Logger

  alias Laminar.{TransferMetrics, Preflight}

  @impl true
  def join("transfer:" <> transfer_id, _params, socket) do
    # Subscribe to specific transfer updates
    case TransferMetrics.get_metrics(transfer_id) do
      {:ok, metrics} ->
        # Send initial state
        send(self(), {:after_join, transfer_id})
        {:ok, assign(socket, :transfer_id, transfer_id)}

      {:error, :not_found} ->
        {:error, %{reason: "transfer_not_found"}}
    end
  end

  def join("transfers:all", _params, socket) do
    # Subscribe to all transfer updates
    {:ok, assign(socket, :all_transfers, true)}
  end

  def join("preflight:" <> check_id, _params, socket) do
    # Subscribe to preflight check progress
    {:ok, assign(socket, :preflight_id, check_id)}
  end

  @impl true
  def handle_info({:after_join, transfer_id}, socket) do
    # Send current metrics immediately after join
    case TransferMetrics.get_metrics(transfer_id) do
      {:ok, metrics} ->
        push(socket, "metrics", metrics)
      _ -> :ok
    end
    {:noreply, socket}
  end

  @impl true
  def handle_info({:transfer_update, update}, socket) do
    push(socket, "progress", update)
    {:noreply, socket}
  end

  def handle_info({:transfer_complete, result}, socket) do
    push(socket, "complete", result)
    {:noreply, socket}
  end

  def handle_info({:transfer_error, error}, socket) do
    push(socket, "error", error)
    {:noreply, socket}
  end

  def handle_info({:file_progress, file_update}, socket) do
    push(socket, "file_progress", file_update)
    {:noreply, socket}
  end

  def handle_info({:preflight_update, update}, socket) do
    push(socket, "preflight", update)
    {:noreply, socket}
  end

  @impl true
  def handle_in("get_metrics", _params, socket) do
    transfer_id = socket.assigns[:transfer_id]

    case TransferMetrics.get_metrics(transfer_id) do
      {:ok, metrics} ->
        {:reply, {:ok, metrics}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("get_recommendations", _params, socket) do
    transfer_id = socket.assigns[:transfer_id]

    case TransferMetrics.get_recommendations(transfer_id) do
      {:ok, recommendations} ->
        {:reply, {:ok, recommendations}, socket}
      {:error, reason} ->
        {:reply, {:error, %{reason: reason}}, socket}
    end
  end

  def handle_in("pause", _params, socket) do
    transfer_id = socket.assigns[:transfer_id]
    # TODO: Implement pause functionality
    {:reply, {:ok, %{status: "paused", transfer_id: transfer_id}}, socket}
  end

  def handle_in("resume", _params, socket) do
    transfer_id = socket.assigns[:transfer_id]
    # TODO: Implement resume functionality
    {:reply, {:ok, %{status: "resumed", transfer_id: transfer_id}}, socket}
  end

  def handle_in("cancel", _params, socket) do
    transfer_id = socket.assigns[:transfer_id]
    # TODO: Implement cancel functionality
    {:reply, {:ok, %{status: "cancelled", transfer_id: transfer_id}}, socket}
  end

  # Broadcast helpers for use by transfer processes

  @doc """
  Broadcast a progress update to all subscribers of a transfer.
  """
  def broadcast_progress(transfer_id, update) do
    LaminarWeb.Endpoint.broadcast("transfer:#{transfer_id}", "progress", update)
    LaminarWeb.Endpoint.broadcast("transfers:all", "progress", Map.put(update, :transfer_id, transfer_id))
  end

  @doc """
  Broadcast file-level progress.
  """
  def broadcast_file_progress(transfer_id, file_update) do
    LaminarWeb.Endpoint.broadcast("transfer:#{transfer_id}", "file_progress", file_update)
  end

  @doc """
  Broadcast transfer completion.
  """
  def broadcast_complete(transfer_id, result) do
    LaminarWeb.Endpoint.broadcast("transfer:#{transfer_id}", "complete", result)
    LaminarWeb.Endpoint.broadcast("transfers:all", "complete", Map.put(result, :transfer_id, transfer_id))
  end

  @doc """
  Broadcast an error.
  """
  def broadcast_error(transfer_id, error) do
    LaminarWeb.Endpoint.broadcast("transfer:#{transfer_id}", "error", error)
    LaminarWeb.Endpoint.broadcast("transfers:all", "error", Map.put(error, :transfer_id, transfer_id))
  end

  @doc """
  Broadcast preflight check progress.
  """
  def broadcast_preflight(check_id, update) do
    LaminarWeb.Endpoint.broadcast("preflight:#{check_id}", "preflight", update)
  end
end
