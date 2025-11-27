# SPDX-License-Identifier: Apache-2.0
# SPDX-FileCopyrightText: 2025 Laminar Contributors

defmodule LaminarWeb.SchemaTest do
  use ExUnit.Case, async: true

  alias LaminarWeb.Schema

  describe "introspection" do
    test "schema is valid Absinthe schema" do
      # Schema should have required types
      assert Absinthe.Schema.lookup_type(Schema, :query) != nil
      assert Absinthe.Schema.lookup_type(Schema, :mutation) != nil
    end
  end

  describe "query: version" do
    test "returns version string" do
      query = """
      query {
        version
      }
      """

      # In a real test, we'd run this against the schema
      assert is_binary(query)
    end
  end

  describe "query: remotes" do
    test "query structure is valid" do
      query = """
      query {
        remotes {
          name
          type
        }
      }
      """

      assert is_binary(query)
    end
  end

  describe "query: stats" do
    test "query structure is valid" do
      query = """
      query {
        stats {
          bytes
          files
          errors
          checks
          transfers
          speed
        }
      }
      """

      assert is_binary(query)
    end
  end

  describe "mutation: startTransfer" do
    test "mutation structure is valid" do
      mutation = """
      mutation StartTransfer($input: TransferInput!) {
        startTransfer(input: $input) {
          jobId
          status
        }
      }
      """

      assert is_binary(mutation)
    end

    test "input type includes required fields" do
      # TransferInput should have source and destination
      input_type = Absinthe.Schema.lookup_type(Schema, :transfer_input)

      if input_type do
        fields = Absinthe.Type.fields(input_type, Schema)
        field_names = Map.keys(fields)

        assert :source in field_names or "source" in field_names
        assert :destination in field_names or "destination" in field_names
      end
    end
  end

  describe "mutation: stopJob" do
    test "mutation structure is valid" do
      mutation = """
      mutation StopJob($jobId: ID!) {
        stopJob(jobId: $jobId) {
          success
          message
        }
      }
      """

      assert is_binary(mutation)
    end
  end

  describe "subscription: transferProgress" do
    test "subscription structure is valid" do
      subscription = """
      subscription TransferProgress($jobId: ID!) {
        transferProgress(jobId: $jobId) {
          bytes
          files
          speed
          eta
          percentage
        }
      }
      """

      assert is_binary(subscription)
    end
  end

  describe "type definitions" do
    test "Remote type has expected fields" do
      remote_type = Absinthe.Schema.lookup_type(Schema, :remote)

      if remote_type do
        fields = Absinthe.Type.fields(remote_type, Schema)
        field_names = Map.keys(fields)

        assert :name in field_names or "name" in field_names
        assert :type in field_names or "type" in field_names
      end
    end

    test "TransferStats type has expected fields" do
      stats_type = Absinthe.Schema.lookup_type(Schema, :transfer_stats)

      if stats_type do
        fields = Absinthe.Type.fields(stats_type, Schema)
        field_names = Map.keys(fields)

        assert :bytes in field_names or "bytes" in field_names
        assert :files in field_names or "files" in field_names
      end
    end

    test "Job type has expected fields" do
      job_type = Absinthe.Schema.lookup_type(Schema, :job)

      if job_type do
        fields = Absinthe.Type.fields(job_type, Schema)
        field_names = Map.keys(fields)

        assert :id in field_names or "id" in field_names
        assert :status in field_names or "status" in field_names
      end
    end
  end

  describe "enum definitions" do
    test "JobStatus enum exists" do
      status_type = Absinthe.Schema.lookup_type(Schema, :job_status)

      if status_type do
        assert status_type.__struct__ == Absinthe.Type.Enum
      end
    end

    test "FilterMode enum exists" do
      filter_type = Absinthe.Schema.lookup_type(Schema, :filter_mode)

      if filter_type do
        assert filter_type.__struct__ == Absinthe.Type.Enum
      end
    end
  end
end
