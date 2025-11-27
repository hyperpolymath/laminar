# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.IntelligenceTest do
  use ExUnit.Case, async: true

  alias Laminar.Intelligence

  describe "consult_oracle/2" do
    test "ignores OS junk files" do
      assert :ignore == Intelligence.consult_oracle(%{name: ".DS_Store", size: 0, extension: ".DS_Store"})
      assert :ignore == Intelligence.consult_oracle(%{name: "Thumbs.db", size: 0, extension: ".db"})
    end

    test "ignores build artifact directories" do
      assert :ignore == Intelligence.consult_oracle(%{name: "node_modules", size: 0, extension: ""})
      assert :ignore == Intelligence.consult_oracle(%{name: "_build", size: 0, extension: ""})
      assert :ignore == Intelligence.consult_oracle(%{name: "target", size: 0, extension: ""})
    end

    test "creates ghost links for huge files (>5GB)" do
      huge_file = %{name: "backup.tar", size: 6_000_000_000, extension: ".tar"}
      assert {:link, :source_location} = Intelligence.consult_oracle(huge_file)
    end

    test "converts WAV to FLAC" do
      wav_file = %{name: "audio.wav", size: 50_000_000, extension: ".wav"}
      assert {:convert, :flac, :medium_priority} = Intelligence.consult_oracle(wav_file)
    end

    test "converts BMP to WebP" do
      bmp_file = %{name: "image.bmp", size: 10_000_000, extension: ".bmp"}
      assert {:convert, :webp, :low_priority} = Intelligence.consult_oracle(bmp_file)
    end

    test "compresses large SQL files" do
      sql_file = %{name: "dump.sql", size: 100_000_000, extension: ".sql"}
      assert {:compress, :zstd, :high_priority} = Intelligence.consult_oracle(sql_file)
    end

    test "passes through already compressed media" do
      mp4_file = %{name: "video.mp4", size: 500_000_000, extension: ".mp4"}
      assert {:transfer, :raw, :immediate} = Intelligence.consult_oracle(mp4_file)

      jpg_file = %{name: "photo.jpg", size: 5_000_000, extension: ".jpg"}
      assert {:transfer, :raw, :immediate} = Intelligence.consult_oracle(jpg_file)
    end

    test "passes through source code files" do
      ex_file = %{name: "app.ex", size: 5_000, extension: ".ex"}
      assert {:transfer, :raw, :immediate} = Intelligence.consult_oracle(ex_file)

      rs_file = %{name: "main.rs", size: 10_000, extension: ".rs"}
      assert {:transfer, :raw, :immediate} = Intelligence.consult_oracle(rs_file)
    end
  end

  describe "partition_files/2" do
    test "partitions files by action type" do
      files = [
        %{name: "node_modules", size: 0, extension: ""},
        %{name: "app.ex", size: 1000, extension: ".ex"},
        %{name: "huge.tar", size: 10_000_000_000, extension: ".tar"},
        %{name: "audio.wav", size: 50_000, extension: ".wav"}
      ]

      result = Intelligence.partition_files(files)

      assert length(result.ignore) == 1
      assert length(result.transfer) == 1
      assert length(result.link) == 1
      assert length(result.convert) == 1
    end
  end
end
