# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

# Configure ExUnit
ExUnit.start(capture_log: true, exclude: [:integration, :slow])

# Configure application for testing
Application.put_env(:laminar_web, :rclone_url, "http://localhost:5572")
Application.put_env(:laminar_web, :test_mode, true)

# Define test helpers
defmodule Laminar.TestHelpers do
  @moduledoc """
  Test helpers for Laminar integration tests.
  """

  @doc """
  Waits for a condition to be true.
  """
  def wait_until(fun, timeout \\ 5_000, interval \\ 100) do
    deadline = System.monotonic_time(:millisecond) + timeout

    Stream.repeatedly(fn ->
      if System.monotonic_time(:millisecond) > deadline do
        {:error, :timeout}
      else
        case fun.() do
          true -> {:ok, true}
          false ->
            Process.sleep(interval)
            :continue
          {:ok, _} = result -> result
          _ ->
            Process.sleep(interval)
            :continue
        end
      end
    end)
    |> Enum.find(fn
      :continue -> false
      _ -> true
    end)
  end

  @doc """
  Creates a temporary test file.
  """
  def create_temp_file(content \\ "test content", opts \\ []) do
    prefix = Keyword.get(opts, :prefix, "laminar_test_")
    suffix = Keyword.get(opts, :suffix, ".txt")

    path = Path.join(System.tmp_dir!(), "#{prefix}#{:rand.uniform(1_000_000)}#{suffix}")
    File.write!(path, content)

    on_exit = fn -> File.rm(path) end

    {path, on_exit}
  end

  @doc """
  Creates a mock file metadata map.
  """
  def mock_file(name, size \\ 1000) do
    ext = Path.extname(name)
    %{
      name: name,
      size: size,
      extension: ext,
      mod_time: DateTime.utc_now(),
      path: "/test/#{name}"
    }
  end

  @doc """
  Creates a mock remote response.
  """
  def mock_remote_response(items) when is_list(items) do
    {:ok, items}
  end

  @doc """
  Generates random bytes for testing.
  """
  def random_bytes(size) do
    :crypto.strong_rand_bytes(size)
  end
end

# Import test helpers
import Laminar.TestHelpers
