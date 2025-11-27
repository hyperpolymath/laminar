# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule Laminar.RefineryTest do
  use ExUnit.Case, async: true

  alias Laminar.Refinery

  describe "convert/3" do
    test "returns conversion plan for WAV to FLAC" do
      input = %{
        name: "audio.wav",
        size: 50_000_000,
        extension: ".wav",
        path: "/music/audio.wav"
      }

      {:ok, plan} = Refinery.convert(input, :flac, [])

      assert plan.input_format == :wav
      assert plan.output_format == :flac
      assert plan.estimated_size < input.size  # FLAC is lossless but smaller
    end

    test "returns conversion plan for BMP to WebP" do
      input = %{
        name: "image.bmp",
        size: 10_000_000,
        extension: ".bmp",
        path: "/images/image.bmp"
      }

      {:ok, plan} = Refinery.convert(input, :webp, quality: 85)

      assert plan.input_format == :bmp
      assert plan.output_format == :webp
      assert plan.options[:quality] == 85
    end

    test "returns error for unsupported conversion" do
      input = %{
        name: "video.mp4",
        size: 1_000_000_000,
        extension: ".mp4"
      }

      result = Refinery.convert(input, :invalid_format, [])

      assert {:error, _} = result
    end
  end

  describe "compress/2" do
    test "returns compression plan for large text files" do
      input = %{
        name: "dump.sql",
        size: 500_000_000,
        extension: ".sql"
      }

      {:ok, plan} = Refinery.compress(input, algorithm: :zstd, level: 3)

      assert plan.algorithm == :zstd
      assert plan.compression_level == 3
      assert plan.output_extension == ".sql.zst"
    end

    test "returns compression plan with default options" do
      input = %{
        name: "log.txt",
        size: 100_000_000,
        extension: ".txt"
      }

      {:ok, plan} = Refinery.compress(input, [])

      assert plan.algorithm == :zstd
      assert plan.compression_level == 3  # Default level
    end
  end

  describe "supported_conversions/0" do
    test "returns list of supported conversion pairs" do
      conversions = Refinery.supported_conversions()

      assert is_list(conversions)
      assert {:wav, :flac} in conversions
      assert {:bmp, :webp} in conversions
      assert {:tiff, :webp} in conversions
    end
  end

  describe "estimate_output_size/3" do
    test "estimates FLAC output size" do
      input_size = 100_000_000  # 100MB WAV

      estimated = Refinery.estimate_output_size(input_size, :wav, :flac)

      # FLAC typically achieves 40-60% compression on WAV
      assert estimated < input_size
      assert estimated > input_size * 0.3
      assert estimated < input_size * 0.7
    end

    test "estimates WebP output size" do
      input_size = 10_000_000  # 10MB BMP

      estimated = Refinery.estimate_output_size(input_size, :bmp, :webp)

      # WebP is much smaller than BMP
      assert estimated < input_size * 0.2
    end
  end

  describe "conversion_priority/1" do
    test "returns high priority for audio conversions" do
      assert :high == Refinery.conversion_priority(:wav)
      assert :high == Refinery.conversion_priority(:aiff)
    end

    test "returns medium priority for image conversions" do
      assert :medium == Refinery.conversion_priority(:bmp)
      assert :medium == Refinery.conversion_priority(:tiff)
    end

    test "returns low priority for document conversions" do
      assert :low == Refinery.conversion_priority(:doc)
    end
  end

  describe "requires_ffmpeg?/2" do
    test "returns true for audio/video conversions" do
      assert Refinery.requires_ffmpeg?(:wav, :flac)
      assert Refinery.requires_ffmpeg?(:aiff, :flac)
      assert Refinery.requires_ffmpeg?(:avi, :mp4)
    end

    test "returns false for image conversions" do
      refute Refinery.requires_ffmpeg?(:bmp, :webp)
      refute Refinery.requires_ffmpeg?(:tiff, :webp)
    end
  end

  describe "requires_imagemagick?/2" do
    test "returns true for image conversions" do
      assert Refinery.requires_imagemagick?(:bmp, :webp)
      assert Refinery.requires_imagemagick?(:tiff, :png)
    end

    test "returns false for audio conversions" do
      refute Refinery.requires_imagemagick?(:wav, :flac)
    end
  end
end
