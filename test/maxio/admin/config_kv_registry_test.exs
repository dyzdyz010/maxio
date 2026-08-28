defmodule Maxio.Admin.ConfigKV.RegistryTest do
  use ExUnit.Case, async: true

  import Maxio.Admin.ConfigKV.Registry,
    only: [entries: 0, exposed_subsystem: 1, classify_path: 2]

  alias Maxio.Config.Schema

  @expected_entries [
    %{
      wire_subsystem: "s3",
      wire_key: "clock_skew_ms",
      core_subsystem: :s3,
      core_key: :clock_skew_ms,
      sensitive?: false,
      order: 0
    },
    %{
      wire_subsystem: "listing",
      wire_key: "sql_hard_limit",
      core_subsystem: :listing,
      core_key: :sql_hard_limit,
      sensitive?: false,
      order: 0
    },
    %{
      wire_subsystem: "prometheus_metrics",
      wire_key: "public",
      core_subsystem: :prometheus_metrics,
      core_key: :public,
      sensitive?: false,
      order: 0
    }
  ]

  test "exposure drift cannot add, omit, reorder, or mark any of the three wire entries sensitive" do
    # Catches a registry that is derived from an unordered map, accidentally exposes another
    # runtime setting, or changes a wire-to-core mapping without a deliberate protocol change.
    assert entries() == @expected_entries
  end

  test "every exposed wire entry names a real writable Schema key guarded by a real Config consumer" do
    # Catches a dangling registry projection: the existing SchemaTest static guard proves each
    # fetched Schema key has a Maxio.Config facade consumer in lib/.
    for entry <- @expected_entries do
      assert {:ok, _schema_entry} = Schema.fetch(entry.core_subsystem, entry.core_key)
    end
  end

  test "exposed subsystem lookup preserves the registry's declared one-key order" do
    # Catches lookup code that uses map enumeration or leaks entries from another subsystem.
    assert exposed_subsystem("s3") ==
             {:ok,
              [
                %{
                  wire_subsystem: "s3",
                  wire_key: "clock_skew_ms",
                  core_subsystem: :s3,
                  core_key: :clock_skew_ms,
                  sensitive?: false,
                  order: 0
                }
              ]}

    assert exposed_subsystem("listing") ==
             {:ok,
              [
                %{
                  wire_subsystem: "listing",
                  wire_key: "sql_hard_limit",
                  core_subsystem: :listing,
                  core_key: :sql_hard_limit,
                  sensitive?: false,
                  order: 0
                }
              ]}

    assert exposed_subsystem("prometheus_metrics") ==
             {:ok,
              [
                %{
                  wire_subsystem: "prometheus_metrics",
                  wire_key: "public",
                  core_subsystem: :prometheus_metrics,
                  core_key: :public,
                  sensitive?: false,
                  order: 0
                }
              ]}

    assert exposed_subsystem("cluster") == {:error, :unknown_subsystem}
  end

  test "path classification keeps the hidden identity and every Schema forbidden declaration ahead of unknowns" do
    # Catches an exposure boundary that turns hidden identity into an exposed setting, or lets a
    # present or future Schema secret/backend declaration masquerade as an ordinary unknown key.
    assert classify_path("cluster", "deployment_id") == {:error, :wire_hidden}

    for subsystem <- Schema.forbidden_subsystems() do
      assert classify_path(to_string(subsystem), "unregistered_key") == {:error, :forbidden}
    end

    for {subsystem, key} <- Schema.forbidden_keys() do
      assert classify_path(to_string(subsystem), to_string(key)) == {:error, :forbidden}
    end

    assert classify_path("s3", "not_a_registered_key") == {:error, :unknown_key}
  end

  test "classifying arbitrary wire strings does not intern caller-controlled atoms" do
    # Catches String.to_atom/1 (or equivalent) on a hostile wire name, which would permanently
    # exhaust the VM atom table under repeated admin requests.
    unique = "untrusted_" <> Integer.to_string(System.unique_integer([:positive]))

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end

    assert classify_path(unique, unique) == {:error, :unknown_key}

    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
  end
end
