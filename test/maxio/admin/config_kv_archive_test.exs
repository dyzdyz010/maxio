defmodule Maxio.Admin.ConfigKV.ArchiveTest do
  use ExUnit.Case, async: true

  alias Maxio.Admin.ConfigKV.{Archive, Registry}
  alias Maxio.Config.Schema

  @fresh_archive "s3 clock_skew_ms=900000 \n" <>
                   "listing sql_hard_limit=100000 \n" <>
                   "prometheus_metrics public=false \n"

  @public_snapshot %{
    {:s3, :clock_skew_ms} => %{value: 900_000, source: :fallback, version: nil},
    {:listing, :sql_hard_limit} => %{value: 100_000, source: :fallback, version: nil},
    {:prometheus_metrics, :public} => %{value: false, source: :fallback, version: nil}
  }

  test "export requests one bounded snapshot and emits the exact 89-byte archive" do
    # Catches one-query-per-subsystem export, map-order serialization, missing trailing spaces/LF,
    # and projection of hidden, forbidden or orphan rows returned by a defensive fake.
    snapshot =
      Map.merge(@public_snapshot, %{
        {:cluster, :deployment_id} => %{
          value: "HIDDEN-DEPLOYMENT-SENTINEL",
          source: :runtime,
          version: 1
        },
        {:s3, :root_password} => %{
          value: "FORBIDDEN-ROOT-SENTINEL",
          source: :runtime,
          version: 1
        },
        {:legacy_orphan, :credential_token} => %{
          value: "ORPHAN-CREDENTIAL-SENTINEL",
          source: :runtime,
          version: 1
        }
      })

    assert {:ok, archive} =
             Archive.export(
               config: __MODULE__,
               test_pid: self(),
               snapshot_response: {:ok, snapshot}
             )

    assert archive == @fresh_archive
    assert byte_size(archive) == 89

    assert :crypto.hash(:sha256, archive) |> Base.encode16(case: :lower) ==
             "c8fe86493cce0083169223b68b59e69612ceeaff7ff45721b45eb85e7eff4141"

    assert String.ends_with?(archive, <<32, 10>>)
    refute archive =~ "HIDDEN-DEPLOYMENT-SENTINEL"
    refute archive =~ "FORBIDDEN-ROOT-SENTINEL"
    refute archive =~ "ORPHAN-CREDENTIAL-SENTINEL"

    assert_receive {:authoritative_snapshot, paths, _opts}
    assert paths == Registry.public_paths()
    refute_receive {:authoritative_snapshot, _paths, _opts}
  end

  test "decode plans typed sets and omitted resets in stable binary subsystem order" do
    # Catches raw wire strings reaching Coordinator, omission being treated as preserve-current,
    # or grouping by registry/map order instead of the frozen binary subsystem order.
    plaintext =
      "s3 clock_skew_ms=\"900000\" \n" <>
        "prometheus_metrics public='true' \n"

    assert {:error, _reason} = Schema.cast(:prometheus_metrics, :public, "true")

    assert Archive.decode_and_plan(plaintext) ==
             {:ok,
              [
                {:listing, [{:reset, :sql_hard_limit}]},
                {:prometheus_metrics, [{:set, :public, true}]},
                {:s3, [{:set, :clock_skew_ms, 900_000}]}
              ]}
  end

  test "an explicit fallback remains a set while blank and comment-only archives reset all" do
    # Catches collapsing an explicit fallback into reset (losing snapshot portability), or
    # interpreting an empty replacement document as a no-op patch.
    assert {:ok, explicit} = Archive.decode_and_plan("s3 clock_skew_ms=900000 \n")

    assert explicit == [
             {:listing, [{:reset, :sql_hard_limit}]},
             {:prometheus_metrics, [{:reset, :public}]},
             {:s3, [{:set, :clock_skew_ms, 900_000}]}
           ]

    reset_all = [
      {:listing, [{:reset, :sql_hard_limit}]},
      {:prometheus_metrics, [{:reset, :public}]},
      {:s3, [{:reset, :clock_skew_ms}]}
    ]

    assert Archive.decode_and_plan("") == {:ok, reset_all}
    assert Archive.decode_and_plan("\n# comment only\n  # another comment\n") == {:ok, reset_all}
  end

  test "duplicate public paths use the last line after typed parsing" do
    # Catches first-line-wins, parsing an overwritten raw scalar before folding, eager map sorting,
    # or emitting two operations for one public path. Only the final raw value is type-relevant.
    plaintext = "s3 clock_skew_ms=not-a-number\ns3 clock_skew_ms=2000\n"

    assert Archive.decode_and_plan(plaintext) ==
             {:ok,
              [
                {:listing, [{:reset, :sql_hard_limit}]},
                {:prometheus_metrics, [{:reset, :public}]},
                {:s3, [{:set, :clock_skew_ms, 2_000}]}
              ]}
  end

  test "target unknown hidden forbidden and orphan input fail before mutation" do
    # Catches any non-public archive line being ignored, partially applied, or passed to the
    # configuration coordinator before the complete replacement document is classified.
    cases = [
      {"s3:secondary clock_skew_ms=1000", :invalid_argument, "unknown", 0},
      {"absent value=1", :config_generic, "unknown", 0},
      {"s3 absent=1", :config_generic, "s3", 0},
      {"cluster deployment_id=HIDDEN-VALUE-SENTINEL", :config_generic, "unknown", 0},
      {"s3 root_password=FORBIDDEN-VALUE-SENTINEL", :access_denied, "s3", 0},
      {"legacy_orphan old_key=ORPHAN-VALUE-SENTINEL", :config_generic, "unknown", 0},
      {"s3 absent=1 clock_skew_ms=1000", :config_bad_json, "s3", 1}
    ]

    for {plaintext, reason, subsystem, key_count} <- cases do
      assert {:error, evidence} = import_with_fake(plaintext)
      assert Map.keys(evidence) |> Enum.sort() == [:key_count, :reason, :stage, :subsystem]
      assert evidence.stage == :exposure
      assert evidence.reason == reason
      assert evidence.subsystem == subsystem
      assert evidence.key_count == key_count
      refute inspect(evidence) =~ "VALUE-SENTINEL"
      refute_receive {:mutate_many, _groups, _opts}
    end
  end

  test "invalid UTF-8 raw type and sensitive prefixes fail closed without submitted values" do
    # Catches unsafe string processing, Schema.parse/3 bypass, a forbidden/sensitive suffix being
    # swallowed into a public scalar, over-broad rejection of an ordinary suffix, or evidence that
    # reflects a submitted value while claiming the mutation never began.
    cases = [
      {"s3 clock_skew_ms=1000 root_password=SECRET-SENTINEL", :exposure, :access_denied,
       "SECRET-SENTINEL", "s3", 1},
      {"s3 clock_skew_ms=1000 secret_token=SECRET-SENTINEL", :exposure, :access_denied,
       "SECRET-SENTINEL", "s3", 1},
      {"s3 clock_skew_ms=1000 absent=UNKNOWN-SUFFIX-SENTINEL", :type, :config_bad_json,
       "UNKNOWN-SUFFIX-SENTINEL", "s3", 1},
      {<<"s3 clock_skew_ms=UTF8-VALUE-SENTINEL", 255>>, :parser, :config_bad_json,
       "UTF8-VALUE-SENTINEL", "unknown", 0},
      {"s3 clock_skew_ms=3600001", :type, :config_bad_json, "3600001", "s3", 1},
      {"secret_backend token=SENSITIVE-VALUE-SENTINEL", :exposure, :access_denied,
       "SENSITIVE-VALUE-SENTINEL", "unknown", 0}
    ]

    for {plaintext, stage, reason, submitted, subsystem, key_count} <- cases do
      assert {:error, evidence} = import_with_fake(plaintext)
      assert Map.keys(evidence) |> Enum.sort() == [:key_count, :reason, :stage, :subsystem]
      assert evidence.stage == stage
      assert evidence.reason == reason
      assert evidence.subsystem == subsystem
      assert evidence.key_count == key_count
      refute inspect(evidence) =~ submitted
      refute_receive {:mutate_many, _groups, _opts}
    end
  end

  test "import delegates one complete typed plan with a string source" do
    # Catches per-subsystem mutation calls, atom audit sources, or import returning a fabricated
    # result instead of the single Config facade result.
    committed = %{committed?: true, changed_count: 3}

    assert Archive.import_config(@fresh_archive,
             config: __MODULE__,
             test_pid: self(),
             source: "admin_api",
             mutation_response: {:ok, committed}
           ) == {:ok, committed}

    assert_receive {:mutate_many, groups, opts}

    assert groups == [
             {:listing, [{:set, :sql_hard_limit, 100_000}]},
             {:prometheus_metrics, [{:set, :public, false}]},
             {:s3, [{:set, :clock_skew_ms, 900_000}]}
           ]

    assert Keyword.fetch!(opts, :source) == "admin_api"
    assert is_binary(Keyword.fetch!(opts, :source))
    refute_receive {:mutate_many, _groups, _opts}
  end

  # The test module itself is the injected Config facade, avoiding a second module in this file.
  def authoritative_snapshot(paths, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:authoritative_snapshot, paths, opts})
    Keyword.fetch!(opts, :snapshot_response)
  end

  def mutate_many(groups, opts) do
    send(Keyword.fetch!(opts, :test_pid), {:mutate_many, groups, opts})
    Keyword.fetch!(opts, :mutation_response)
  end

  defp import_with_fake(plaintext) do
    Archive.import_config(plaintext,
      config: __MODULE__,
      test_pid: self(),
      source: "admin_api",
      mutation_response: {:ok, %{committed?: true}}
    )
  end
end
