defmodule Maxio.STSTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.Auth.SessionToken
  alias Maxio.IAM
  alias Maxio.IAM.{STSSession, STSSessionSecret, User}
  alias Maxio.Policy.{Evaluator, RequestContext, Statement}
  alias Maxio.STS

  test "issue_session stores encrypted secret, token hash and list_sessions hides secrets" do
    {:ok, issuer} =
      IAM.create_access_key(
        access_key_id: unique_ak("ISSUER"),
        secret_key: "issuer-secret",
        tags: %{"team" => "platform"}
      )

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        session_access_key_id: unique_session_ak("ISSUE"),
        secret_key: "session-secret",
        session_token: "session-token",
        session_name: "test-session",
        duration_seconds: 900
      )

    assert session.secret_key == "session-secret"
    assert session.session_token == "session-token"
    assert session.principal_arn == issuer.principal_arn

    row = Repo.get_by!(STSSession, access_key_id: session.access_key_id)
    refute row.secret_key == "session-secret"
    assert STSSessionSecret.encrypted?(row.secret_key)

    assert {:ok, "session-secret"} =
             STSSessionSecret.unwrap(row.secret_key, session.access_key_id)

    assert {:error, :sts_session_secret_decrypt_failed} =
             STSSessionSecret.unwrap(row.secret_key, unique_session_ak("OTHER"))

    assert row.session_token_sha256 == SessionToken.hash("session-token")
    refute inspect(row) =~ "session-token"
    refute inspect(row) =~ "session-secret"

    [public] = STS.list_sessions(issuer_access_key_id: issuer.access_key_id)
    refute Map.has_key?(public, :secret_key)
    refute Map.has_key?(public, :session_token)
    refute Map.has_key?(public, :session_token_sha256)
    assert public.access_key_id == session.access_key_id
  end

  test "EctoStore validates session token, expiry and revocation fail-closed" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("STORE"), secret_key: "issuer-secret")

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        session_access_key_id: unique_session_ak("STORE"),
        secret_key: "session-secret",
        session_token: "session-token",
        duration_seconds: 900
      )

    now = DateTime.add(session.issued_at, 1, :second)
    issuer_access_key_id = issuer.access_key_id
    session_access_key_id = session.access_key_id

    assert {:error, :missing_session_token} =
             EctoStore.get_secret(session.access_key_id, now: now)

    assert {:error, :invalid_token} =
             EctoStore.get_secret(session.access_key_id,
               session_token: "wrong",
               now: now
             )

    assert {:ok,
            %{
              secret_key: "session-secret",
              principal: %{
                access_key: ^issuer_access_key_id,
                credential_type: :session,
                session_access_key: ^session_access_key_id
              }
            }} =
             EctoStore.get_secret(session.access_key_id,
               session_token: "session-token",
               now: now
             )

    assert {:ok, _revoked} = STS.revoke_session(session.access_key_id)

    assert {:error, :invalid_token} =
             EctoStore.get_secret(session.access_key_id,
               session_token: "session-token",
               now: now
             )
  end

  test "access_key_account_id identifies long-term and temporary keys without exposing state" do
    {:ok, inactive} =
      IAM.create_access_key(
        access_key_id: unique_ak("INFOINACTIVE"),
        secret_key: "issuer-secret",
        status: "inactive"
      )

    assert {:ok, STS.account_id()} == STS.access_key_account_id(inactive.access_key_id)

    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("INFOISSUER"), secret_key: "issuer-secret")

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        session_access_key_id: unique_session_ak("INFO"),
        secret_key: "session-secret",
        session_token: "session-token",
        duration_seconds: 900
      )

    assert {:ok, _revoked} = STS.revoke_session(session.access_key_id)
    assert {:ok, STS.account_id()} == STS.access_key_account_id(session.access_key_id)
    assert {:error, :access_key_not_found} = STS.access_key_account_id(unique_ak("MISSINGINFO"))
    assert {:error, :invalid_access_key_id} = STS.access_key_account_id("")
  end

  test "EctoStore reads legacy plaintext STS session secret rows" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("LEGACYSTS"), secret_key: "issuer-secret")

    session_access_key_id = unique_session_ak("LEGACY")

    insert_sts_session_row!(
      issuer,
      session_access_key_id,
      "legacy-session-secret",
      "legacy-session-token"
    )

    assert {:ok,
            %{
              secret_key: "legacy-session-secret",
              principal: %{session_access_key: ^session_access_key_id}
            }} =
             EctoStore.get_secret(session_access_key_id,
               session_token: "legacy-session-token",
               now: DateTime.utc_now()
             )
  end

  test "STS session secret envelopes honor configured key ring for rotation" do
    old_key = b64_secret("sts-old-key")
    new_key = b64_secret("sts-new-key")
    session_access_key_id = unique_session_ak("RINGREAD")

    with_access_key_secret_config([current_key_id: "sts-old", secret_key: old_key], fn ->
      {:ok, readable_envelope} =
        STSSessionSecret.wrap("readable-session-secret", session_access_key_id)

      assert sts_envelope_key_id(readable_envelope) == "sts-old"

      with_access_key_secret_config(
        [current_key_id: "sts-new", secret_key: new_key, keys: %{"sts-old" => old_key}],
        fn ->
          assert {:ok, "readable-session-secret"} =
                   STSSessionSecret.unwrap(readable_envelope, session_access_key_id)

          {:ok, new_envelope} =
            STSSessionSecret.wrap("new-session-secret", unique_session_ak("RINGNEW"))

          assert sts_envelope_key_id(new_envelope) == "sts-new"
        end
      )

      with_access_key_secret_config([current_key_id: "sts-new", secret_key: new_key], fn ->
        assert {:error, :sts_session_secret_key_not_configured} =
                 STSSessionSecret.unwrap(readable_envelope, session_access_key_id)
      end)
    end)
  end

  test "STS session secret envelopes reject unsupported or missing algorithm metadata" do
    session_access_key_id = unique_session_ak("ALG")
    {:ok, envelope} = STSSessionSecret.wrap("alg-session-secret", session_access_key_id)

    missing_alg = rewrite_sts_envelope(envelope, &Map.delete(&1, "alg"))
    wrong_alg = rewrite_sts_envelope(envelope, &Map.put(&1, "alg", "AES-128-GCM"))

    assert {:error, :invalid_sts_session_secret_envelope} =
             STSSessionSecret.unwrap(missing_alg, session_access_key_id)

    assert {:error, :invalid_sts_session_secret_envelope} =
             STSSessionSecret.unwrap(wrong_alg, session_access_key_id)
  end

  test "STS session secret envelopes reject undecodable base64 payloads" do
    # `Base.url_decode64/2` 用**裸 `:error`**（不是 `{:error, _}`）表示解码失败，
    # 这是 `unwrap/2` 与 `envelope_metadata/1` else 兜底子句唯一可达的入口。
    session_access_key_id = unique_session_ak("B64")
    corrupt = "maxio-sts-secret-v1:" <> "not*valid*base64url"

    assert STSSessionSecret.encrypted?(corrupt)

    assert {:error, :invalid_sts_session_secret_envelope} =
             STSSessionSecret.unwrap(corrupt, session_access_key_id)

    assert {:error, :invalid_sts_session_secret_envelope} =
             STSSessionSecret.envelope_metadata(corrupt)
  end

  test "STS session secret storage rejects empty secrets and fails closed for empty rows" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("EMPTYSTS"), secret_key: "issuer-secret")

    before_count = Repo.aggregate(STSSession, :count)

    assert {:error, :invalid_sts_session_secret} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: unique_session_ak("EMPTYHOOK"),
               secret_key: "",
               session_token: "session-token",
               duration_seconds: 900
             )

    assert Repo.aggregate(STSSession, :count) == before_count

    legacy_empty_id = unique_session_ak("EMPTYLEGACY")
    insert_sts_session_row!(issuer, legacy_empty_id, "", "legacy-empty-token")

    assert {:error, :invalid_token} =
             EctoStore.get_secret(legacy_empty_id,
               session_token: "legacy-empty-token",
               now: DateTime.utc_now()
             )

    encrypted_empty_id = unique_session_ak("EMPTYENC")

    insert_sts_session_row!(
      issuer,
      encrypted_empty_id,
      encrypted_sts_secret_for_test("", encrypted_empty_id),
      "encrypted-empty-token"
    )

    assert {:error, :invalid_token} =
             EctoStore.get_secret(encrypted_empty_id,
               session_token: "encrypted-empty-token",
               now: DateTime.utc_now()
             )
  end

  test "tampered encrypted STS session secret fails closed" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("TAMPERSTS"), secret_key: "issuer-secret")

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        session_access_key_id: unique_session_ak("TAMPERSTS"),
        secret_key: "session-secret",
        session_token: "session-token",
        duration_seconds: 900
      )

    row = Repo.get_by!(STSSession, access_key_id: session.access_key_id)

    row
    |> Ecto.Changeset.change(secret_key: row.secret_key <> "A")
    |> Repo.update!()

    assert {:error, :invalid_token} =
             EctoStore.get_secret(session.access_key_id,
               session_token: "session-token",
               now: DateTime.add(session.issued_at, 1, :second)
             )
  end

  test "explicit user deletion revokes STS sessions issued by that user" do
    user_name = unique_user("session-delete")
    {:ok, _user} = IAM.create_user(name: user_name)

    {:ok, issuer} =
      IAM.create_access_key(
        access_key_id: unique_ak("USRDEL"),
        secret_key: "issuer-secret",
        user_name: user_name
      )

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        session_access_key_id: unique_session_ak("USRDEL"),
        secret_key: "session-secret",
        session_token: "session-token",
        duration_seconds: 900
      )

    assert {:ok, _} =
             EctoStore.get_secret(session.access_key_id,
               session_token: "session-token",
               now: DateTime.add(session.issued_at, 1, :second)
             )

    assert :ok = IAM.delete_user(user_name)
    assert Repo.get_by!(STSSession, access_key_id: session.access_key_id).status == "revoked"

    assert {:error, :invalid_token} =
             EctoStore.get_secret(session.access_key_id,
               session_token: "session-token",
               now: DateTime.add(session.issued_at, 2, :second)
             )
  end

  test "explicit user inactivity prevents STS issuance and invalidates existing sessions" do
    user_name = unique_user("session-inactive")
    {:ok, user} = IAM.create_user(name: user_name)

    {:ok, issuer} =
      IAM.create_access_key(
        access_key_id: unique_ak("USRINACT"),
        secret_key: "issuer-secret",
        user_name: user_name
      )

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        session_access_key_id: unique_session_ak("USRINACT"),
        secret_key: "session-secret",
        session_token: "session-token",
        duration_seconds: 900
      )

    Repo.update_all(from(u in User, where: u.user_arn == ^user.user_arn),
      set: [status: "inactive"]
    )

    assert :error = EctoStore.get_secret(issuer.access_key_id)

    assert {:error, :issuer_access_key_not_found} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: unique_session_ak("USRINACT2"),
               duration_seconds: 900
             )

    assert {:error, :invalid_token} =
             EctoStore.get_secret(session.access_key_id,
               session_token: "session-token",
               now: DateTime.add(session.issued_at, 1, :second)
             )
  end

  test "EctoStore rejects expired sessions and long-term keys with token" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("EXP"), secret_key: "issuer-secret")

    {:ok, session} =
      STS.issue_session(
        issuer_access_key_id: issuer.access_key_id,
        session_access_key_id: unique_session_ak("EXP"),
        secret_key: "session-secret",
        session_token: "session-token",
        duration_seconds: 900
      )

    assert {:error, :expired_token} =
             EctoStore.get_secret(session.access_key_id,
               session_token: "session-token",
               now: DateTime.add(session.expires_at, 1, :second)
             )

    assert {:error, :invalid_token} =
             EctoStore.get_secret(issuer.access_key_id, session_token: "stale-token")
  end

  test "duration bounds follow root and IAM session caps" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("DUR"), secret_key: "issuer-secret")

    assert {:error, :invalid_session_duration} =
             STS.issue_session(issuer_access_key_id: issuer.access_key_id, duration_seconds: 899)

    assert {:ok, _session} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: unique_session_ak("DUR"),
               duration_seconds: 129_600
             )

    IAM.bootstrap_root()
    root_ak = Application.fetch_env!(:maxio, :s3) |> Keyword.fetch!(:root_user)

    assert {:error, :invalid_session_duration} =
             STS.issue_session(issuer_access_key_id: root_ak, duration_seconds: 3_601)
  end

  test "issue_session rejects key ids that collide with long-term or STS credentials" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("COLLIDE"), secret_key: "issuer-secret")

    long_term_key = unique_ak("EXISTING")

    {:ok, _existing} =
      IAM.create_access_key(access_key_id: long_term_key, secret_key: "existing-secret")

    assert {:error, :access_key_id_conflict} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: long_term_key,
               duration_seconds: 900
             )

    session_key = unique_session_ak("EXISTING")

    assert {:ok, _session} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: session_key,
               duration_seconds: 900
             )

    assert {:error, :access_key_id_conflict} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: session_key,
               duration_seconds: 900
             )

    assert {:ok, _revoked} = STS.revoke_session(session_key)

    assert {:error, :access_key_id_conflict} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: session_key,
               duration_seconds: 900
             )
  end

  test "issue_session insert errors are sanitized and do not leak secret material" do
    {:ok, issuer} =
      IAM.create_access_key(access_key_id: unique_ak("LEAK"), secret_key: "issuer-secret")

    assert {:error, errors} =
             STS.issue_session(
               issuer_access_key_id: issuer.access_key_id,
               session_access_key_id: "ASIASHORT",
               secret_key: "session-secret-leak",
               session_token: "session-token-leak",
               session_name: "",
               duration_seconds: 900
             )

    inspected = inspect(errors)
    refute inspected =~ "session-secret-leak"
    refute inspected =~ "session-token-leak"
    refute inspected =~ "session_token_sha256"
  end

  test "assume_role_with_web_identity issues assumed-role credentials without access-key issuer" do
    issuer = "https://core.oidc.example.test/tenant"
    {:ok, provider_arn} = STS.WebIdentity.oidc_provider_arn(issuer)
    {:ok, issuer_host_path} = STS.WebIdentity.issuer_host_path(issuer)
    subject = "core-subject"
    audience = "sts.amazonaws.com"

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("webid-core"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"Federated" => provider_arn},
            "Action" => "sts:AssumeRoleWithWebIdentity",
            "Condition" => %{
              "StringEquals" => %{
                "#{issuer_host_path}:sub" => subject,
                "#{issuer_host_path}:aud" => audience
              }
            }
          }
        }
      )

    web_identity = %{
      issuer: issuer,
      issuer_host_path: issuer_host_path,
      provider_arn: provider_arn,
      provider: issuer,
      subject: subject,
      subject_sha256: sha256_hex(subject),
      audience: audience,
      audiences: [audience],
      claims: %{}
    }

    assert {:ok, session} =
             STS.assume_role_with_web_identity(role, web_identity,
               session_name: "webid-core",
               duration_seconds: 900,
               session_access_key_id: unique_session_ak("WEBIDCORE"),
               secret_key: "webid-secret",
               session_token: "webid-token"
             )

    assert session.role_arn == role.role_arn
    assert session.web_identity_provider_arn == provider_arn
    assert session.web_identity_subject_sha256 == sha256_hex(subject)

    row = Repo.get_by!(STSSession, access_key_id: session.access_key_id)
    assert row.issuer_access_key_id == nil
    assert row.principal_arn == role.role_arn
    assert row.principal_type == "assumed_role"
    assert row.web_identity_provider_arn == provider_arn
  end

  test "assume_role_with_web_identity core maps flat JWT tag claims and gates TagSession" do
    issuer = "https://flat-tags.oidc.example.test/tenant"
    {:ok, provider_arn} = STS.WebIdentity.oidc_provider_arn(issuer)
    {:ok, issuer_host_path} = STS.WebIdentity.issuer_host_path(issuer)
    subject = "flat-tag-subject"
    audience = "sts.amazonaws.com"

    web_identity = %{
      issuer: issuer,
      issuer_host_path: issuer_host_path,
      provider_arn: provider_arn,
      provider: issuer,
      subject: subject,
      subject_sha256: sha256_hex(subject),
      audience: audience,
      audiences: [audience],
      claims: %{
        "https://aws.amazon.com/tags/principal_tags/team" => "platform",
        "https://aws.amazon.com/tags/transitive_tag_keys" => ["team"]
      }
    }

    {:ok, denied_role} =
      IAM.create_role(
        role_name: unique_role("webid-direct-tags-denied"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"Federated" => provider_arn},
            "Action" => "sts:AssumeRoleWithWebIdentity",
            "Condition" => %{
              "StringEquals" => %{
                "#{issuer_host_path}:sub" => subject,
                "#{issuer_host_path}:aud" => audience,
                "aws:RequestTag/team" => "platform"
              }
            }
          }
        }
      )

    assert {:error, {:tag_session_denied, :implicit_deny}} =
             STS.assume_role_with_web_identity(denied_role, web_identity,
               session_name: "flat-tags-denied",
               duration_seconds: 900
             )

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("webid-direct-tags"),
        tags: %{"project" => "storage", "team" => "role-team"},
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"Federated" => provider_arn},
            "Action" => ["sts:AssumeRoleWithWebIdentity", "sts:TagSession"],
            "Condition" => %{
              "StringEquals" => %{
                "#{issuer_host_path}:sub" => subject,
                "#{issuer_host_path}:aud" => audience,
                "aws:RequestTag/team" => "platform",
                "sts:TransitiveTagKeys" => "team"
              }
            }
          }
        }
      )

    assert {:ok, session} =
             STS.assume_role_with_web_identity(role, web_identity,
               session_name: "flat-tags",
               duration_seconds: 900,
               session_access_key_id: unique_session_ak("FLATTAG")
             )

    assert session.tags == %{"project" => "storage", "team" => "platform"}
    assert session.transitive_tag_keys == ["team"]

    row = Repo.get_by!(STSSession, access_key_id: session.access_key_id)
    assert row.tags == %{"project" => "storage", "team" => "platform"}
    assert row.transitive_tag_keys == ["team"]

    invalid_web_identity =
      put_in(web_identity, [:claims, "https://aws.amazon.com/tags/transitive_tag_keys"], [
        "missing"
      ])

    assert {:error, :invalid_transitive_tag_keys} =
             STS.assume_role_with_web_identity(role, invalid_web_identity,
               session_name: "flat-tags-invalid",
               duration_seconds: 900
             )
  end

  test "assume_role_with_web_identity rejects malformed direct web identity input" do
    issuer = "https://direct.oidc.example.test/tenant"
    {:ok, provider_arn} = STS.WebIdentity.oidc_provider_arn(issuer)
    {:ok, issuer_host_path} = STS.WebIdentity.issuer_host_path(issuer)
    subject = "direct-subject"
    audience = "sts.amazonaws.com"

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("webid-direct"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"Federated" => provider_arn},
            "Action" => "sts:AssumeRoleWithWebIdentity"
          }
        }
      )

    forged_identity = %{
      issuer: issuer,
      issuer_host_path: issuer_host_path,
      provider_arn: "arn:aws:iam:::oidc-provider/attacker.example.test",
      provider: issuer,
      subject: subject,
      subject_sha256: sha256_hex(subject),
      audience: audience,
      audiences: [audience],
      claims: %{}
    }

    assert {:error, :invalid_web_identity} =
             STS.assume_role_with_web_identity(role, forged_identity,
               session_name: "webid-direct",
               duration_seconds: 900
             )

    # normalize_web_identity/1 只保证 claims 非 nil（`|| %{}`），不保证是 map。
    # 非 map 的 claims 必须被 web_identity_claims/1 这道唯一关卡结构化拒绝，
    # 而不是漏进 source-identity / session-tag 解析里。
    for bad_claims <- ["not-a-map", ["sub"], 7] do
      non_map_claims = %{
        issuer: issuer,
        issuer_host_path: issuer_host_path,
        provider_arn: provider_arn,
        provider: issuer,
        subject: subject,
        subject_sha256: sha256_hex(subject),
        audience: audience,
        audiences: [audience],
        claims: bad_claims
      }

      assert {:error, :invalid_web_identity} =
               STS.assume_role_with_web_identity(role, non_map_claims,
                 session_name: "webid-direct",
                 duration_seconds: 900
               )
    end
  end

  test "web identity verifier derives provider ARN from HTTPS issuer and rejects HTTP issuers" do
    issuer = "https://secure.oidc.example.test/team"
    subject = "provider-subject"
    audience = "sts.amazonaws.com"
    jwk = JOSE.JWK.from_oct("provider-secret")
    token = web_identity_token(jwk, issuer, subject, audience)

    provider = %{
      issuer: issuer,
      audiences: [audience],
      jwks: [jwk],
      allowed_algs: ["HS256"],
      provider_arn: "arn:aws:iam:::oidc-provider/attacker.example.test"
    }

    assert {:ok, verified} =
             STS.WebIdentity.verify(token, providers: [provider])

    assert verified.provider_arn == "arn:aws:iam:::oidc-provider/secure.oidc.example.test/team"

    http_issuer = "http://secure.oidc.example.test/team"
    http_token = web_identity_token(jwk, http_issuer, subject, audience)

    assert {:error, :invalid_provider_issuer} =
             STS.WebIdentity.verify(http_token,
               providers: [%{provider | issuer: http_issuer}]
             )

    userinfo_issuer = "https://evil@secure.oidc.example.test/team"
    userinfo_token = web_identity_token(jwk, userinfo_issuer, subject, audience)

    assert {:error, :invalid_provider_issuer} =
             STS.WebIdentity.oidc_provider_arn(userinfo_issuer)

    assert {:error, :invalid_provider_issuer} =
             STS.WebIdentity.verify(userinfo_token,
               providers: [%{provider | issuer: userinfo_issuer}]
             )
  end

  test "web identity verifier rejects malformed provider clock skew config" do
    issuer = "https://skew.oidc.example.test/team"
    subject = "skew-subject"
    audience = "sts.amazonaws.com"
    jwk = JOSE.JWK.from_oct("provider-secret")
    token = web_identity_token(jwk, issuer, subject, audience)

    provider = %{
      issuer: issuer,
      audiences: [audience],
      jwks: [jwk],
      allowed_algs: ["HS256"],
      clock_skew_seconds: "not-an-integer"
    }

    assert {:error, :identity_provider_clock_skew_malformed} =
             STS.WebIdentity.verify(token, providers: [provider])
  end

  test "federated trust principals only match federated request principals" do
    provider_arn = "arn:aws:iam:::oidc-provider/issuer.example.test"

    statement = %Statement{
      effect: :allow,
      actions: ["sts:AssumeRoleWithWebIdentity"],
      resources: ["arn:aws:iam:::role/webid"],
      principals: {:federated, [provider_arn]},
      conditions: %{}
    }

    federated_ctx = %RequestContext{
      principal: %{type: :federated, arn: provider_arn},
      authenticated?: true,
      owner?: false,
      action: "sts:AssumeRoleWithWebIdentity",
      resource: "arn:aws:iam:::role/webid",
      conditions: %{}
    }

    iam_ctx = %{federated_ctx | principal: %{type: :iam_user, arn: provider_arn}}

    assert Evaluator.evaluate(federated_ctx, [statement]) == :allow
    assert Evaluator.evaluate(iam_ctx, [statement]) == {:deny, :implicit_deny}
  end

  test "assume_role requires SetSourceIdentity trust action even when called directly" do
    {:ok, caller} =
      IAM.create_access_key(access_key_id: unique_ak("SRCID"), secret_key: "issuer-secret")

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("direct-source"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => caller.principal_arn},
            "Action" => "sts:AssumeRole",
            "Condition" => %{"StringEquals" => %{"sts:SourceIdentity" => "pipeline"}}
          }
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: caller.principal_arn,
      tags: %{}
    }

    assert {:error, {:set_source_identity_denied, :implicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-source",
               duration_seconds: 900,
               source_identity: "pipeline"
             )
  end

  test "assume_role requires caller SetSourceIdentity identity policy even when called directly" do
    {:ok, caller} =
      IAM.create_access_key(access_key_id: unique_ak("CALLSRCID"), secret_key: "issuer-secret")

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("direct-caller-source"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => caller.principal_arn},
            "Action" => ["sts:AssumeRole", "sts:SetSourceIdentity"],
            "Condition" => %{"StringEquals" => %{"sts:SourceIdentity" => "pipeline"}}
          }
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: caller.principal_arn,
      tags: %{}
    }

    assert {:error, {:caller_set_source_identity_denied, :implicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-caller-source",
               duration_seconds: 900,
               source_identity: "pipeline"
             )

    assert :ok =
             IAM.put_principal_policy(
               caller.principal_arn,
               "set-source",
               ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:SetSourceIdentity","Resource":"#{role.role_arn}"}})
             )

    assert {:ok, session} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-caller-source",
               duration_seconds: 900,
               source_identity: "pipeline",
               session_access_key_id: unique_session_ak("CALLSRC")
             )

    assert session.source_identity == "pipeline"
  end

  test "assume_role requires caller AssumeRole identity policy for account principal trust" do
    {:ok, caller} =
      IAM.create_access_key(access_key_id: unique_ak("CALLASSUME"), secret_key: "issuer-secret")

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("direct-account-principal"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => IAM.root_principal_arn()},
            "Action" => "sts:AssumeRole"
          }
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: caller.principal_arn,
      tags: %{}
    }

    assert {:error, {:caller_assume_role_denied, :implicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-account-principal",
               duration_seconds: 900
             )

    assert :ok =
             IAM.put_principal_policy(
               caller.principal_arn,
               "allow-assume",
               ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"#{role.role_arn}"}})
             )

    assert {:ok, session} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-account-principal",
               duration_seconds: 900,
               session_access_key_id: unique_session_ak("CALLASSUME")
             )

    assert session.role_arn == role.role_arn
    row = Repo.get_by!(STSSession, access_key_id: session.access_key_id)
    assert STSSessionSecret.encrypted?(row.secret_key)
    expected_secret = session.secret_key

    assert {:ok, ^expected_secret} =
             STSSessionSecret.unwrap(row.secret_key, session.access_key_id)

    assert :ok =
             IAM.put_principal_policy(
               caller.principal_arn,
               "deny-assume",
               ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"sts:AssumeRole","Resource":"#{role.role_arn}"}})
             )

    assert {:error, {:caller_assume_role_denied, :explicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-account-principal-denied",
               duration_seconds: 900
             )
  end

  test "assume_role account principal caller policy is bounded by user permissions boundary" do
    {:ok, user} = IAM.create_user(user_name: unique_user("boundary-caller"))

    {:ok, caller} =
      IAM.create_access_key(
        user_name: user.user_name,
        access_key_id: unique_ak("CALLBOUND"),
        secret_key: "issuer-secret"
      )

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("account-boundary"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => IAM.root_principal_arn()},
            "Action" => "sts:AssumeRole"
          }
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: user.user_arn,
      tags: %{}
    }

    assert :ok =
             IAM.put_principal_policy(
               user.user_arn,
               "allow-assume",
               ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"#{role.role_arn}"}})
             )

    assert {:ok, boundary_without_sts} =
             IAM.create_managed_policy(
               name: unique_role("BoundaryWithoutSts"),
               path: "/sts/",
               policy:
                 ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"*"}})
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(
               user.user_name,
               boundary_without_sts.policy_arn
             )

    assert {:error, {:caller_assume_role_denied, :permissions_boundary}} =
             STS.assume_role(caller_principal, role,
               session_name: "account-boundary-denied",
               duration_seconds: 900
             )

    assert {:ok, boundary_with_sts} =
             IAM.create_managed_policy(
               name: unique_role("BoundaryWithSts"),
               path: "/sts/",
               policy:
                 ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"#{role.role_arn}"}})
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(
               user.user_name,
               boundary_with_sts.policy_arn
             )

    assert {:ok, session} =
             STS.assume_role(caller_principal, role,
               session_name: "account-boundary-allowed",
               duration_seconds: 900,
               session_access_key_id: unique_session_ak("CALLBOUND")
             )

    assert session.role_arn == role.role_arn
  end

  test "assume_role direct principal trust honors boundary explicit deny only" do
    {:ok, user} = IAM.create_user(user_name: unique_user("direct-boundary-caller"))

    {:ok, caller} =
      IAM.create_access_key(
        user_name: user.user_name,
        access_key_id: unique_ak("DIRECTBOUND"),
        secret_key: "issuer-secret"
      )

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("direct-boundary"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => user.user_arn},
            "Action" => "sts:AssumeRole"
          }
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: user.user_arn,
      tags: %{}
    }

    assert {:ok, implicit_boundary} =
             IAM.create_managed_policy(
               name: unique_role("DirectImplicitBoundary"),
               path: "/sts/",
               policy:
                 ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"s3:GetObject","Resource":"*"}})
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(
               user.user_name,
               implicit_boundary.policy_arn
             )

    assert {:ok, session} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-boundary-implicit",
               duration_seconds: 900,
               session_access_key_id: unique_session_ak("DIRBOUND")
             )

    assert session.role_arn == role.role_arn

    assert {:ok, explicit_deny_boundary} =
             IAM.create_managed_policy(
               name: unique_role("DirectExplicitDenyBoundary"),
               path: "/sts/",
               policy:
                 ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"sts:AssumeRole","Resource":"#{role.role_arn}"}})
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(
               user.user_name,
               explicit_deny_boundary.policy_arn
             )

    assert {:error, {:caller_assume_role_denied, :explicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-boundary-explicit",
               duration_seconds: 900
             )
  end

  test "assume_role direct principal trust still honors caller explicit deny" do
    {:ok, caller} =
      IAM.create_access_key(access_key_id: unique_ak("DIRECTDENY"), secret_key: "issuer-secret")

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("direct-explicit-deny"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => caller.principal_arn},
            "Action" => "sts:AssumeRole"
          }
        }
      )

    assert :ok =
             IAM.put_principal_policy(
               caller.principal_arn,
               "deny-assume",
               ~s({"Version":"2012-10-17","Statement":{"Effect":"Deny","Action":"sts:AssumeRole","Resource":"#{role.role_arn}"}})
             )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: caller.principal_arn,
      tags: %{}
    }

    assert {:error, {:caller_assume_role_denied, :explicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-explicit-deny",
               duration_seconds: 900
             )
  end

  test "assume_role account principal explicit deny overrides direct allow" do
    {:ok, caller} =
      IAM.create_access_key(access_key_id: unique_ak("ACCTDENY"), secret_key: "issuer-secret")

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("account-deny-direct-allow"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => [
            %{
              "Effect" => "Deny",
              "Principal" => %{"AWS" => IAM.root_principal_arn()},
              "Action" => "sts:AssumeRole"
            },
            %{
              "Effect" => "Allow",
              "Principal" => %{"AWS" => caller.principal_arn},
              "Action" => "sts:AssumeRole"
            }
          ]
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: caller.principal_arn,
      tags: %{}
    }

    assert {:error, {:assume_role_denied, :explicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "account-deny-direct-allow",
               duration_seconds: 900
             )
  end

  test "assume_role session tags require caller TagSession identity policy" do
    {:ok, caller} =
      IAM.create_access_key(access_key_id: unique_ak("TAGCALL"), secret_key: "issuer-secret")

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("caller-tag-session"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => IAM.root_principal_arn()},
            "Action" => ["sts:AssumeRole", "sts:TagSession"]
          }
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: caller.principal_arn,
      tags: %{}
    }

    assert :ok =
             IAM.put_principal_policy(
               caller.principal_arn,
               "assume-only",
               ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"#{role.role_arn}"}})
             )

    assert {:error, {:caller_tag_session_denied, :implicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "caller-tag-session",
               duration_seconds: 900,
               session_tags: [{"team", "platform"}]
             )

    assert :ok =
             IAM.put_principal_policy(
               caller.principal_arn,
               "tag-session",
               ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:TagSession","Resource":"#{role.role_arn}"}})
             )

    assert {:ok, session} =
             STS.assume_role(caller_principal, role,
               session_name: "caller-tag-session",
               duration_seconds: 900,
               session_tags: [{"team", "platform"}],
               session_access_key_id: unique_session_ak("TAGCALL")
             )

    assert session.tags["team"] == "platform"
  end

  test "assume_role caller permissions boundary gates TagSession and SetSourceIdentity" do
    {:ok, user} = IAM.create_user(user_name: unique_user("aux-boundary-caller"))

    {:ok, caller} =
      IAM.create_access_key(
        user_name: user.user_name,
        access_key_id: unique_ak("AUXBOUND"),
        secret_key: "issuer-secret"
      )

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("aux-boundary"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => IAM.root_principal_arn()},
            "Action" => ["sts:AssumeRole", "sts:TagSession", "sts:SetSourceIdentity"]
          }
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: user.user_arn,
      tags: %{}
    }

    assert :ok =
             IAM.put_principal_policy(
               user.user_arn,
               "allow-sts-aux",
               ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["sts:AssumeRole","sts:TagSession","sts:SetSourceIdentity"],"Resource":"#{role.role_arn}"}})
             )

    assert {:ok, assume_only_boundary} =
             IAM.create_managed_policy(
               name: unique_role("AssumeOnlyBoundary"),
               path: "/sts/",
               policy:
                 ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:AssumeRole","Resource":"#{role.role_arn}"}})
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(
               user.user_name,
               assume_only_boundary.policy_arn
             )

    assert {:error, {:caller_tag_session_denied, :permissions_boundary}} =
             STS.assume_role(caller_principal, role,
               session_name: "aux-boundary-tags",
               duration_seconds: 900,
               session_tags: [{"team", "platform"}]
             )

    assert {:error, {:caller_set_source_identity_denied, :permissions_boundary}} =
             STS.assume_role(caller_principal, role,
               session_name: "aux-boundary-source",
               duration_seconds: 900,
               source_identity: "pipeline"
             )

    assert {:ok, full_boundary} =
             IAM.create_managed_policy(
               name: unique_role("FullAuxBoundary"),
               path: "/sts/",
               policy:
                 ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":["sts:AssumeRole","sts:TagSession","sts:SetSourceIdentity"],"Resource":"#{role.role_arn}"}})
             )

    assert {:ok, _user} =
             IAM.put_user_permissions_boundary_strict(user.user_name, full_boundary.policy_arn)

    assert {:ok, session} =
             STS.assume_role(caller_principal, role,
               session_name: "aux-boundary-allowed",
               duration_seconds: 900,
               source_identity: "pipeline",
               session_tags: [{"team", "platform"}],
               session_access_key_id: unique_session_ak("AUXBOUND")
             )

    assert session.source_identity == "pipeline"
    assert session.tags["team"] == "platform"
  end

  test "assume_role inherits caller SourceIdentity in core calls and gates caller policy" do
    {:ok, caller} =
      IAM.create_access_key(access_key_id: unique_ak("INHERITSRC"), secret_key: "issuer-secret")

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("direct-inherited-source"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => caller.principal_arn},
            "Action" => ["sts:AssumeRole", "sts:SetSourceIdentity"],
            "Condition" => %{"StringEquals" => %{"sts:SourceIdentity" => "pipeline"}}
          }
        }
      )

    caller_principal = %{
      type: :assumed_role,
      access_key: caller.access_key_id,
      arn: caller.principal_arn,
      source_identity: "pipeline",
      credential_type: :session,
      tags: %{}
    }

    assert {:error, {:caller_set_source_identity_denied, :implicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-inherited-source",
               duration_seconds: 900
             )

    assert :ok =
             IAM.put_principal_policy(
               caller.principal_arn,
               "set-inherited-source",
               ~s({"Version":"2012-10-17","Statement":{"Effect":"Allow","Action":"sts:SetSourceIdentity","Resource":"#{role.role_arn}"}})
             )

    assert {:ok, session} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-inherited-source",
               duration_seconds: 900,
               session_access_key_id: unique_session_ak("INHSRC")
             )

    assert session.source_identity == "pipeline"

    assert {:error, :source_identity_cannot_be_changed} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-inherited-source",
               duration_seconds: 900,
               source_identity: "other"
             )
  end

  test "assume_role core ignores caller-supplied request tag conditions without real session tags" do
    {:ok, caller} =
      IAM.create_access_key(access_key_id: unique_ak("TAGSPF"), secret_key: "issuer-secret")

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("direct-tag-spoof"),
        tags: %{"project" => "storage"},
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => caller.principal_arn},
            "Action" => "sts:AssumeRole",
            "Condition" => %{
              "StringEquals" => %{
                "aws:RequestTag/team" => "platform",
                "aws:ResourceTag/project" => "storage"
              }
            }
          }
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: caller.principal_arn,
      tags: %{}
    }

    before_count = Repo.aggregate(STSSession, :count)

    assert {:error, {:assume_role_denied, :implicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-tag-spoof",
               duration_seconds: 900,
               conditions: %{
                 "aws:RequestTag/team" => "platform",
                 "aws:ResourceTag/project" => "storage",
                 "aws:TagKeys" => ["team"]
               }
             )

    assert Repo.aggregate(STSSession, :count) == before_count
  end

  test "assume_role core ignores caller-supplied mfa_authenticated without verified MFA" do
    {:ok, caller} =
      IAM.create_access_key(access_key_id: unique_ak("MFASPF"), secret_key: "issuer-secret")

    {:ok, role} =
      IAM.create_role(
        role_name: unique_role("direct-mfa-spoof"),
        trust_policy: %{
          "Version" => "2012-10-17",
          "Statement" => %{
            "Effect" => "Allow",
            "Principal" => %{"AWS" => caller.principal_arn},
            "Action" => "sts:AssumeRole",
            "Condition" => %{"Bool" => %{"aws:MultiFactorAuthPresent" => "true"}}
          }
        }
      )

    caller_principal = %{
      type: :iam_user,
      access_key: caller.access_key_id,
      arn: caller.principal_arn,
      tags: %{}
    }

    before_count = Repo.aggregate(STSSession, :count)

    assert {:error, {:assume_role_denied, :implicit_deny}} =
             STS.assume_role(caller_principal, role,
               session_name: "direct-mfa-spoof",
               duration_seconds: 900,
               mfa_authenticated: true
             )

    assert Repo.aggregate(STSSession, :count) == before_count
  end

  defp unique_ak(prefix), do: "AKIA#{prefix}#{System.unique_integer([:positive])}"
  defp unique_session_ak(prefix), do: "ASIA#{prefix}#{System.unique_integer([:positive])}"
  defp unique_role(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp unique_user(prefix), do: "#{prefix}-#{System.unique_integer([:positive])}"
  defp sha256_hex(value), do: :crypto.hash(:sha256, value) |> Base.encode16(case: :lower)

  defp web_identity_token(jwk, issuer, subject, audience) do
    now = DateTime.utc_now() |> DateTime.to_unix()

    claims = %{
      "iss" => issuer,
      "sub" => subject,
      "aud" => audience,
      "iat" => now,
      "exp" => now + 3_600
    }

    jwk
    |> JOSE.JWT.sign(%{"alg" => "HS256"}, claims)
    |> JOSE.JWS.compact()
    |> elem(1)
  end

  defp with_access_key_secret_config(config, fun) do
    original = Application.fetch_env!(:maxio, :access_key_secret)

    try do
      Application.put_env(:maxio, :access_key_secret, config)
      fun.()
    after
      Application.put_env(:maxio, :access_key_secret, original)
    end
  end

  defp b64_secret(label), do: :crypto.hash(:sha256, label) |> Base.encode64()

  defp sts_envelope_key_id(envelope) do
    envelope
    |> String.replace_prefix("maxio-sts-secret-v1:", "")
    |> Base.url_decode64!(padding: false)
    |> Jason.decode!()
    |> Map.fetch!("key_id")
  end

  defp rewrite_sts_envelope(envelope, rewrite_fun) do
    rewritten =
      envelope
      |> String.replace_prefix("maxio-sts-secret-v1:", "")
      |> Base.url_decode64!(padding: false)
      |> Jason.decode!()
      |> rewrite_fun.()

    "maxio-sts-secret-v1:" <> Base.url_encode64(Jason.encode!(rewritten), padding: false)
  end

  defp insert_sts_session_row!(issuer, access_key_id, secret_key, token) do
    now = DateTime.utc_now()

    Repo.insert!(%STSSession{
      access_key_id: access_key_id,
      secret_key: secret_key,
      session_token_sha256: SessionToken.hash(token),
      issuer_access_key_id: issuer.access_key_id,
      principal_arn: issuer.principal_arn,
      principal_type: issuer.type,
      session_name: "test-session",
      status: "active",
      issued_at: now,
      expires_at: DateTime.add(now, 900, :second),
      tags: issuer.tags || %{}
    })
  end

  defp encrypted_sts_secret_for_test(secret_key, access_key_id) do
    key =
      :maxio
      |> Application.fetch_env!(:access_key_secret)
      |> Keyword.fetch!(:secret_key)
      |> Base.decode64!()

    iv = :crypto.strong_rand_bytes(12)
    aad = "maxio:iam:sts-session-secret:v1:" <> access_key_id

    {ciphertext, tag} =
      :crypto.crypto_one_time_aead(:aes_256_gcm, key, iv, secret_key, aad, true)

    envelope = %{
      "alg" => "AES-256-GCM",
      "key_id" => "local-default",
      "iv_b64" => Base.encode64(iv),
      "ciphertext_b64" => Base.encode64(ciphertext),
      "tag_b64" => Base.encode64(tag)
    }

    "maxio-sts-secret-v1:" <> Base.url_encode64(Jason.encode!(envelope), padding: false)
  end
end
