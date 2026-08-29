defmodule Maxio.Admin.ConfigKV.RegistryTest do
  use ExUnit.Case, async: true

  import Maxio.Admin.ConfigKV.Registry,
    only: [entries: 0, exposed_subsystem: 1, classify_path: 2]

  alias Maxio.Admin.ConfigKV.Registry
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

  test "public archive paths preserve the exact registry order" do
    # Catches deriving the archive projection from Schema/map/DB enumeration, which can reorder or
    # silently expand the bounded S7 public surface. The checked seam must accept the production
    # registry, and arity zero must not bypass that same checked result.
    expected_paths = [
      {:s3, :clock_skew_ms},
      {:listing, :sql_hard_limit},
      {:prometheus_metrics, :public}
    ]

    assert {:ok, checked_paths} = Registry.public_paths(@expected_entries)
    assert checked_paths == expected_paths
    assert Registry.public_paths() == checked_paths

    assert Enum.all?(entries(), &(&1.sensitive? == false))
  end

  test "checked public paths fail closed instead of filtering unsafe injected entries" do
    # Catches an archive advertised as complete silently omitting an entry after registry drift.
    # These three entries exercise the independent sensitive, hidden and forbidden boundaries.
    unsafe_entries = [
      %{
        wire_subsystem: "s3",
        wire_key: "clock_skew_ms",
        core_subsystem: :s3,
        core_key: :clock_skew_ms,
        sensitive?: true,
        order: 0
      },
      %{
        wire_subsystem: "cluster",
        wire_key: "deployment_id",
        core_subsystem: :cluster,
        core_key: :deployment_id,
        sensitive?: false,
        order: 0
      },
      %{
        wire_subsystem: "s3",
        wire_key: "root_password",
        core_subsystem: :s3,
        core_key: :root_password,
        sensitive?: false,
        order: 0
      }
    ]

    for unsafe <- unsafe_entries do
      assert {:error, _reason} = Registry.public_paths(@expected_entries ++ [unsafe])
    end
  end

  test "one ordered registry declaration exposes exact stable subsystem and key help metadata" do
    # Catches a second help-only catalog drifting from the S5 exposure registry, an unordered
    # projection, or Schema prose/default/runtime values leaking into the public protocol.
    expected = [
      {"s3", "Maxio extension: configure s3.clock_skew_ms.", "clock_skew_ms",
       "Maximum allowed SigV4 header-signature clock skew in milliseconds; applied to the next authentication request."},
      {"listing", "Maxio extension: configure listing.sql_hard_limit.", "sql_hard_limit",
       "Hard upper bound on rows fetched by one SQL-backed listing operation; applied to the next listing request."},
      {"prometheus_metrics", "Maxio extension: configure prometheus_metrics.public.", "public",
       "Allow unauthenticated access to the Prometheus metrics endpoint; enable only behind a trusted network or proxy."}
    ]

    assert Enum.map(Registry.subsystems(), fn subsystem ->
             assert subsystem.multiple_targets? == false
             assert length(subsystem.entries) == 1
             [entry] = subsystem.entries
             assert entry.optional? == true
             assert entry.multiple_targets? == false
             assert entry.sensitive? == false

             {subsystem.wire_subsystem, subsystem.description, entry.wire_key, entry.description}
           end) == expected

    for subsystem <- Registry.subsystems() do
      assert Registry.classify_subsystem(subsystem.wire_subsystem) == {:ok, subsystem}
    end
  end

  test "subsystem classification fails closed before unknown and never interns wire atoms" do
    for subsystem <- Schema.forbidden_subsystems() do
      assert Registry.classify_subsystem(to_string(subsystem)) == {:error, :forbidden}
    end

    unique = "untrusted_subsystem_" <> Integer.to_string(System.unique_integer([:positive]))
    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
    assert Registry.classify_subsystem(unique) == {:error, :unknown_subsystem}
    assert_raise ArgumentError, fn -> String.to_existing_atom(unique) end
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
