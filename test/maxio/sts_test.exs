defmodule Maxio.STSTest do
  use Maxio.DataCase, async: false

  alias Maxio.Auth.CredentialStore.EctoStore
  alias Maxio.Auth.SessionToken
  alias Maxio.IAM
  alias Maxio.IAM.STSSession
  alias Maxio.STS

  test "issue_session stores only token hash and list_sessions hides secrets" do
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
end
