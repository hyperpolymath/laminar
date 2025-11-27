# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.Schema.Types do
  @moduledoc """
  Custom GraphQL types for Laminar.
  """

  use Absinthe.Schema.Notation

  @desc "A file size in human-readable format (e.g., '128M', '1G')"
  scalar :file_size, name: "FileSize" do
    parse fn
      %{value: value}, _ when is_binary(value) -> {:ok, value}
      _, _ -> :error
    end

    serialize fn value -> value end
  end
end
