defmodule MaxioWeb.StsSessionLiveTest do
  use MaxioWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Maxio.IAM
  alias Maxio.IAM.{STSSession, STSSessionSecret, User}
  alias Maxio.Auth.SessionToken
  alias Maxio.Repo
  alias Maxio.STS

  setup %{conn: conn} do
    {:ok, conn: log_in_console(conn)}
  end

  test "mounts STS session list and forms", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    assert has_element?(view, "#sts-sessions")
    assert has_element?(view, "#sts-sessions-empty")
    assert has_element?(view, "#create-sts-session-form")
    assert has_element?(view, "#create-sts-session-submit")
    assert has_element?(view, "#assume-role-session-form")
    assert has_element?(view, "#assume-role-session-submit")
    assert has_element?(view, "#sts-session-filter-form")
  end

  test "issues a session and shows one-time credentials", %{conn: conn} do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("CONSOLEISSUE"), secret_key: "issuer-secret")

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#create-sts-session-form",
      session: %{
        issuer_access_key_id: issuer.access_key_id,
        duration_seconds: "900",
        session_name: "console-session"
      }
    )
    |> render_submit()

    assert has_element?(view, "#sts-new-secret-banner")

    [session] = STS.list_sessions(issuer_access_key_id: issuer.access_key_id)
    row = Repo.get_by!(STSSession, access_key_id: session.access_key_id)
    suffix = dom_suffix(session.access_key_id)
    banner_html = view |> element("#sts-new-secret-banner") |> render()

    assert has_element?(view, "#sts-session-#{suffix}")
    assert has_element?(view, "#sts-session-status-#{suffix}.badge-success")
    assert banner_html =~ session.access_key_id
    refute banner_html =~ row.secret_key
    assert STSSessionSecret.encrypted?(row.secret_key)
    assert [_, secret_key] = Regex.run(~r/SecretAccessKey:\s*([^<\s]+)/, banner_html)
    assert {:ok, ^secret_key} = STSSessionSecret.unwrap(row.secret_key, session.access_key_id)
    assert [_, session_token] = Regex.run(~r/SessionToken:\s*([^<\s]+)/, banner_html)
    assert SessionToken.hash(session_token) == row.session_token_sha256
    refute Map.has_key?(session, :secret_key)
    refute Map.has_key?(session, :session_token)
    refute Map.has_key?(session, :session_token_sha256)

    {:ok, remounted, _html} = live(conn, ~p"/sts-sessions")
    refute has_element?(remounted, "#sts-new-secret-banner")
  end

  test "session list does not render persisted secret material", %{conn: conn} do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("CONSOLELEAK"), secret_key: "issuer-secret")

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        session_access_key_id: unique_session_ak("CONSOLELEAK"),
        secret_key: "console-session-secret",
        session_token: "console-session-token",
        duration_seconds: 900
      )

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")
    assert has_element?(view, "#sts-session-#{dom_suffix(session.access_key_id)}")

    list_html = view |> element("#sts-sessions") |> render()
    refute list_html =~ "console-session-secret"
    refute list_html =~ "console-session-token"
    refute list_html =~ "session_token_sha256"
  end

  test "assumes an IAM role from the console and shows one-time credentials", %{conn: conn} do
    {:ok, caller} =
      IAM.create_access_key(
        access_key_id: unique_ak("CONSOLEASSUME"),
        secret_key: "caller-secret"
      )

    role_name = unique_name("console-assume-role")

    {:ok, role} =
      IAM.create_role(
        role_name: role_name,
        trust_policy: trust_policy(caller.principal_arn)
      )

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#assume-role-session-form",
      assume_role: %{
        caller_access_key_id: caller.access_key_id,
        role_arn: role.role_arn,
        session_name: "console-role-session",
        duration_seconds: "900",
        external_id: "",
        source_identity: "",
        mfa_serial: "",
        mfa_token_code: "",
        session_tags: "",
        transitive_tag_keys: "",
        policy_arns: "",
        session_policy: ""
      }
    )
    |> render_submit()

    assert has_element?(view, "#sts-new-secret-banner")

    [session] = STS.list_sessions(issuer_access_key_id: caller.access_key_id)
    row = Repo.get_by!(STSSession, access_key_id: session.access_key_id)
    suffix = dom_suffix(session.access_key_id)
    banner_html = view |> element("#sts-new-secret-banner") |> render()

    assert session.principal_type == "assumed_role"
    assert session.principal_arn == role.role_arn
    assert session.session_name == "console-role-session"
    assert has_element?(view, "#sts-session-#{suffix}")
    assert has_element?(view, "#sts-session-status-#{suffix}.badge-success")
    assert banner_html =~ session.access_key_id
    assert banner_html =~ STS.assumed_role_arn(role.role_arn, "console-role-session")
    refute banner_html =~ row.secret_key
    assert STSSessionSecret.encrypted?(row.secret_key)
    assert [_, secret_key] = Regex.run(~r/SecretAccessKey:\s*([^<\s]+)/, banner_html)
    assert {:ok, ^secret_key} = STSSessionSecret.unwrap(row.secret_key, session.access_key_id)
    assert [_, session_token] = Regex.run(~r/SessionToken:\s*([^<\s]+)/, banner_html)
    assert SessionToken.hash(session_token) == row.session_token_sha256
    refute Map.has_key?(session, :secret_key)
    refute Map.has_key?(session, :session_token)
    refute Map.has_key?(session, :session_token_sha256)
  end

  test "assume role form forwards advanced trust and session policy parameters", %{conn: conn} do
    {:ok, caller} =
      IAM.create_access_key(
        access_key_id: unique_ak("CONSOLEADVROOT"),
        secret_key: "caller-secret",
        type: "root"
      )

    {:ok, policy} =
      IAM.create_managed_policy(
        name: unique_name("console-session-boundary"),
        path: "/console/",
        policy: allow_list_buckets_policy()
      )

    role_name = unique_name("console-advanced-role")

    {:ok, role} =
      IAM.create_role(
        role_name: role_name,
        trust_policy:
          trust_policy(caller.principal_arn,
            actions: ["sts:AssumeRole", "sts:SetSourceIdentity", "sts:TagSession"],
            conditions: %{
              "StringEquals" => %{
                "sts:ExternalId" => "external-123",
                "sts:SourceIdentity" => "pipeline",
                "aws:RequestTag/team" => "platform"
              },
              "ForAllValues:StringEquals" => %{"aws:TagKeys" => ["team"]}
            }
          )
      )

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#assume-role-session-form",
      assume_role: %{
        caller_access_key_id: caller.access_key_id,
        role_arn: role.role_arn,
        session_name: "advanced-session",
        duration_seconds: "900",
        external_id: "external-123",
        source_identity: "pipeline",
        mfa_serial: "",
        mfa_token_code: "",
        session_tags: "team=platform",
        transitive_tag_keys: "team",
        policy_arns: policy.policy_arn,
        session_policy: allow_list_buckets_policy()
      }
    )
    |> render_submit()

    [session] = STS.list_sessions(issuer_access_key_id: caller.access_key_id)

    assert session.principal_arn == role.role_arn
    assert session.source_identity == "pipeline"
    assert session.tags["team"] == "platform"
    assert session.transitive_tag_keys == ["team"]
    assert %{"Statement" => statements} = session.session_policy
    assert length(statements) == 2
  end

  test "revokes active sessions from the console", %{conn: conn} do
    {:ok, issuer} =
      IAM.create_access_key(
        access_key_id: unique_ak("CONSOLEREVOKE"),
        secret_key: "issuer-secret"
      )

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        session_access_key_id: unique_session_ak("CONSOLEREVOKE"),
        duration_seconds: 900
      )

    suffix = dom_suffix(session.access_key_id)

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")
    assert has_element?(view, "#revoke-sts-session-#{suffix}")

    view |> element("#revoke-sts-session-#{suffix}") |> render_click()

    assert has_element?(view, "#sts-session-status-#{suffix}.badge-warning")
    assert has_element?(view, "#sts-session-revoked-#{suffix}")
    refute has_element?(view, "#revoke-sts-session-#{suffix}")

    [revoked] = STS.list_sessions(issuer_access_key_id: issuer.access_key_id)
    assert revoked.status == "revoked"
    assert revoked.revoked_at
  end

  test "filters sessions by issuer access key and clears filters", %{conn: conn} do
    {:ok, issuer_one} =
      IAM.create_access_key(access_key_id: unique_ak("CONSOLEFLT1"), secret_key: "issuer-secret")

    {:ok, issuer_two} =
      IAM.create_access_key(access_key_id: unique_ak("CONSOLEFLT2"), secret_key: "issuer-secret")

    {:ok, session_one} =
      STS.issue_session(
        issuer_access_key_id: issuer_one.access_key_id,
        session_access_key_id: unique_session_ak("CONSOLEFLT1"),
        duration_seconds: 900
      )

    {:ok, session_two} =
      STS.issue_session(
        issuer_access_key_id: issuer_two.access_key_id,
        session_access_key_id: unique_session_ak("CONSOLEFLT2"),
        duration_seconds: 900
      )

    suffix_one = dom_suffix(session_one.access_key_id)
    suffix_two = dom_suffix(session_two.access_key_id)

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")
    assert has_element?(view, "#sts-session-#{suffix_one}")
    assert has_element?(view, "#sts-session-#{suffix_two}")

    view
    |> form("#sts-session-filter-form",
      filter: %{issuer_access_key_id: issuer_one.access_key_id, principal_arn: ""}
    )
    |> render_submit()

    assert has_element?(view, "#sts-session-#{suffix_one}")
    refute has_element?(view, "#sts-session-#{suffix_two}")

    view |> element("#sts-session-filter-clear") |> render_click()

    assert has_element?(view, "#sts-session-#{suffix_one}")
    assert has_element?(view, "#sts-session-#{suffix_two}")
  end

  test "filters sessions by principal ARN", %{conn: conn} do
    user_one_name = unique_name("console-principal-one")
    user_two_name = unique_name("console-principal-two")
    {:ok, _user_one} = IAM.create_user(name: user_one_name)
    {:ok, _user_two} = IAM.create_user(name: user_two_name)

    {:ok, issuer_one} =
      IAM.create_access_key(
        access_key_id: unique_ak("CONSOLEARN1"),
        secret_key: "issuer-secret",
        user_name: user_one_name
      )

    {:ok, issuer_two} =
      IAM.create_access_key(
        access_key_id: unique_ak("CONSOLEARN2"),
        secret_key: "issuer-secret",
        user_name: user_two_name
      )

    {:ok, session_one} =
      STS.issue_session(
        issuer_access_key_id: issuer_one.access_key_id,
        session_access_key_id: unique_session_ak("CONSOLEARN1"),
        duration_seconds: 900
      )

    {:ok, session_two} =
      STS.issue_session(
        issuer_access_key_id: issuer_two.access_key_id,
        session_access_key_id: unique_session_ak("CONSOLEARN2"),
        duration_seconds: 900
      )

    suffix_one = dom_suffix(session_one.access_key_id)
    suffix_two = dom_suffix(session_two.access_key_id)

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#sts-session-filter-form",
      filter: %{issuer_access_key_id: "", principal_arn: issuer_one.principal_arn}
    )
    |> render_submit()

    assert has_element?(view, "#sts-session-#{suffix_one}")
    refute has_element?(view, "#sts-session-#{suffix_two}")
  end

  test "rejects invalid issue params without creating sessions", %{conn: conn} do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("CONSOLEBAD"), secret_key: "issuer-secret")

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#create-sts-session-form",
      session: %{
        issuer_access_key_id: issuer.access_key_id,
        duration_seconds: "899",
        session_name: "bad-duration"
      }
    )
    |> render_submit()

    assert has_element?(view, "#sts-sessions-empty")
    assert [] = STS.list_sessions(issuer_access_key_id: issuer.access_key_id)
  end

  test "rejects a caller access key whose principal type is not a long-term identity",
       %{conn: conn} do
    # 本例钉的是**上游关卡**，不是 `Index.caller_principal_type/1`（那里已无兜底分支）：
    # 非长期凭据在 `IAM.get_active_access_key_principal/1` 就被
    # `public_active_access_key_principal(%AccessKey{})` 的总括子句拒成 `:error`，
    # 压根到不了 LiveView 的类型判定。`AccessKey.changeset/2` 的
    # `validate_inclusion(:type, ["root", "iam_user"])` 挡住了正常写入路径，所以这里绕过
    # changeset 直接篡改 `type` 列造出这种凭据，先断言上游返回 `:error`，再断言控制台
    # **不会**为它签发扮演角色会话（AGENTS.md §3 失败必须结构化拒绝）。
    {:ok, caller} =
      IAM.create_access_key(
        access_key_id: unique_ak("CONSOLENOTLONGTERM"),
        secret_key: "caller-secret"
      )

    {:ok, role} =
      IAM.create_role(
        role_name: unique_name("console-not-long-term-role"),
        trust_policy: trust_policy(caller.principal_arn)
      )

    Maxio.IAM.AccessKey
    |> Repo.get_by!(access_key_id: caller.access_key_id)
    |> Ecto.Changeset.change(%{type: "sts_session"})
    |> Repo.update!()

    assert :error = IAM.get_active_access_key_principal(caller.access_key_id)

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#assume-role-session-form",
      assume_role: %{
        caller_access_key_id: caller.access_key_id,
        role_arn: role.role_arn,
        session_name: "not-long-term-session",
        duration_seconds: "900",
        external_id: "",
        source_identity: "",
        mfa_serial: "",
        mfa_token_code: "",
        session_tags: "",
        transitive_tag_keys: "",
        policy_arns: "",
        session_policy: ""
      }
    )
    |> render_submit()

    assert has_element?(view, "#sts-sessions-empty")
    refute has_element?(view, "#sts-new-secret-banner")
    assert [] = STS.list_sessions(principal_arn: role.role_arn)
    assert [] = STS.list_sessions(issuer_access_key_id: caller.access_key_id)
  end

  test "rejects invalid assume role params without creating sessions", %{conn: conn} do
    {:ok, role} =
      IAM.create_role(
        role_name: unique_name("console-bad-assume-role"),
        trust_policy: trust_policy(IAM.root_principal_arn())
      )

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#assume-role-session-form",
      assume_role: %{
        caller_access_key_id: unique_ak("MISSINGCALLER"),
        role_arn: role.role_arn,
        session_name: "bad-session",
        duration_seconds: "900",
        external_id: "",
        source_identity: "",
        mfa_serial: "",
        mfa_token_code: "",
        session_tags: "",
        transitive_tag_keys: "",
        policy_arns: "",
        session_policy: ""
      }
    )
    |> render_submit()

    assert has_element?(view, "#sts-sessions-empty")
    assert [] = STS.list_sessions(principal_arn: role.role_arn)
  end

  test "rejects invalid assume role MFA params without creating sessions", %{conn: conn} do
    {:ok, caller} =
      IAM.create_access_key(
        access_key_id: unique_ak("CONSOLEBADMFA"),
        secret_key: "caller-secret"
      )

    {:ok, role} =
      IAM.create_role(
        role_name: unique_name("console-bad-mfa-role"),
        trust_policy: trust_policy(caller.principal_arn)
      )

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#assume-role-session-form",
      assume_role: %{
        caller_access_key_id: caller.access_key_id,
        role_arn: role.role_arn,
        session_name: "bad-mfa-session",
        duration_seconds: "900",
        external_id: "",
        source_identity: "",
        mfa_serial: "arn:aws:iam:::mfa/root",
        mfa_token_code: "abcdef",
        session_tags: "",
        transitive_tag_keys: "",
        policy_arns: "",
        session_policy: ""
      }
    )
    |> render_submit()

    assert has_element?(view, "#sts-sessions-empty")
    assert [] = STS.list_sessions(issuer_access_key_id: caller.access_key_id)
  end

  test "rejects assume role callers bound to inactive IAM users", %{conn: conn} do
    user_name = unique_name("console-inactive-caller")
    {:ok, _user} = IAM.create_user(name: user_name)

    {:ok, caller} =
      IAM.create_access_key(
        access_key_id: unique_ak("CONSOLEINACTIVE"),
        secret_key: "caller-secret",
        user_name: user_name
      )

    caller.principal_arn
    |> then(&Repo.get_by!(User, user_arn: &1))
    |> Ecto.Changeset.change(status: "inactive")
    |> Repo.update!()

    {:ok, role} =
      IAM.create_role(
        role_name: unique_name("console-inactive-caller-role"),
        trust_policy: trust_policy(caller.principal_arn)
      )

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#assume-role-session-form",
      assume_role: %{
        caller_access_key_id: caller.access_key_id,
        role_arn: role.role_arn,
        session_name: "inactive-caller",
        duration_seconds: "900",
        external_id: "",
        source_identity: "",
        mfa_serial: "",
        mfa_token_code: "",
        session_tags: "",
        transitive_tag_keys: "",
        policy_arns: "",
        session_policy: ""
      }
    )
    |> render_submit()

    refute has_element?(view, "#sts-new-secret-banner")
    assert [] = STS.list_sessions(issuer_access_key_id: caller.access_key_id)
  end

  test "malformed events clear one-time secret banner", %{conn: conn} do
    {:ok, issuer} =
      IAM.create_access_key(
        access_key_id: unique_ak("CONSOLECLEAR"),
        secret_key: "issuer-secret"
      )

    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    view
    |> form("#create-sts-session-form",
      session: %{
        issuer_access_key_id: issuer.access_key_id,
        duration_seconds: "900",
        session_name: "clear-session"
      }
    )
    |> render_submit()

    assert has_element?(view, "#sts-new-secret-banner")

    render_click(view, "assume_role", %{})

    refute has_element?(view, "#sts-new-secret-banner")
  end

  test "stale revoke events do not crash", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/sts-sessions")

    render_click(view, "revoke_session", %{"access-key-id" => unique_session_ak("MISSING")})
    render_click(view, "revoke_session", %{})

    assert has_element?(view, "#sts-sessions")
  end

  defp unique_ak(prefix), do: "AKIA#{prefix}#{System.unique_integer([:positive])}"
  defp unique_session_ak(prefix), do: "ASIA#{prefix}#{System.unique_integer([:positive])}"
  defp unique_name(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp dom_suffix(value), do: Base.encode16(to_string(value), case: :lower)

  defp trust_policy(principal_arn, opts \\ []) do
    statement =
      %{
        "Effect" => "Allow",
        "Principal" => %{"AWS" => principal_arn},
        "Action" => Keyword.get(opts, :actions, "sts:AssumeRole")
      }
      |> maybe_put_condition(Keyword.get(opts, :conditions))

    Jason.encode!(%{"Version" => "2012-10-17", "Statement" => statement})
  end

  defp maybe_put_condition(statement, nil), do: statement
  defp maybe_put_condition(statement, conditions), do: Map.put(statement, "Condition", conditions)

  defp allow_list_buckets_policy do
    ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:ListAllMyBuckets","Resource":"*"}})
  end
end
