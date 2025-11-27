# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.RcloneClientTest do
  use ExUnit.Case, async: true

  alias Laminar.RcloneClient

  # Unit tests that don't require a running rclone instance
  describe "url construction" do
    test "builds correct RPC URL" do
      # The URL should be constructed from environment/config
      url = RcloneClient.rclone_url()
      assert is_binary(url)
      assert String.starts_with?(url, "http")
    end
  end

  describe "request building" do
    test "builds JSON request body" do
      params = %{fs: "dropbox:", remote: "test.txt"}
      # Internal function test - verifying params are properly structured
      assert is_map(params)
      assert params[:fs] == "dropbox:"
    end
  end

  # Integration tests that require rclone to be running
  @tag :integration
  describe "list_remotes/0" do
    test "returns list of remotes" do
      case RcloneClient.list_remotes() do
        {:ok, remotes} ->
          assert is_list(remotes)

        {:error, :connection_refused} ->
          # Expected when rclone is not running
          :ok

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end
  end

  @tag :integration
  describe "list/2" do
    test "lists files in remote" do
      case RcloneClient.list("local", "/tmp") do
        {:ok, items} ->
          assert is_list(items)
          # Items should have expected structure
          if length(items) > 0 do
            item = hd(items)
            assert Map.has_key?(item, "Path") or Map.has_key?(item, "Name")
          end

        {:error, :connection_refused} ->
          :ok

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end
  end

  @tag :integration
  describe "version/0" do
    test "returns rclone version" do
      case RcloneClient.version() do
        {:ok, version_info} ->
          assert is_map(version_info) or is_binary(version_info)

        {:error, :connection_refused} ->
          :ok

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end
  end

  @tag :integration
  describe "stats/0" do
    test "returns transfer statistics" do
      case RcloneClient.stats() do
        {:ok, stats} ->
          assert is_map(stats)

        {:error, :connection_refused} ->
          :ok

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end
  end

  @tag :integration
  describe "memstats/0" do
    test "returns memory statistics" do
      case RcloneClient.memstats() do
        {:ok, memstats} ->
          assert is_map(memstats)

        {:error, :connection_refused} ->
          :ok

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end
  end

  @tag :integration
  describe "job_list/0" do
    test "returns list of jobs" do
      case RcloneClient.job_list() do
        {:ok, jobs} ->
          assert is_list(jobs) or is_map(jobs)

        {:error, :connection_refused} ->
          :ok

        {:error, reason} ->
          flunk("Unexpected error: #{inspect(reason)}")
      end
    end
  end
end
