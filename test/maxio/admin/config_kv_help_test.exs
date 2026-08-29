defmodule Maxio.Admin.ConfigKV.HelpTest do
  use ExUnit.Case, async: true

  alias Maxio.Admin.ConfigKV.Help

  @top_level_json ~s({"subSys":"","description":"","multipleTargets":false,"keysHelp":[{"key":"s3","description":"Maxio extension: configure s3.clock_skew_ms.","optional":false,"type":"","multipleTargets":false},{"key":"listing","description":"Maxio extension: configure listing.sql_hard_limit.","optional":false,"type":"","multipleTargets":false},{"key":"prometheus_metrics","description":"Maxio extension: configure prometheus_metrics.public.","optional":false,"type":"","multipleTargets":false}]})

  @subsystem_json %{
    "s3" =>
      ~s({"subSys":"s3","description":"Maxio extension: configure s3.clock_skew_ms.","multipleTargets":false,"keysHelp":[{"key":"clock_skew_ms","description":"Maximum allowed SigV4 header-signature clock skew in milliseconds; applied to the next authentication request.","optional":true,"type":"integer in 0..3600000","multipleTargets":false}]}),
    "listing" =>
      ~s({"subSys":"listing","description":"Maxio extension: configure listing.sql_hard_limit.","multipleTargets":false,"keysHelp":[{"key":"sql_hard_limit","description":"Hard upper bound on rows fetched by one SQL-backed listing operation; applied to the next listing request.","optional":true,"type":"integer in 1..10000000","multipleTargets":false}]}),
    "prometheus_metrics" =>
      ~s({"subSys":"prometheus_metrics","description":"Maxio extension: configure prometheus_metrics.public.","multipleTargets":false,"keysHelp":[{"key":"public","description":"Allow unauthenticated access to the Prometheus metrics endpoint; enable only behind a trusted network or proxy.","optional":true,"type":"boolean","multipleTargets":false}]})
  }

  test "empty subsystem projects the ordered catalog and ignores key and env after the early return" do
    for {key, env_only?} <- [{"", false}, {"anything", false}, {"", true}, {"anything", true}] do
      assert {:ok,
              %{
                scope: :catalog,
                subsystem: "all",
                key_count: 3,
                env_only?: ^env_only?,
                wire: wire
              }} = Help.project("", key, env_only?)

      assert IO.iodata_to_binary(Help.encode_line(wire)) == @top_level_json <> "\n"
    end
  end

  test "subsystem and direct-key projection use Schema types and madmin-client field order" do
    for {subsystem, key} <- [
          {"s3", "clock_skew_ms"},
          {"listing", "sql_hard_limit"},
          {"prometheus_metrics", "public"}
        ] do
      assert {:ok, %{scope: :subsystem, key_count: 1, wire: subsystem_wire}} =
               Help.project(subsystem, "", false)

      assert {:ok, %{scope: :key, key_count: 1, wire: key_wire}} =
               Help.project(subsystem, key, false)

      expected = Map.fetch!(@subsystem_json, subsystem) <> "\n"
      assert IO.iodata_to_binary(Help.encode_line(subsystem_wire)) == expected
      assert IO.iodata_to_binary(Help.encode_line(key_wire)) == expected
    end
  end

  test "env-only projection filters only known nonempty subsystem keys through Schema bindings" do
    assert {:ok,
            %{
              scope: :subsystem,
              subsystem: "s3",
              key_count: 0,
              env_only?: true,
              wire: wire
            }} = Help.project("s3", "", true)

    encoded = IO.iodata_to_binary(Help.encode_line(wire))

    assert encoded ==
             ~s({"subSys":"s3","description":"Maxio extension: configure s3.clock_skew_ms.","multipleTargets":false,"keysHelp":[]}) <>
               "\n"

    assert Jason.decode!(encoded)["keysHelp"] == []

    assert {:error,
            %{
              reason: {:config_generic, "unknown key clock_skew_ms for sub-system s3"},
              subsystem: "s3",
              key_count: 0,
              stage: :exposure
            }} = Help.project("s3", "clock_skew_ms", true)
  end

  test "target, forbidden, hidden, unknown, and sensitive paths retain safe precedence and evidence" do
    assert {:error, %{reason: :invalid_argument, subsystem: "s3", key_count: 0, stage: :parser}} =
             Help.project("s3:target", "", false)

    assert {:error,
            %{
              reason: {:config_generic, "unknown sub-system absent"},
              subsystem: "absent",
              key_count: 0,
              stage: :exposure
            }} = Help.project("absent", "", false)

    assert {:error,
            %{
              reason: {:config_generic, "unknown sub-system absent"},
              subsystem: "absent",
              key_count: 0,
              stage: :exposure
            }} = Help.project("absent", "also_absent", false)

    assert {:error,
            %{
              reason: {:config_generic, "unknown key absent for sub-system s3"},
              subsystem: "s3",
              key_count: 0,
              stage: :exposure
            }} = Help.project("s3", "absent", false)

    assert {:error, %{reason: :access_denied, subsystem: "s3", stage: :exposure}} =
             Help.project("s3", "root_password", false)

    assert {:error, %{reason: :access_denied, subsystem: "unknown", stage: :exposure}} =
             Help.project("storage_backend", "unregistered", false)

    for {subsystem, key, forbidden_fragment} <- [
          {"cluster", "deployment_id", "deployment_id"},
          {"SECRETCONFIGKVSENTINEL", "", "SECRETCONFIGKVSENTINEL"},
          {"s3", "credential", "credential"},
          {"bad/control", "", "bad/control"}
        ] do
      assert {:error,
              %{
                reason: :config_generic,
                subsystem: safe_subsystem,
                key_count: 0,
                stage: :exposure
              }} = Help.project(subsystem, key, false)

      refute inspect(safe_subsystem) =~ forbidden_fragment
    end
  end

  test "CLI error descriptions form a closed redacted vocabulary" do
    assert Help.describe_error(:invalid_argument) == "configuration help request is invalid"
    assert Help.describe_error(:access_denied) == "configuration help path is not exposed"

    assert Help.describe_error({:config_generic, "unknown sub-system safe"}) ==
             "configuration help entry was not found"

    assert Help.describe_error({:unexpected, "TOP-SECRET"}) == "configuration help failed"
  end
end
