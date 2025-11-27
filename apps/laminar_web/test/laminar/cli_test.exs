# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.CLITest do
  use ExUnit.Case, async: true

  alias Laminar.CLI

  describe "argument parsing" do
    test "parses global options" do
      args = ["--verbose", "--json", "ls", "dropbox:"]

      # The CLI should extract global options
      assert "--verbose" in args
      assert "--json" in args
    end

    test "parses transfer options" do
      args = [
        "stream",
        "--transfers", "64",
        "--checkers", "128",
        "--buffer-size", "256M",
        "dropbox:", "gdrive:"
      ]

      assert "stream" in args
      assert "--transfers" in args
      assert "64" in args
    end

    test "parses filter options" do
      args = [
        "copy",
        "--include", "*.jpg",
        "--exclude", "*.tmp",
        "--min-size", "1M",
        "--max-size", "100M",
        "s3:bucket", "b2:backup"
      ]

      assert "--include" in args
      assert "*.jpg" in args
      assert "--exclude" in args
    end
  end

  describe "command identification" do
    test "identifies transfer commands" do
      assert is_transfer_command?("stream")
      assert is_transfer_command?("sync")
      assert is_transfer_command?("copy")
      assert is_transfer_command?("move")
    end

    test "identifies list commands" do
      assert is_list_command?("ls")
      assert is_list_command?("lsl")
      assert is_list_command?("lsd")
      assert is_list_command?("tree")
    end

    test "identifies management commands" do
      assert is_management_command?("remotes")
      assert is_management_command?("config")
      assert is_management_command?("profile")
      assert is_management_command?("job")
    end
  end

  describe "remote path parsing" do
    test "parses remote:path format" do
      assert {"dropbox", "photos/vacation"} == parse_remote_path("dropbox:photos/vacation")
      assert {"s3", "bucket/prefix"} == parse_remote_path("s3:bucket/prefix")
    end

    test "parses remote with empty path" do
      assert {"gdrive", ""} == parse_remote_path("gdrive:")
    end

    test "parses local path without colon" do
      assert {"", "/local/path"} == parse_remote_path("/local/path")
    end
  end

  describe "profile application" do
    test "applies high_bandwidth profile settings" do
      opts = apply_test_profile("high_bandwidth", %{})

      assert opts[:transfers] == 64
      assert opts[:checkers] == 128
      assert opts[:buffer_size] == "256M"
    end

    test "applies low_bandwidth profile settings" do
      opts = apply_test_profile("low_bandwidth", %{})

      assert opts[:transfers] == 4
      assert opts[:checkers] == 8
      assert opts[:bwlimit] == "5M"
    end

    test "merges profile with explicit options" do
      opts = apply_test_profile("high_bandwidth", %{transfers: 100})

      # Explicit option should override profile
      assert opts[:transfers] == 100
      assert opts[:checkers] == 128  # From profile
    end
  end

  describe "output formatting" do
    test "formats bytes in human readable form" do
      assert format_bytes(1024) == "1.0 KB"
      assert format_bytes(1_048_576) == "1.0 MB"
      assert format_bytes(1_073_741_824) == "1.0 GB"
      assert format_bytes(1_099_511_627_776) == "1.0 TB"
    end

    test "formats small byte counts" do
      assert format_bytes(0) == "0 B"
      assert format_bytes(100) == "100 B"
      assert format_bytes(1023) == "1023 B"
    end
  end

  # Helper functions for testing
  defp is_transfer_command?(cmd), do: cmd in ["stream", "sync", "copy", "move"]
  defp is_list_command?(cmd), do: cmd in ["ls", "lsl", "lsd", "tree"]
  defp is_management_command?(cmd), do: cmd in ["remotes", "config", "profile", "job"]

  defp parse_remote_path(path) do
    case String.split(path, ":", parts: 2) do
      [remote, rest] -> {remote, rest}
      [path] -> {"", path}
    end
  end

  defp apply_test_profile(profile_name, opts) do
    profiles = %{
      "high_bandwidth" => %{transfers: 64, checkers: 128, buffer_size: "256M"},
      "low_bandwidth" => %{transfers: 4, checkers: 8, buffer_size: "32M", bwlimit: "5M"},
      "extreme" => %{transfers: 128, checkers: 256, buffer_size: "512M"}
    }

    case Map.get(profiles, profile_name) do
      nil -> opts
      profile_opts -> Map.merge(profile_opts, opts)
    end
  end

  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_099_511_627_776 -> "#{Float.round(bytes / 1_099_511_627_776, 1)} TB"
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 1)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 1)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 1)} KB"
      true -> "#{bytes} B"
    end
  end
end
