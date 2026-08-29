defmodule Maxio.Admin.ConfigKV.AdapterTest do
  use Maxio.DataCase, async: false

  alias Maxio.Admin.ConfigKV.{Adapter, Registry}
  alias Maxio.Config
  alias Maxio.Config.{RuntimeConfig, RuntimeConfigAudit, Store}

  alias Maxio.Test.{
    ConfigBatchFailureRepo,
    ConfigMissingQueryRepo,
    ConfigPostcommitNotify,
    ConfigPostcommitStore
  }

  setup do
    ConfigBatchFailureRepo.clear!()
    Store.reset_local!()

    on_exit(fn ->
      ConfigBatchFailureRepo.clear!()
      Store.reset_local!()
    end)

    :ok
  end

  describe "typed wire projections" do
    test "GET renders each approved projection with exact core metadata and bytes" do
      # Catches a swapped wire/core mapping, a non-facade value projection, uppercase booleans,
      # or removal of madmin's final ASCII space/LF pair.
      for {wire_subsystem, core_subsystem, core_key, expected_plaintext} <- [
            {"s3", :s3, :clock_skew_ms, "s3 clock_skew_ms=900000 \n"},
            {"listing", :listing, :sql_hard_limit, "listing sql_hard_limit=100000 \n"},
            {"prometheus_metrics", :prometheus_metrics, :public,
             "prometheus_metrics public=false \n"}
          ] do
        assert {:ok,
                %{
                  plaintext: plaintext,
                  subsystem: ^core_subsystem,
                  keys: [^core_key]
                }} = Adapter.get(wire_subsystem)

        assert IO.iodata_to_binary(plaintext) == expected_plaintext
        assert String.ends_with?(expected_plaintext, <<32, 10>>)
      end
    end

    test "integer commands accept both inclusive boundaries as typed values" do
      # Catches off-by-one bounds or an adapter that forwards raw strings to Config.
      for {command, subsystem, key, expected} <- [
            {"s3 clock_skew_ms=0", "s3", "clock_skew_ms", 0},
            {"s3 clock_skew_ms=3600000", "s3", "clock_skew_ms", 3_600_000},
            {"listing sql_hard_limit=1", "listing", "sql_hard_limit", 1},
            {"listing sql_hard_limit=10000000", "listing", "sql_hard_limit", 10_000_000}
          ] do
        assert {:ok, %{committed?: true}} = Adapter.set(command, mutation_opts())

        assert Repo.one(
                 from row in RuntimeConfig,
                   where: row.subsystem == ^subsystem and row.key == ^key,
                   select: row.value
               ) == %{"v" => expected}
      end
    end

    test "madmin mixed quote sanitization reaches the typed Config mutation boundary" do
      # Catches the parser leaving the inner single quotes for Schema.parse/3 after it removes the
      # outer double quotes.
      assert {:ok, %{committed?: true, changed_count: 1}} =
               Adapter.set(~s(s3 clock_skew_ms="'900000'"), mutation_opts())

      assert Repo.one(
               from row in RuntimeConfig,
                 where: row.subsystem == "s3" and row.key == "clock_skew_ms",
                 select: row.value
             ) == %{"v" => 900_000}
    end

    test "integer commands reject partial decimals and both out-of-range neighbors" do
      # Catches Integer.parse/1 remainder loss, clamping, or bounds checked against the wrong
      # projection. None of these invalid scalars may begin a transaction.
      for command <- [
            "s3 clock_skew_ms=-1",
            "s3 clock_skew_ms=3600001",
            "s3 clock_skew_ms=1ms",
            "listing sql_hard_limit=0",
            "listing sql_hard_limit=10000001",
            "listing sql_hard_limit=1.0"
          ] do
        assert {:error, :config_bad_json} = Adapter.set(command, mutation_opts())
      end

      assert ConfigBatchFailureRepo.observations().transactions == 0
      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "boolean commands accept only lowercase true and false" do
      # Catches truthy string coercion or case folding at the Admin boundary.
      assert {:ok, %{committed?: true}} =
               Adapter.set("prometheus_metrics public=true", mutation_opts())

      assert Store.lookup(:prometheus_metrics, :public) == {:ok, true}

      assert {:ok, %{committed?: true}} =
               Adapter.set("prometheus_metrics public=false", mutation_opts())

      assert Store.lookup(:prometheus_metrics, :public) == {:ok, false}

      for raw <- ["TRUE", "False", "1", "yes"] do
        assert {:error, :config_bad_json} =
                 Adapter.set("prometheus_metrics public=#{raw}", mutation_opts())
      end

      assert Repo.one(
               from row in RuntimeConfig,
                 where: row.subsystem == "prometheus_metrics" and row.key == "public",
                 select: row.value
             ) == %{"v" => false}
    end
  end

  describe "exposure and parser error translation" do
    test "known hidden cluster configuration is generic for get set and reset" do
      # Catches leakage of deployment_id as an ordinary unknown, reset-not-found, or BadJSON.
      assert {:error, :config_generic} = Adapter.get("cluster")

      assert {:error, :config_generic} =
               Adapter.set("cluster deployment_id=replacement", mutation_opts())

      assert {:error, :config_generic} =
               Adapter.reset("cluster deployment_id", mutation_opts())

      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "ordinary unknown reset key in an exposed subsystem is not found" do
      # Catches flattening the reset-only 404 branch into the generic 400 branch.
      assert {:error, :config_not_found} =
               Adapter.reset("s3 not_a_registered_key", mutation_opts())

      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "a later-line unknown reset keeps the atom contract and exposes detail only on request" do
      # Catches leaking HTTP-only description tuples to ordinary Adapter callers, losing the safe
      # evidence needed by Plug, or beginning a transaction before the subset is classified.
      insert_runtime!("s3", "clock_skew_ms", 2_468, 7)
      command = "s3 clock_skew_ms\ns3 absent"
      opts = mutation_opts()

      assert {:error, :config_not_found} = Adapter.reset(command, opts)

      assert ConfigBatchFailureRepo.observations() == %{
               transactions: 0,
               query_calls: 0,
               advisory_locks: 0
             }

      assert Repo.one(
               from row in RuntimeConfig,
                 where: row.subsystem == "s3" and row.key == "clock_skew_ms",
                 select: {row.value, row.version}
             ) == {%{"v" => 2_468}, 7}

      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0

      assert {:error,
              %{
                reason: {:config_not_found, "key absent doesn't exist"},
                subsystem: "s3",
                key_count: 2,
                stage: :exposure
              }} = Adapter.reset(command, Keyword.put(opts, :return_error_evidence, true))

      assert ConfigBatchFailureRepo.observations() == %{
               transactions: 0,
               query_calls: 0,
               advisory_locks: 0
             }

      assert Repo.one(
               from row in RuntimeConfig,
                 where: row.subsystem == "s3" and row.key == "clock_skew_ms",
                 select: {row.value, row.version}
             ) == {%{"v" => 2_468}, 7}

      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "forbidden paths win before unknown and unknown-prefix classification" do
      # Catches Parser's generic/BadJSON result masking a known secret or backend path.
      assert {:error, :access_denied} =
               Adapter.set(
                 "s3 root_password=forbidden-value clock_skew_ms=1000",
                 mutation_opts()
               )

      assert {:error, :access_denied} =
               Adapter.set("storage_backend module=Elixir.Forbidden", mutation_opts())

      assert {:error, :access_denied} =
               Adapter.reset("s3 root_password not_a_registered_key", mutation_opts())

      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "explicit target is invalid argument for every operation" do
      # Catches accepting a target and silently applying or reading the default target.
      assert {:error, :invalid_argument} = Adapter.get("s3:secondary")

      assert {:error, :invalid_argument} =
               Adapter.set("s3:secondary clock_skew_ms=1000", mutation_opts())

      assert {:error, :invalid_argument} =
               Adapter.reset("s3:secondary", mutation_opts())
    end

    test "a first-line target remains invalid when a later line names a forbidden path" do
      # Catches plaintext-wide exposure preflight replacing the parser's earlier target error with
      # AccessDenied. Both commands are evaluated before assertions so both precedence paths run.
      results = [
        Adapter.set(
          "s3:secondary clock_skew_ms=1000\ns3 root_password=forbidden-value",
          mutation_opts()
        ),
        Adapter.reset("s3:secondary\nstorage_backend module", mutation_opts())
      ]

      assert results == [{:error, :invalid_argument}, {:error, :invalid_argument}]

      assert ConfigBatchFailureRepo.observations() == %{
               transactions: 0,
               query_calls: 0,
               advisory_locks: 0
             }

      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "cross-subsystem and unknown-prefix safety deviations are BadJSON" do
      # Catches either unsafe parser deviation being diluted into the generic unknown response.
      assert {:error, :config_bad_json} =
               Adapter.set(
                 "s3 clock_skew_ms=1000\nlisting sql_hard_limit=100000",
                 mutation_opts()
               )

      assert {:error, :config_bad_json} =
               Adapter.set("s3 absent=1 clock_skew_ms=1000", mutation_opts())

      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "cross-subsystem grammar wins before a forbidden token on the later line" do
      # Catches a general exposure preflight scanning all tokens before Parser establishes that
      # the plaintext cannot represent one subsystem mutation.
      assert {:error, :config_bad_json} =
               Adapter.set(
                 "listing sql_hard_limit=100000\ns3 clock_skew_ms=1000 root_password=forbidden-value",
                 mutation_opts()
               )

      assert ConfigBatchFailureRepo.observations() == %{
               transactions: 0,
               query_calls: 0,
               advisory_locks: 0
             }

      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "unknown subsystem and unknown-only set remain generic" do
      # Catches over-broad translation of every parser error to BadJSON.
      assert {:error, :config_generic} = Adapter.get("absent")
      assert {:error, :config_generic} = Adapter.set("s3 absent=1", mutation_opts())
      assert {:error, :config_generic} = Adapter.reset("absent", mutation_opts())
    end

    test "uppercase safe identifiers preserve exact evidence while unsafe identifiers stay redacted" do
      evidence_opts = Keyword.put(mutation_opts(), :return_error_evidence, true)

      safe_get = Adapter.get("S3", return_error_evidence: true)
      safe_reset = Adapter.reset("s3 ABSENT", evidence_opts)

      unsafe_gets = [
        {"SECRETCONFIGKVSENTINEL",
         Adapter.get("SECRETCONFIGKVSENTINEL", return_error_evidence: true)},
        {"CONTROL\u0001MARK", Adapter.get("CONTROL\u0001MARK", return_error_evidence: true)},
        {String.duplicate("A", 129),
         Adapter.get(String.duplicate("A", 129), return_error_evidence: true)}
      ]

      unsafe_resets = [
        {"SECRETCONFIGKVSENTINEL", Adapter.reset("s3 SECRETCONFIGKVSENTINEL", evidence_opts)},
        {"CONTROL\u0001MARK", Adapter.reset("s3 CONTROL\u0001MARK", evidence_opts)},
        {String.duplicate("A", 129),
         Adapter.reset("s3 #{String.duplicate("A", 129)}", evidence_opts)}
      ]

      assert {:error,
              %{
                reason: {:config_generic, "unknown subsystem: S3"},
                subsystem: "S3",
                key_count: 0,
                stage: :exposure
              }} = safe_get

      assert {:error,
              %{
                reason: {:config_not_found, "key ABSENT doesn't exist"},
                subsystem: "s3",
                key_count: 1,
                stage: :exposure
              }} = safe_reset

      for {submitted, result} <- unsafe_gets do
        assert {:error, %{reason: :config_generic, subsystem: "unknown"}} = result
        refute inspect(result) =~ submitted
      end

      for {submitted, result} <- unsafe_resets do
        assert {:error, %{reason: :config_not_found, subsystem: "s3"}} = result
        refute inspect(result) =~ submitted
      end
    end
  end

  describe "atomic mutation adaptation" do
    test "multi-line overwrite folds to the final typed scalar and mutates once" do
      # Catches eager first-line validation, per-line Config calls, or a first-line-wins fold.
      assert {:ok, %{committed?: true, changed_count: 1}} =
               Adapter.set(
                 "s3 clock_skew_ms=not-an-integer\ns3 clock_skew_ms=2000",
                 mutation_opts(request_id: "req-final-fold")
               )

      assert ConfigBatchFailureRepo.observations() == %{
               transactions: 1,
               query_calls: 1,
               advisory_locks: 1
             }

      assert Repo.one(
               from row in RuntimeConfig,
                 where: row.subsystem == "s3" and row.key == "clock_skew_ms",
                 select: {row.value, row.version}
             ) == {%{"v" => 2000}, 1}

      assert Repo.one(
               from audit in RuntimeConfigAudit,
                 select: {audit.operation, audit.new_value, audit.request_id}
             ) == {"set", %{"v" => 2000}, "req-final-fold"}
    end

    test "invalid final scalar is rejected before the mutation lock" do
      # Catches a per-line write where the first legal scalar commits before the final scalar is
      # parsed, or validation that begins the DB coordinator needlessly.
      assert {:error, :config_bad_json} =
               Adapter.set(
                 "s3 clock_skew_ms=1000\ns3 clock_skew_ms=not-an-integer",
                 mutation_opts()
               )

      assert ConfigBatchFailureRepo.observations() == %{
               transactions: 0,
               query_calls: 0,
               advisory_locks: 0
             }

      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
    end

    test "full reset expands only Admin-exposed keys" do
      # Catches reset expansion from core Schema.keys/0, which would touch a hidden or forbidden
      # row merely because it shares the exposed s3 subsystem.
      insert_runtime!("s3", "root_user", "hidden-root", 7)

      assert {:ok, _result} =
               Config.set(:s3, :clock_skew_ms, 2_000, source: "admin_api")

      Repo.delete_all(RuntimeConfigAudit)

      assert {:ok, %{committed?: true, changed_count: 1}} =
               Adapter.reset("s3", mutation_opts(request_id: "req-exposed-reset"))

      assert Repo.all(
               from row in RuntimeConfig,
                 where: row.subsystem == "s3",
                 order_by: [asc: row.key],
                 select: {row.key, row.value, row.version}
             ) == [{"root_user", %{"v" => "hidden-root"}, 7}]

      assert Repo.all(
               from audit in RuntimeConfigAudit,
                 select: {audit.key, audit.operation, audit.request_id}
             ) == [{"clock_skew_ms", "reset", "req-exposed-reset"}]
    end

    test "repeated full reset is a committed no-op without audit version or postcommit work" do
      # Catches duplicate-full-reset rejection, a manufactured reset version/audit, or callbacks
      # that run despite changed_count=0.
      start_supervised!({ConfigPostcommitStore, owner: self()})
      start_supervised!({ConfigPostcommitNotify, owner: self()})

      opts =
        mutation_opts(
          store: ConfigPostcommitStore,
          notify: ConfigPostcommitNotify,
          request_id: "req-reset-retry"
        )

      for plaintext <- ["s3\ns3\n", "s3"] do
        assert {:ok,
                %{
                  committed?: true,
                  changed_count: 0,
                  local_reload: :not_needed,
                  broadcast: :not_needed,
                  attention?: false
                }} = Adapter.reset(plaintext, opts)
      end

      assert Repo.aggregate(RuntimeConfig, :count) == 0
      assert Repo.aggregate(RuntimeConfigAudit, :count) == 0
      assert ConfigPostcommitStore.observations().reload_calls == []
      assert ConfigPostcommitStore.observations().attention_calls == []
      assert ConfigPostcommitNotify.observations() == %{checked_calls: [], legacy_calls: []}
    end

    test "one request audit context is copied unchanged to the committed row" do
      # Catches regenerated per-key request IDs or dropped principal/access-key/source fields.
      assert {:ok, %{changed_count: 1}} =
               Adapter.set(
                 "listing sql_hard_limit=4242",
                 mutation_opts(
                   request_id: "req-admin-kvs-42",
                   principal_arn: "arn:aws:iam:::user/operator",
                   access_key_id: "AKIA-OPERATOR"
                 )
               )

      assert Repo.one(
               from audit in RuntimeConfigAudit,
                 select: %{
                   request_id: audit.request_id,
                   principal_arn: audit.principal_arn,
                   access_key_id: audit.access_key_id,
                   source: audit.source
                 }
             ) == %{
               request_id: "req-admin-kvs-42",
               principal_arn: "arn:aws:iam:::user/operator",
               access_key_id: "AKIA-OPERATOR",
               source: "admin_api"
             }
    end
  end

  describe "authoritative GET" do
    test "GET synchronously reconciles a stale snapshot before projecting through Config" do
      # Catches projection from a cached value after a missed invalidation broadcast.
      assert {:ok, _result} =
               Config.set(:listing, :sql_hard_limit, 111, source: "admin_api")

      {1, nil} =
        Repo.update_all(
          from(row in RuntimeConfig,
            where: row.subsystem == "listing" and row.key == "sql_hard_limit"
          ),
          set: [value: %{"v" => 999}]
        )

      assert Config.get(:listing, :sql_hard_limit) == 111
      assert Store.drifted?() == true

      assert {:ok, %{plaintext: plaintext}} = Adapter.get("listing")
      assert IO.iodata_to_binary(plaintext) == "listing sql_hard_limit=999 \n"
      assert Config.get(:listing, :sql_hard_limit) == 999
      assert Store.meta().last_reload_reason == :reconcile
      assert Store.drifted?() == false
    end

    test "GET returns a safe store reason instead of cached plaintext when authority fails" do
      # Catches rescue-to-cache behavior and raw DB exception disclosure.
      assert {:ok, _result} =
               Config.set(:listing, :sql_hard_limit, 111, source: "admin_api")

      assert Config.get(:listing, :sql_hard_limit) == 111

      assert {:error, {:config_store_unavailable, safe_reason}} =
               Adapter.get("listing", repo: ConfigMissingQueryRepo)

      assert is_atom(safe_reason)
      refute Atom.to_string(safe_reason) =~ "111"
    end

    test "GET serializes only approved non-sensitive entries and keeps exact tail bytes" do
      # Catches projection of hidden/sensitive registry material before Parser.render/2.
      secret_marker = "DEPLOYMENT-SHOULD-NOT-SERIALIZE"
      insert_runtime!("cluster", "deployment_id", secret_marker, 1)
      Store.load_all!()

      refute Enum.any?(Registry.entries(), & &1.sensitive?)

      assert {:ok, %{plaintext: plaintext}} = Adapter.get("s3")
      binary = IO.iodata_to_binary(plaintext)

      assert binary == "s3 clock_skew_ms=900000 \n"
      assert String.ends_with?(binary, <<32, 10>>)
      refute binary =~ secret_marker
      refute binary =~ "deployment_id"
    end
  end

  defp mutation_opts(overrides \\ []) do
    [
      source: "admin_api",
      principal_arn: "arn:aws:iam:::root",
      access_key_id: "AKIA-ADMIN-KVS",
      request_id: "req-admin-kvs",
      repo: ConfigBatchFailureRepo
    ]
    |> Keyword.merge(overrides)
  end

  defp insert_runtime!(subsystem, key, value, version) do
    %RuntimeConfig{}
    |> RuntimeConfig.changeset(%{
      subsystem: subsystem,
      key: key,
      value: %{"v" => value},
      version: version,
      apply_mode: "hot",
      source: "admin_api"
    })
    |> Repo.insert!()
  end
end
