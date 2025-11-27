# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.Resolvers.System do
  @moduledoc """
  GraphQL resolvers for system health and configuration.
  """

  alias Laminar.RcloneClient

  def health(_parent, _args, _resolution) do
    relay_healthy = RcloneClient.health_check()

    # Read system stats
    {cpu_load, _} =
      case File.read("/proc/loadavg") do
        {:ok, content} ->
          [load | _] = String.split(content)
          Float.parse(load)

        _ ->
          {0.0, ""}
      end

    memory_info = get_memory_info()
    tcp_algo = get_tcp_congestion_algo()
    tcp_retransmits = get_tcp_retransmits()

    {:ok,
     %{
       cpu_load: cpu_load,
       memory_used: memory_info.used,
       memory_available: memory_info.available,
       network_congestion_algo: tcp_algo,
       tcp_retransmits: tcp_retransmits,
       relay_healthy: relay_healthy
     }}
  end

  def list_remotes(_parent, _args, _resolution) do
    case RcloneClient.rpc("config/listremotes", %{}) do
      {:ok, %{"remotes" => remotes}} ->
        formatted =
          Enum.map(remotes, fn name ->
            %{
              name: name,
              type: "unknown",
              space_used: nil,
              space_available: nil
            }
          end)

        {:ok, formatted}

      {:error, reason} ->
        {:error, "Failed to list remotes: #{reason}"}
    end
  end

  # -- Private Helpers --

  defp get_memory_info do
    case File.read("/proc/meminfo") do
      {:ok, content} ->
        lines = String.split(content, "\n")

        mem_total =
          lines
          |> Enum.find(&String.starts_with?(&1, "MemTotal:"))
          |> parse_meminfo_line()

        mem_available =
          lines
          |> Enum.find(&String.starts_with?(&1, "MemAvailable:"))
          |> parse_meminfo_line()

        used = mem_total - mem_available

        %{
          used: format_bytes(used * 1024),
          available: format_bytes(mem_available * 1024)
        }

      _ ->
        %{used: "unknown", available: "unknown"}
    end
  end

  defp parse_meminfo_line(nil), do: 0

  defp parse_meminfo_line(line) do
    case Regex.run(~r/(\d+)/, line) do
      [_, num] -> String.to_integer(num)
      _ -> 0
    end
  end

  defp get_tcp_congestion_algo do
    case File.read("/proc/sys/net/ipv4/tcp_congestion_control") do
      {:ok, algo} -> String.trim(algo)
      _ -> "unknown"
    end
  end

  defp get_tcp_retransmits do
    case File.read("/proc/net/snmp") do
      {:ok, content} ->
        lines = String.split(content, "\n")

        tcp_line =
          lines
          |> Enum.drop_while(&(!String.starts_with?(&1, "Tcp:")))
          |> Enum.take(2)

        case tcp_line do
          [_header, values] ->
            # RetransSegs is typically the 13th field
            parts = String.split(values)
            if length(parts) >= 13, do: String.to_integer(Enum.at(parts, 12)), else: 0

          _ ->
            0
        end

      _ ->
        0
    end
  end

  defp format_bytes(bytes) when bytes >= 1_073_741_824 do
    "#{Float.round(bytes / 1_073_741_824, 2)} GiB"
  end

  defp format_bytes(bytes) when bytes >= 1_048_576 do
    "#{Float.round(bytes / 1_048_576, 2)} MiB"
  end

  defp format_bytes(bytes) do
    "#{Float.round(bytes / 1024, 2)} KiB"
  end
end
