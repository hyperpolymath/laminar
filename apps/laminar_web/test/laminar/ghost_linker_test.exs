# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.GhostLinkerTest do
  use ExUnit.Case, async: true

  alias Laminar.GhostLinker

  describe "create_ghost/2" do
    test "creates ghost link for file" do
      file_info = %{
        name: "large_video.mp4",
        size: 10_000_000_000,  # 10GB
        path: "videos/large_video.mp4",
        remote: "dropbox",
        mod_time: "2024-01-15T10:30:00Z",
        mime_type: "video/mp4"
      }

      ghost = GhostLinker.create_ghost(file_info, "gdrive:backup/videos")

      assert ghost.type == :ghost_link
      assert ghost.source_remote == "dropbox"
      assert ghost.source_path == "videos/large_video.mp4"
      assert ghost.original_size == 10_000_000_000
      assert ghost.original_name == "large_video.mp4"
    end

    test "includes original metadata in ghost" do
      file_info = %{
        name: "archive.tar.gz",
        size: 50_000_000_000,  # 50GB
        path: "archives/archive.tar.gz",
        remote: "s3",
        mod_time: "2024-02-20T14:45:00Z",
        checksum: "abc123"
      }

      ghost = GhostLinker.create_ghost(file_info, "b2:cold-storage")

      assert ghost.metadata.checksum == "abc123"
      assert ghost.metadata.mod_time == "2024-02-20T14:45:00Z"
    end
  end

  describe "serialize_ghost/1" do
    test "serializes ghost to JSON-compatible format" do
      ghost = %GhostLinker.Ghost{
        type: :ghost_link,
        source_remote: "dropbox",
        source_path: "path/to/file.zip",
        original_size: 5_000_000_000,
        original_name: "file.zip",
        created_at: ~U[2024-01-01 12:00:00Z],
        metadata: %{checksum: "sha256:abc123"}
      }

      serialized = GhostLinker.serialize_ghost(ghost)

      assert is_binary(serialized)
      # Should be valid JSON
      assert {:ok, _} = Jason.decode(serialized)
    end
  end

  describe "deserialize_ghost/1" do
    test "deserializes ghost from JSON" do
      json = """
      {
        "type": "ghost_link",
        "laminar_version": "1.0.0",
        "source": {
          "remote": "dropbox",
          "path": "videos/movie.mkv"
        },
        "original": {
          "name": "movie.mkv",
          "size": 8000000000,
          "checksum": "sha256:def456"
        },
        "created_at": "2024-01-15T10:00:00Z"
      }
      """

      {:ok, ghost} = GhostLinker.deserialize_ghost(json)

      assert ghost.source_remote == "dropbox"
      assert ghost.source_path == "videos/movie.mkv"
      assert ghost.original_size == 8_000_000_000
    end

    test "returns error for invalid JSON" do
      assert {:error, _} = GhostLinker.deserialize_ghost("not valid json")
    end

    test "returns error for missing required fields" do
      json = """
      {
        "type": "ghost_link"
      }
      """

      assert {:error, _} = GhostLinker.deserialize_ghost(json)
    end
  end

  describe "is_ghost?/1" do
    test "returns true for ghost link files" do
      assert GhostLinker.is_ghost?("movie.mkv.ghost")
      assert GhostLinker.is_ghost?("archive.tar.gz.ghost")
    end

    test "returns false for regular files" do
      refute GhostLinker.is_ghost?("movie.mkv")
      refute GhostLinker.is_ghost?("document.pdf")
    end
  end

  describe "ghost_threshold/0" do
    test "returns threshold in bytes" do
      threshold = GhostLinker.ghost_threshold()

      assert is_integer(threshold)
      # Default threshold is 5GB
      assert threshold == 5_368_709_120
    end
  end

  describe "should_ghost?/1" do
    test "returns true for files above threshold" do
      assert GhostLinker.should_ghost?(%{size: 10_000_000_000})
      assert GhostLinker.should_ghost?(%{size: 6_000_000_000})
    end

    test "returns false for files below threshold" do
      refute GhostLinker.should_ghost?(%{size: 1_000_000_000})
      refute GhostLinker.should_ghost?(%{size: 100_000})
    end

    test "returns false for files exactly at threshold" do
      threshold = GhostLinker.ghost_threshold()
      refute GhostLinker.should_ghost?(%{size: threshold})
    end
  end
end
