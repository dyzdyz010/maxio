defmodule Maxio.Admin.Plug do
  @moduledoc """
  MinIO 管控面（`/minio/admin/*`）骨架 plug。

  ## 挂载点：SigV4 **之后**、Dispatch **之前**（设计 D7）

    * 必须在 SigV4 之后——admin 面需要 `conn.assigns.principal`（madmin 的请求是 SigV4
      签名的，service 名同样是 `s3`，credential scope 的 region 段为空串，maxio 现有
      验签路径原样通过，签名层零改动）。
    * 必须在 Dispatch 之前——否则 path-style 会把 `/minio/admin/v3/info` 误判成
      "桶 minio + key admin/v3/info"，返回 S3 XML `NoSuchBucket`。madmin 只解 JSON，
      拿到 XML 后只会显示 "The specified bucket does not exist."，把"管控面未接入"
      伪装成"桶不存在"——这正是接入前的实测症状。

  认领判定经 `ReservedNamespace.claimed?/2`：路径匹配之外还要求寻址结果指向**服务器根
  命名空间**。vhost 下 `Host: <bucket>.<domain>` + `GET /minio/admin/v3/info` 说的是桶
  `<bucket>` 里 key 为 `minio/admin/v3/info` 的对象；管控面若把它认领掉，客户端会拿到
  admin JSON 而不是自己的对象——静默数据劫持（铁律 3）。

  ## 已实现的端点

  | 路径 | 方法 | admin action | 响应 |
  |---|---|---|---|
  | `/minio/admin/v3/info` | GET | `admin:ServerInfo` | 200 明文 JSON `InfoMessage` |
  | `/minio/admin/v3/add-canned-policy` | PUT | `admin:CreatePolicy` | 200 空 body |
  | `/minio/admin/v3/list-canned-policies` | GET | `admin:ListUserPolicies` | 200 明文 JSON |
  | `/minio/admin/v3/info-canned-policy` | GET | `admin:GetPolicy` | 200 明文 JSON |
  | `/minio/admin/v3/remove-canned-policy` | DELETE | `admin:DeletePolicy` | 200 空 body |
  | `/minio/admin/v3/user-info` | GET | `admin:GetUser` | 200 明文 JSON `UserInfo` |

  其余一切 `/minio/admin/*`（含 `/minio/admin/v4/*`）落 501 `NotImplemented`(JSON)；
  匿名请求一律 403 `AccessDenied`(JSON)。

  501 而非 404 是刻意的（设计 §9.2）：运维必须看到"该功能未实现"，而不是"路径不存在"
  ——后者会把人引向版本/路径的无效排查（铁律 3：绝不用一个误导性的状态码掩盖真相）。
  `/minio/admin/v4/*` 同样落 501（本批不做 v4→426 回落：实测当前 mc 的 madmin 硬编码
  打 v3，做了无法活体验证，绝不实现无法取证的分支）。

  ## 为什么鉴权判定在路由**之前**

  未认证请求无论打哪条路径都是 403，不是 501。反过来（先路由再鉴权）会让匿名请求从
  501 的措辞里读出"这个端点存在/不存在"，把管控面的实现进度泄露给未认证方；而且
  "未认证"是比"未实现"更根本的拒绝理由，先报它才对得上因果。
  """

  import Plug.Conn

  alias Maxio.Admin.{
    Authz,
    ErrorMap,
    Envelope,
    ErrorView,
    GroupAdapter,
    GroupRequest,
    PolicyAdapter,
    PolicyAssociationRequest,
    PolicyEntitiesRequest,
    PolicyRequest,
    ServerInfo,
    UserAdapter,
    UserRequest
  }

  alias Maxio.Auth.SigningSecret
  alias Maxio.Admin.ConfigKV.{Adapter, Help, Request}
  alias Maxio.S3.{Error, Log, PipelineOrderError, RawPath, ReservedNamespace}

  @behaviour Plug
  @config_update_action "admin:ConfigUpdate"
  @config_kv_test_build Mix.env() == :test
  @config_failure_stages [:parser, :exposure, :type, :database, :postcommit]

  @impl true
  def init(opts), do: opts

  @impl true
  def call(%{assigns: %{maxio_surface: :admin}} = conn, _opts), do: handle(conn)
  def call(%{assigns: %{maxio_surface: :s3}} = conn, _opts), do: conn

  def call(conn, _opts) do
    if ReservedNamespace.admin_path?(conn.request_path || "") do
      raise PipelineOrderError,
            "admin surface requires assigns.maxio_surface; mount " <>
              "Maxio.S3.Plugs.SurfaceClassifier after Maxio.S3.Plugs.AddressStyle and before " <>
              "Maxio.Admin.Plug"
    else
      conn
    end
  end

  defp handle(conn) do
    try do
      route(conn)
    rescue
      err in Maxio.S3.Error ->
        render_error(conn, err)

      err in PipelineOrderError ->
        # 管线顺序错误是**部署期构造错误**，绝不能被下面的通用 500 兜底吞成一条与偶发
        # InternalError 无法区分的日志——那样"顺序错了要立刻可见"这个意图就只剩一句
        # 语义模糊的 warning。原样上抛 → OTP crash report（含 stacktrace），客户端仍是
        # 500 且细节不变（见 Maxio.S3.PipelineOrderError）。
        reraise err, __STACKTRACE__

      other ->
        # 完整异常 message 只进服务端日志，绝不进客户端 JSON（内部路径/密钥绝不外泄）——
        # 逐字继承 Maxio.S3.Plugs.Dispatch 的纪律。
        Log.error("unhandled exception in admin api",
          code: "InternalError",
          status: 500,
          method: conn.method,
          resource: RawPath.decoded_path(conn),
          reason: Exception.message(other)
        )

        render_error(conn, Error.new(:internal_error))
    end
  end

  defp route(conn) do
    if authenticated?(conn) do
      path = RawPath.decoded_path(conn)
      conn = assign(conn, :admin_raw_query_string, conn.query_string)
      conn = if raw_query_route?(conn.method, path), do: conn, else: fetch_query_params(conn)
      dispatch(conn, conn.method, path)
    else
      render_error(conn, Error.new(:access_denied))
    end
  end

  # madmin 的 ServerInfo 硬编码打 v3（实测 mc RELEASE.2025-08-13）。
  defp dispatch(conn, "GET", "/minio/admin/v3/info"), do: server_info(conn)

  defp dispatch(conn, "GET", "/minio/admin/v3/get-config-kv"), do: get_config_kv(conn)
  defp dispatch(conn, "GET", "/minio/admin/v3/help-config-kv"), do: help_config_kv(conn)
  defp dispatch(conn, "PUT", "/minio/admin/v3/set-config-kv"), do: set_config_kv(conn)
  defp dispatch(conn, "DELETE", "/minio/admin/v3/del-config-kv"), do: reset_config_kv(conn)
  defp dispatch(conn, "GET", "/minio/admin/v3/config"), do: export_config(conn)
  defp dispatch(conn, "PUT", "/minio/admin/v3/config"), do: import_config(conn)

  defp dispatch(conn, "PUT", "/minio/admin/v3/add-canned-policy"),
    do: create_policy(conn)

  defp dispatch(conn, "GET", "/minio/admin/v3/list-canned-policies"),
    do: list_policies(conn)

  defp dispatch(conn, "GET", "/minio/admin/v3/info-canned-policy"),
    do: policy_info(conn)

  defp dispatch(conn, "DELETE", "/minio/admin/v3/remove-canned-policy"),
    do: remove_policy(conn)

  defp dispatch(conn, "PUT", "/minio/admin/v3/add-user"), do: add_user(conn)
  defp dispatch(conn, "GET", "/minio/admin/v3/list-users"), do: list_users(conn)
  defp dispatch(conn, "GET", "/minio/admin/v3/user-info"), do: user_info(conn)
  defp dispatch(conn, "DELETE", "/minio/admin/v3/remove-user"), do: remove_user(conn)
  defp dispatch(conn, "PUT", "/minio/admin/v3/set-user-status"), do: set_user_status(conn)

  defp dispatch(conn, "GET", "/minio/admin/v3/groups"), do: list_groups(conn)
  defp dispatch(conn, "GET", "/minio/admin/v3/group"), do: group_info(conn)

  defp dispatch(conn, "PUT", "/minio/admin/v3/update-group-members"),
    do: update_group_members(conn)

  defp dispatch(conn, "PUT", "/minio/admin/v3/set-group-status"),
    do: set_group_status(conn)

  defp dispatch(conn, "POST", "/minio/admin/v3/idp/builtin/policy/" <> operation),
    do: policy_association(conn, operation)

  defp dispatch(conn, "GET", "/minio/admin/v3/idp/builtin/policy-entities"),
    do: policy_entities(conn)

  defp dispatch(conn, _method, path) do
    render_not_implemented(conn, path)
  end

  defp get_config_kv(conn) do
    with_config_kv_boundary(conn, "admin_config_get", fn ->
      conn = fetch_query_params(conn)

      if Map.has_key?(conn.query_params, "key") do
        authorize_and_run(conn, @config_update_action, "admin_config_get", fn conn ->
          get_config_kv_authorized(conn, conn.query_params["key"])
        end)
      else
        render_error(conn, ErrorMap.from_reason(:admin_version_mismatch))
      end
    end)
  end

  defp get_config_kv_authorized(conn, subsystem) do
    with {:ok, caller_secret} <- signing_secret(conn),
         {:ok, access_key_id} <- exact_actor_access_key_id(conn),
         {:ok, result} <- Adapter.get(subsystem, config_kv_options(conn, access_key_id)) do
      ciphertext = Request.encrypt_get!(caller_secret, result.plaintext)

      Log.info("admin config projected",
        action: "admin_config_get",
        admin_action: "admin_config_get",
        required_action: @config_update_action,
        config_subsystem: Atom.to_string(result.subsystem),
        config_key_count: length(result.keys),
        config_changed_count: 0,
        request_id: request_id(conn),
        principal_arn: principal_arn(conn),
        access_key_id: access_key_id,
        auth_type: conn.assigns[:auth_type]
      )

      send_config_ciphertext(conn, ciphertext)
    else
      {:error, :missing_signing_secret} ->
        render_error(conn, Error.new(:internal_error))

      {:error, :missing_actor_access_key} ->
        render_error(conn, Error.new(:internal_error))

      {:error, evidence} ->
        render_config_adapter_error(conn, :get, evidence)
    end
  end

  defp help_config_kv(conn) do
    action = config_action(:help)

    with_config_kv_boundary(conn, action, fn ->
      conn = fetch_query_params(conn)

      if Map.has_key?(conn.query_params, "subSys") and Map.has_key?(conn.query_params, "key") do
        authorize_and_run(conn, @config_update_action, action, fn conn ->
          help_config_kv_authorized(
            conn,
            conn.query_params["subSys"],
            conn.query_params["key"]
          )
        end)
      else
        render_error(conn, ErrorMap.from_reason(:admin_version_mismatch))
      end
    end)
  end

  defp help_config_kv_authorized(conn, subsystem, key) do
    env_only? = Map.has_key?(conn.query_params, "env")

    with {:ok, access_key_id} <- exact_actor_access_key_id(conn) do
      case Help.project(subsystem, key, env_only?) do
        {:ok, result} ->
          log_config_help(conn, access_key_id, result)
          send_config_help(conn, result)

        {:error, evidence} ->
          render_config_evidence_error(conn, config_action(:help), evidence)
      end
    else
      {:error, :missing_actor_access_key} ->
        render_config_unexpected_failure(conn, config_action(:help))
    end
  end

  defp set_config_kv(conn), do: mutate_config_kv(conn, :set)
  defp reset_config_kv(conn), do: mutate_config_kv(conn, :reset)

  defp export_config(conn) do
    action = config_action(:export)

    with_config_kv_boundary(conn, action, fn ->
      authorize_and_run(conn, @config_update_action, action, fn conn ->
        export_config_authorized(conn)
      end)
    end)
  end

  defp export_config_authorized(conn) do
    with {:ok, caller_secret} <- signing_secret(conn),
         {:ok, access_key_id} <- exact_actor_access_key_id(conn),
         {:ok, plaintext} <- Adapter.export_config(config_kv_options(conn, access_key_id)) do
      ciphertext = Request.encrypt!(caller_secret, plaintext)
      log_config_export(conn, access_key_id)
      send_config_ciphertext(conn, ciphertext)
    else
      {:error, :missing_signing_secret} -> render_error(conn, Error.new(:internal_error))
      {:error, :missing_actor_access_key} -> render_error(conn, Error.new(:internal_error))
      {:error, evidence} -> render_config_adapter_error(conn, :export, evidence)
    end
  end

  defp import_config(conn) do
    action = config_action(:import)

    with_config_kv_boundary(conn, action, fn ->
      authorize_and_run(conn, @config_update_action, action, fn conn ->
        import_config_authorized(conn)
      end)
    end)
  end

  defp import_config_authorized(conn) do
    with {:ok, caller_secret} <- signing_secret(conn),
         {:ok, access_key_id} <- exact_actor_access_key_id(conn) do
      {conn, plaintext} = Request.read_encrypted!(conn, caller_secret)
      opts = config_kv_options(conn, access_key_id)

      case Adapter.import_config(plaintext, opts) do
        {:ok, mutation} ->
          log_config_import(conn, access_key_id, mutation)
          config_archive_mutation_success(conn)

        {:error, evidence} ->
          render_config_adapter_error(conn, :import, evidence)
      end
    else
      {:error, :missing_signing_secret} -> render_error(conn, Error.new(:internal_error))
      {:error, :missing_actor_access_key} -> render_error(conn, Error.new(:internal_error))
    end
  end

  defp mutate_config_kv(conn, operation) do
    action = config_action(operation)

    with_config_kv_boundary(conn, action, fn ->
      authorize_and_run(conn, @config_update_action, action, fn conn ->
        mutate_config_kv_authorized(conn, operation)
      end)
    end)
  end

  defp mutate_config_kv_authorized(conn, operation) do
    with {:ok, caller_secret} <- signing_secret(conn),
         {:ok, access_key_id} <- exact_actor_access_key_id(conn) do
      declared_length = Request.declared_mutation_length!(conn)
      {conn, plaintext} = Request.read_mutation!(conn, caller_secret, declared_length)
      opts = config_kv_options(conn, access_key_id)

      result =
        case operation do
          :set -> Adapter.set(plaintext, opts)
          :reset -> Adapter.reset(plaintext, opts)
        end

      case result do
        {:ok, mutation} ->
          log_config_mutation(conn, config_action(operation), access_key_id, mutation)
          mutation_success(conn, mutation)

        {:error, evidence} ->
          render_config_adapter_error(conn, operation, evidence)
      end
    else
      {:error, :missing_signing_secret} -> render_error(conn, Error.new(:internal_error))
      {:error, :missing_actor_access_key} -> render_error(conn, Error.new(:internal_error))
    end
  end

  defp create_policy(conn) do
    authorize_and_run(conn, "admin:CreatePolicy", "admin_policy_create", fn conn ->
      {conn, body} = PolicyRequest.read_add_body!(conn)

      case PolicyAdapter.create(conn.query_params["name"], body) do
        {:ok, _policy} -> send_empty_success(conn)
        {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
      end
    end)
  end

  defp policy_association(conn, operation) do
    authorize_any_and_run(
      conn,
      ["admin:UpdatePolicyAssociation", "admin:AttachUserOrGroupPolicy"],
      "admin_policy_association_#{operation}",
      fn conn, authorized_action ->
        declared_length = PolicyAssociationRequest.validate_transport!(conn)

        if operation in ["attach", "detach"] do
          with {:ok, caller_secret} <- signing_secret(conn) do
            {conn, request} =
              PolicyAssociationRequest.read!(conn, caller_secret, declared_length)

            case PolicyAdapter.update_associations(
                   String.to_existing_atom(operation),
                   request.principal,
                   request.policies
                 ) do
              {:ok, result} ->
                log_policy_association(
                  conn,
                  operation,
                  authorized_action,
                  request,
                  result
                )

                encrypt_admin_success(conn, caller_secret, result.wire)

              {:error, reason} ->
                render_error(conn, ErrorMap.from_reason(reason))
            end
          else
            {:error, :missing_signing_secret} -> render_error(conn, Error.new(:internal_error))
          end
        else
          render_error(conn, Error.new(:admin_invalid_argument))
        end
      end
    )
  end

  defp policy_entities(conn) do
    authorize_any_and_run(
      conn,
      ["admin:ListGroups", "admin:ListUsers", "admin:ListUserPolicies"],
      "admin_policy_entities",
      fn conn, authorized_action ->
        with {:ok, caller_secret} <- signing_secret(conn),
             parsed <- PolicyEntitiesRequest.parse!(conn.assigns.admin_raw_query_string),
             {:ok, result} <-
               PolicyAdapter.entities(%{
                 users: parsed.users,
                 groups: parsed.groups,
                 policies: parsed.policies,
                 requested: parsed.requested
               }) do
          Log.info("admin policy entities projected",
            action: "admin_policy_entities",
            admin_action: "admin_policy_entities",
            authorized_action: authorized_action,
            required_actions: "admin:ListGroups,admin:ListUsers,admin:ListUserPolicies",
            requested_user_count: length(parsed.users),
            requested_group_count: length(parsed.groups),
            requested_policy_count: length(parsed.policies),
            user_mapping_count: result.evidence.user_mappings,
            group_mapping_count: result.evidence.group_mappings,
            policy_mapping_count: result.evidence.policy_mappings,
            request_id: request_id(conn),
            principal_arn: principal_arn(conn),
            auth_type: conn.assigns[:auth_type]
          )

          encrypt_admin_success(conn, caller_secret, result.wire)
        else
          {:error, :missing_signing_secret} -> render_error(conn, Error.new(:internal_error))
          {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
        end
      end
    )
  end

  defp list_policies(conn) do
    authorize_and_run(conn, "admin:ListUserPolicies", "admin_policy_list", fn conn ->
      if Map.has_key?(conn.query_params, "bucket") do
        render_not_implemented(conn, RawPath.decoded_path(conn))
      else
        {:ok, %{policies: policies, omitted: omitted}} = PolicyAdapter.list()

        if omitted != [] do
          Log.info("non-root policies omitted from MinIO admin view",
            action: "admin_policy_list",
            admin_action: "admin_policy_list",
            omitted_non_root_path_policies: length(omitted),
            request_id: request_id(conn),
            surface: conn.assigns[:maxio_surface]
          )
        end

        send_json(conn, policies)
      end
    end)
  end

  defp policy_info(conn) do
    authorize_and_run(conn, "admin:GetPolicy", "admin_policy_info", fn conn ->
      case conn.query_params["v"] do
        version when version in [nil, "", "2"] -> policy_info(conn, version)
        _unsupported -> render_error(conn, Error.new(:admin_invalid_argument))
      end
    end)
  end

  defp policy_info(conn, version) do
    case PolicyAdapter.info(conn.query_params["name"]) do
      {:ok, info} when version == "2" -> send_json(conn, info)
      {:ok, info} -> send_json(conn, info["Policy"])
      {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
    end
  end

  defp remove_policy(conn) do
    authorize_and_run(conn, "admin:DeletePolicy", "admin_policy_remove", fn conn ->
      case PolicyAdapter.remove(conn.query_params["name"]) do
        :ok -> send_empty_success(conn)
        {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
      end
    end)
  end

  defp add_user(conn) do
    authorize_and_run(
      conn,
      "admin:CreateUser",
      "admin_user_add",
      [target_user: conn.query_params["accessKey"]],
      fn conn ->
        if Map.has_key?(conn.query_params, "bucket") do
          render_not_implemented(conn, RawPath.decoded_path(conn))
        else
          add_user_authorized(conn)
        end
      end
    )
  end

  defp add_user_authorized(conn) do
    with {:ok, caller_secret} <- signing_secret(conn) do
      {conn, request} = UserRequest.read_add_body!(conn, caller_secret)

      case UserAdapter.add(conn.query_params["accessKey"], request) do
        {:ok, _created} -> send_empty_success(conn)
        {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
      end
    else
      {:error, :missing_signing_secret} -> render_error(conn, Error.new(:internal_error))
    end
  end

  defp list_users(conn) do
    authorize_and_run(conn, "admin:ListUsers", "admin_user_list", fn conn ->
      if Map.has_key?(conn.query_params, "bucket") do
        render_not_implemented(conn, RawPath.decoded_path(conn))
      else
        with {:ok, caller_secret} <- signing_secret(conn),
             {:ok, result} <- UserAdapter.list(),
             plaintext = Jason.encode_to_iodata!(result.wire),
             {:ok, encrypted} <- Envelope.encrypt(caller_secret, plaintext) do
          log_user_list_projection(conn, result.evidence)
          send_encrypted_json(conn, encrypted)
        else
          {:error, :missing_signing_secret} -> render_error(conn, Error.new(:internal_error))
          {:error, reason} -> render_error(conn, ErrorMap.from_reason(reason))
        end
      end
    end)
  end

  defp signing_secret(%{
         assigns: %{sigv4_context: %{caller_secret: %SigningSecret{} = caller_secret}}
       }),
       do: {:ok, caller_secret}

  defp signing_secret(_conn), do: {:error, :missing_signing_secret}

  defp log_user_list_projection(conn, evidence) do
    metadata =
      [
        action: "admin_user_list",
        admin_action: "admin_user_list",
        user_count: evidence.user_count,
        credential_bearing_count: evidence.credential_bearing_count,
        managed_policies: evidence.managed_policies,
        inline_policies: evidence.inline_policies,
        group_inherited: evidence.group_inherited,
        role_attached: evidence.role_attached,
        minio_view_partial_count: evidence.minio_view_partial_count,
        omitted_reason: Enum.join(evidence.omitted_reason, ","),
        request_id: request_id(conn),
        surface: conn.assigns[:maxio_surface]
      ]

    Log.info("admin user list projected", metadata)

    if evidence.minio_view_partial_count > 0 do
      Log.warn("admin user list contains partial MinIO UserInfo projections", metadata)
    end
  end

  defp user_info(conn) do
    authorize_and_run(
      conn,
      "admin:GetUser",
      "admin_user_info",
      [target_user: conn.query_params["accessKey"]],
      fn conn ->
        case UserAdapter.info(conn.query_params["accessKey"]) do
          {:ok, result} ->
            log_user_info_projection(conn, result.evidence)
            send_json(conn, result.wire)

          {:error, reason} ->
            render_error(conn, ErrorMap.from_reason(reason))
        end
      end
    )
  end

  defp remove_user(conn) do
    authorize_and_run(
      conn,
      "admin:DeleteUser",
      "admin_user_remove",
      [target_user: conn.query_params["accessKey"]],
      fn conn ->
        if Map.has_key?(conn.query_params, "bucket") do
          render_not_implemented(conn, RawPath.decoded_path(conn))
        else
          with {:ok, actor_access_key_id} <- exact_actor_access_key_id(conn),
               {:ok, result} <-
                 UserAdapter.remove(conn.query_params["accessKey"], actor_access_key_id) do
            log_user_mutation(conn, "admin_user_remove", result)
            send_empty_success(conn)
          else
            {:error, :missing_actor_access_key} ->
              render_error(conn, Error.new(:internal_error))

            {:error, reason} ->
              render_error(conn, ErrorMap.from_reason(reason))
          end
        end
      end
    )
  end

  defp set_user_status(conn) do
    authorize_and_run(
      conn,
      "admin:EnableUser",
      "admin_user_status",
      [
        target_user: conn.query_params["accessKey"],
        requested_status: conn.query_params["status"]
      ],
      fn conn ->
        if Map.has_key?(conn.query_params, "bucket") do
          render_not_implemented(conn, RawPath.decoded_path(conn))
        else
          with {:ok, actor_access_key_id} <- exact_actor_access_key_id(conn),
               {:ok, result} <-
                 UserAdapter.status(
                   conn.query_params["accessKey"],
                   conn.query_params["status"],
                   actor_access_key_id
                 ) do
            log_user_mutation(conn, "admin_user_status", result)
            send_empty_success(conn)
          else
            {:error, :missing_actor_access_key} ->
              render_error(conn, Error.new(:internal_error))

            {:error, reason} ->
              render_error(conn, ErrorMap.from_reason(reason))
          end
        end
      end
    )
  end

  defp list_groups(conn) do
    authorize_and_run(conn, "admin:ListGroups", "admin_group_list", fn conn ->
      case GroupAdapter.list() do
        {:ok, result} ->
          Log.info("admin groups projected",
            action: "admin_group_list",
            admin_action: "admin_group_list",
            group_count: result.evidence.group_count,
            request_id: request_id(conn),
            surface: conn.assigns[:maxio_surface]
          )

          send_json(conn, result.wire)

        {:error, reason} ->
          render_error(conn, ErrorMap.from_reason(reason))
      end
    end)
  end

  defp group_info(conn) do
    authorize_and_run(
      conn,
      "admin:GetGroup",
      "admin_group_info",
      [target_group: conn.query_params["group"]],
      fn conn ->
        case GroupAdapter.info(conn.query_params["group"]) do
          {:ok, result} ->
            Log.info("admin group projected",
              action: "admin_group_info",
              admin_action: "admin_group_info",
              target_group: result.wire["name"],
              affected_member_count: length(result.wire["members"]),
              request_id: request_id(conn),
              surface: conn.assigns[:maxio_surface]
            )

            send_group_json(conn, result.wire)

          {:error, reason} ->
            render_error(conn, ErrorMap.from_reason(reason))
        end
      end
    )
  end

  defp update_group_members(conn) do
    authorize_and_run(conn, "admin:AddUserToGroup", "admin_group_members", fn conn ->
      {conn, request} = GroupRequest.read_update_body!(conn)

      case GroupAdapter.update_members(request) do
        {:ok, result} ->
          invalidation = Map.get(result, :invalidation, %{failures: []})

          Log.info("admin group membership mutation committed",
            action: "admin_group_members",
            admin_action: "admin_group_members",
            required_action: "admin:AddUserToGroup",
            target_group: request.group,
            requested_member_count: length(request.members),
            changed_member_count: length(Map.get(result, :changed_member_arns, [])),
            affected_member_count: length(Map.get(result, :affected_member_arns, [])),
            group_status_ignored: result.evidence.group_status_ignored,
            cleanup_count:
              result
              |> Map.get(:affected, %{})
              |> Map.values()
              |> Enum.sum(),
            invalidation_failure_count: length(invalidation.failures),
            request_id: request_id(conn),
            principal_arn: principal_arn(conn),
            auth_type: conn.assigns[:auth_type]
          )

          send_empty_success(conn)

        {:error, reason} ->
          render_error(conn, ErrorMap.from_reason(reason))
      end
    end)
  end

  defp set_group_status(conn) do
    authorize_and_run(
      conn,
      "admin:EnableGroup",
      "admin_group_status",
      [
        target_group: conn.query_params["group"],
        requested_group_status: conn.query_params["status"]
      ],
      fn conn ->
        case GroupAdapter.status(conn.query_params["group"], conn.query_params["status"]) do
          {:ok, result} ->
            invalidation = Map.get(result, :invalidation, %{failures: []})

            Log.info("admin group status mutation committed",
              action: "admin_group_status",
              admin_action: "admin_group_status",
              required_action: "admin:EnableGroup",
              target_group: result.group.group_name,
              requested_group_status: conn.query_params["status"],
              actual_group_status: result.group.status,
              affected_member_count: length(Map.get(result, :affected_member_arns, [])),
              invalidation_failure_count: length(invalidation.failures),
              request_id: request_id(conn),
              principal_arn: principal_arn(conn),
              auth_type: conn.assigns[:auth_type]
            )

            send_empty_success(conn)

          {:error, reason} ->
            render_error(conn, ErrorMap.from_reason(reason))
        end
      end
    )
  end

  defp exact_actor_access_key_id(%{
         assigns: %{sigv4_signed_request: %{access_key: access_key_id}}
       })
       when is_binary(access_key_id) and access_key_id != "",
       do: {:ok, access_key_id}

  defp exact_actor_access_key_id(_conn), do: {:error, :missing_actor_access_key}

  defp config_kv_options(conn, access_key_id) do
    audit = [
      source: "admin_api",
      principal_arn: principal_arn(conn),
      access_key_id: access_key_id,
      request_id: request_id(conn),
      auth_type: conn.assigns[:auth_type],
      return_error_evidence: true
    ]

    Keyword.merge(config_kv_test_options(conn), audit)
  end

  if @config_kv_test_build do
    defp config_kv_test_options(conn) do
      case conn.private[:maxio_config_kv_test_opts] do
        opts when is_list(opts) -> if Keyword.keyword?(opts), do: opts, else: []
        _other -> []
      end
    end
  else
    defp config_kv_test_options(_conn), do: []
  end

  defp render_config_adapter_error(conn, operation, evidence),
    do: render_config_evidence_error(conn, config_action(operation), evidence)

  defp render_config_evidence_error(
         conn,
         action,
         %{reason: reason, subsystem: subsystem, key_count: key_count, stage: stage}
       )
       when is_binary(action) and
              is_binary(subsystem) and is_integer(key_count) and key_count >= 0 and
              stage in @config_failure_stages do
    err = config_adapter_error(reason, action)

    Log.warn("admin config request failed",
      action: action,
      admin_action: action,
      required_action: @config_update_action,
      config_subsystem: subsystem,
      config_key_count: key_count,
      config_failure_stage: stage,
      code: err.code,
      status: err.http_status,
      request_id: request_id(conn),
      principal_arn: principal_arn(conn),
      auth_type: conn.assigns[:auth_type]
    )

    render_error(conn, err)
  end

  defp render_config_evidence_error(conn, action, _invalid_evidence),
    do: render_config_unexpected_failure(conn, action)

  defp config_adapter_error(:access_denied, action)
       when action in ["config_export", "config_import"],
       do: Error.new(:access_denied)

  defp config_adapter_error(:access_denied, _action), do: config_access_denied_error()
  defp config_adapter_error(reason, _action), do: ErrorMap.from_reason(reason)

  defp with_config_kv_boundary(conn, action, callback) do
    try do
      callback.()
    rescue
      err in Error ->
        log_config_transport_failure(conn, action, err)
        render_error(conn, err)

      _unexpected_error ->
        render_config_unexpected_failure(conn, action)
    catch
      _kind, _discarded_reason ->
        render_config_unexpected_failure(conn, action)
    end
  end

  defp render_config_unexpected_failure(conn, action) do
    err = Error.new(:internal_error)

    Log.warn("admin config handler failed",
      action: action,
      admin_action: action,
      required_action: @config_update_action,
      config_subsystem: "unknown",
      config_key_count: 0,
      config_failure_stage: config_unexpected_failure_stage(action),
      code: err.code,
      status: err.http_status,
      request_id: request_id(conn),
      principal_arn: principal_arn(conn),
      auth_type: conn.assigns[:auth_type]
    )

    render_error(conn, err)
  end

  defp config_unexpected_failure_stage("admin_config_help"), do: :exposure
  defp config_unexpected_failure_stage(_action), do: :database

  defp log_config_transport_failure(conn, action, err) do
    Log.warn("admin config transport failed",
      action: action,
      admin_action: action,
      required_action: @config_update_action,
      config_subsystem: "unknown",
      config_key_count: 0,
      config_failure_stage: config_transport_failure_stage(err),
      code: err.code,
      status: err.http_status,
      request_id: request_id(conn),
      principal_arn: principal_arn(conn),
      auth_type: conn.assigns[:auth_type]
    )
  end

  defp config_transport_failure_stage(%Error{code: "XMinioAdminConfigTooLarge"}), do: :framing
  defp config_transport_failure_stage(%Error{code: "XAmzContentSHA256Mismatch"}), do: :hash
  defp config_transport_failure_stage(%Error{code: "XMinioAdminConfigBadJSON"}), do: :transport
  defp config_transport_failure_stage(_err), do: :transport

  defp log_config_help(conn, access_key_id, result) do
    action = config_action(:help)

    Log.info("admin config help projected",
      action: action,
      admin_action: action,
      required_action: @config_update_action,
      config_subsystem: result.subsystem,
      config_key_count: result.key_count,
      config_changed_count: 0,
      request_id: request_id(conn),
      principal_arn: principal_arn(conn),
      access_key_id: access_key_id,
      auth_type: conn.assigns[:auth_type],
      surface: conn.assigns[:maxio_surface]
    )
  end

  defp log_config_mutation(conn, action, access_key_id, mutation) do
    Log.info("admin config mutation committed",
      action: action,
      admin_action: action,
      required_action: @config_update_action,
      config_subsystem: mutation.subsystem,
      config_key_count: map_size(mutation.outcomes),
      config_changed_count: mutation.changed_count,
      config_apply_modes: mutation_apply_modes_text(mutation),
      config_local_reload: config_local_reload_metadata(mutation.local_reload),
      config_broadcast: config_broadcast_metadata(mutation.broadcast),
      config_attention: to_string(mutation.attention?),
      request_id: request_id(conn),
      principal_arn: principal_arn(conn),
      access_key_id: access_key_id,
      auth_type: conn.assigns[:auth_type]
    )
  end

  defp log_config_export(conn, access_key_id) do
    Log.info("admin config archive projected",
      action: config_action(:export),
      admin_action: config_action(:export),
      required_action: @config_update_action,
      config_subsystem: "listing,prometheus_metrics,s3",
      config_key_count: 3,
      config_changed_count: 0,
      request_id: request_id(conn),
      principal_arn: principal_arn(conn),
      access_key_id: access_key_id,
      auth_type: conn.assigns[:auth_type]
    )
  end

  defp log_config_import(conn, access_key_id, mutation) do
    Log.info("admin config archive committed",
      action: config_action(:import),
      admin_action: config_action(:import),
      required_action: @config_update_action,
      config_subsystem: safe_subsystems(Map.get(mutation, :touched_subsystems, [])),
      config_changed_count: Map.get(mutation, :changed_count, 0),
      decision: "committed=#{Map.get(mutation, :committed?, false)}",
      config_local_reload: config_local_reload_metadata(Map.get(mutation, :local_reload)),
      config_broadcast: config_broadcast_metadata(Map.get(mutation, :broadcast)),
      config_attention: Map.get(mutation, :attention?, false),
      request_id: request_id(conn),
      principal_arn: principal_arn(conn),
      access_key_id: access_key_id,
      auth_type: conn.assigns[:auth_type]
    )
  end

  defp safe_subsystems(subsystems) when is_list(subsystems) do
    subsystems
    |> Enum.filter(&(&1 in [:listing, :prometheus_metrics, :s3]))
    |> Enum.map(&Atom.to_string/1)
    |> Enum.uniq()
    |> Enum.sort()
    |> Enum.join(",")
  end

  defp safe_subsystems(_subsystems), do: ""

  defp mutation_apply_modes_text(mutation) do
    case mutation_apply_modes(mutation) do
      [] -> "none"
      modes -> Enum.map_join(modes, ",", &Atom.to_string/1)
    end
  end

  defp mutation_apply_modes(%{outcomes: outcomes}) when is_map(outcomes) do
    outcomes
    |> Map.values()
    |> Enum.filter(&Map.get(&1, :changed?, false))
    |> Enum.map(&Map.get(&1, :applied))
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp mutation_apply_modes(_mutation), do: [:unknown]

  defp config_local_reload_metadata(:ok), do: :ok
  defp config_local_reload_metadata(:not_needed), do: :not_needed
  defp config_local_reload_metadata({:error, :reload_failed}), do: :reload_failed
  defp config_local_reload_metadata(_result), do: :failed

  defp config_broadcast_metadata(:ok), do: :ok
  defp config_broadcast_metadata(:not_needed), do: :not_needed
  defp config_broadcast_metadata({:error, :broadcast_failed}), do: :broadcast_failed
  defp config_broadcast_metadata(_result), do: :failed

  defp config_action(:get), do: "admin_config_get"
  defp config_action(:help), do: "admin_config_help"
  defp config_action(:set), do: "admin_config_set"
  defp config_action(:reset), do: "admin_config_reset"
  defp config_action(:export), do: "config_export"
  defp config_action(:import), do: "config_import"

  defp log_user_mutation(conn, admin_action, result) do
    affected = Map.get(result, :affected, %{})
    invalidation = Map.get(result, :invalidation, %{failures: []})

    Log.info("admin user mutation committed",
      action: admin_action,
      admin_action: admin_action,
      required_action: mutation_required_action(admin_action),
      target_user: conn.query_params["accessKey"],
      requested_status: conn.query_params["status"],
      affected_credentials: Map.get(affected, :credentials, 0),
      access_keys_deleted: Map.get(affected, :access_keys_deleted, 0),
      sessions_revoked: Map.get(affected, :sessions_revoked, 0),
      principal_policies_deleted: Map.get(affected, :principal_policies_deleted, 0),
      memberships_deleted: Map.get(affected, :memberships_deleted, 0),
      managed_policy_attachments_deleted:
        Map.get(affected, :managed_policy_attachments_deleted, 0),
      mfa_devices_deleted: Map.get(affected, :mfa_devices_deleted, 0),
      signing_certificates_deleted: Map.get(affected, :signing_certificates_deleted, 0),
      ssh_public_keys_deleted: Map.get(affected, :ssh_public_keys_deleted, 0),
      invalidation_failure_count: invalidation |> Map.get(:failures, []) |> length(),
      decision: "committed",
      principal_arn: principal_arn(conn),
      auth_type: conn.assigns[:auth_type],
      request_id: request_id(conn),
      surface: conn.assigns[:maxio_surface]
    )
  end

  defp mutation_required_action("admin_user_remove"), do: "admin:DeleteUser"
  defp mutation_required_action("admin_user_status"), do: "admin:EnableUser"

  defp log_user_info_projection(conn, evidence) do
    metadata =
      user_info_log_metadata(conn, evidence)

    Log.info("admin user info projected", metadata)

    if evidence.direct_managed.omitted_names != [] do
      Log.warn("ambiguous direct managed policy omitted from MinIO UserInfo", metadata)
    end
  end

  defp user_info_log_metadata(conn, evidence) do
    [
      action: "admin_user_info",
      admin_action: "admin_user_info",
      target_user: conn.query_params["accessKey"],
      credential_bearing: evidence.credential_bearing,
      managed_policies: evidence.direct_managed.count,
      inline_policies: evidence.direct_inline.count,
      group_inherited: evidence.group_inline.count + evidence.group_managed.count,
      role_attached: evidence.role_managed.count,
      minio_view_partial: evidence.minio_view_partial,
      omitted_reason: Enum.join(evidence.omitted_reason, ","),
      request_id: request_id(conn),
      surface: conn.assigns[:maxio_surface]
    ]
  end

  defp authorize_and_run(conn, required_action, admin_action, callback) do
    authorize_and_run(conn, required_action, admin_action, [], callback)
  end

  defp authorize_and_run(conn, required_action, admin_action, target_metadata, callback) do
    metadata =
      admin_log_metadata(conn, required_action, admin_action, target_metadata)

    case Authz.authorize(conn, conn.assigns[:principal], required_action) do
      :ok ->
        Log.info("admin request authorized", [{:decision, "allow"} | metadata])
        callback.(conn)

      {:error, reason} ->
        Log.warn("admin request denied", [
          {:decision, "deny"},
          {:reason, to_string(reason)}
          | metadata
        ])

        render_error(conn, access_denied_error(admin_action))
    end
  end

  defp access_denied_error(admin_action)
       when admin_action in [
              "admin_config_get",
              "admin_config_help",
              "admin_config_set",
              "admin_config_reset"
            ],
       do: config_access_denied_error()

  defp access_denied_error(_admin_action), do: Error.new(:access_denied)

  defp config_access_denied_error,
    do: Error.new(:access_denied, message: "Access Denied.")

  defp authorize_any_and_run(conn, required_actions, admin_action, callback) do
    metadata = [
      action: admin_action,
      admin_action: admin_action,
      admin_endpoint: RawPath.decoded_path(conn),
      required_actions: Enum.join(required_actions, ","),
      method: conn.method,
      resource: RawPath.decoded_path(conn),
      request_id: request_id(conn),
      auth_type: conn.assigns[:auth_type],
      principal_arn: principal_arn(conn),
      surface: conn.assigns[:maxio_surface]
    ]

    case Authz.authorize_any(conn, conn.assigns[:principal], required_actions) do
      {:ok, authorized_action} ->
        Log.info(
          "admin request authorized",
          [{:decision, "allow"}, {:authorized_action, authorized_action} | metadata]
        )

        callback.(conn, authorized_action)

      {:error, reason} ->
        Log.warn("admin request denied", [
          {:decision, "deny"},
          {:reason, to_string(reason)}
          | metadata
        ])

        render_error(conn, Error.new(:access_denied))
    end
  end

  defp encrypt_admin_success(conn, caller_secret, wire) do
    with {:ok, encrypted} <- Envelope.encrypt(caller_secret, Jason.encode_to_iodata!(wire)) do
      send_encrypted_json(conn, encrypted)
    else
      {:error, _reason} -> render_error(conn, Error.new(:internal_error))
    end
  end

  defp log_policy_association(conn, operation, authorized_action, request, result) do
    {principal_kind, _principal_name} = request.principal

    Log.info("admin policy association committed",
      action: "admin_policy_association_#{operation}",
      admin_action: "admin_policy_association_#{operation}",
      required_actions: "admin:UpdatePolicyAssociation,admin:AttachUserOrGroupPolicy",
      authorized_action: authorized_action,
      principal_kind: principal_kind,
      operation: operation,
      requested_policy_count: length(request.policies),
      changed_policy_count: result.changed_count,
      request_id: request_id(conn),
      principal_arn: principal_arn(conn),
      auth_type: conn.assigns[:auth_type]
    )
  end

  defp admin_log_metadata(conn, required_action, admin_action, target_metadata) do
    base = [
      action: admin_action,
      admin_action: admin_action,
      admin_endpoint: RawPath.decoded_path(conn),
      required_action: required_action,
      method: conn.method,
      resource: RawPath.decoded_path(conn),
      request_id: request_id(conn),
      auth_type: conn.assigns[:auth_type],
      principal_arn: principal_arn(conn),
      surface: conn.assigns[:maxio_surface]
    ]

    default_target =
      if String.starts_with?(admin_action, "admin_policy_") do
        [target_policy: conn.query_params["name"]]
      else
        []
      end

    target_metadata ++ default_target ++ base
  end

  defp send_json(conn, body) do
    encoded = Jason.encode_to_iodata!(body)

    conn
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("content-length", encoded |> IO.iodata_length() |> Integer.to_string())
    |> send_resp(200, encoded)
    |> halt()
  end

  defp send_group_json(conn, wire) do
    ordered =
      Jason.OrderedObject.new(
        Enum.flat_map(["name", "status", "members", "policy", "updatedAt"], fn key ->
          if Map.has_key?(wire, key), do: [{key, Map.fetch!(wire, key)}], else: []
        end)
      )

    send_json(conn, ordered)
  end

  defp send_encrypted_json(conn, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(200, body)
    |> halt()
  end

  defp send_config_ciphertext(conn, body) do
    conn
    |> delete_resp_header("transfer-encoding")
    |> delete_resp_header("content-encoding")
    |> delete_resp_header("x-minio-config-applied")
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("content-length", body |> IO.iodata_length() |> Integer.to_string())
    |> send_resp(200, body)
    |> halt()
  end

  defp send_config_help(conn, result) do
    body = Help.encode_line(result.wire)

    conn
    |> delete_resp_header("transfer-encoding")
    |> delete_resp_header("content-encoding")
    |> delete_resp_header("x-minio-config-applied")
    |> put_resp_header("content-type", "application/json")
    |> put_resp_header("content-length", Integer.to_string(IO.iodata_length(body)))
    |> send_resp(200, body)
    |> halt()
  end

  defp mutation_success(conn, result) do
    conn =
      if applied_without_restart?(result) do
        put_resp_header(conn, "x-minio-config-applied", "true")
      else
        delete_resp_header(conn, "x-minio-config-applied")
      end

    conn
    |> delete_resp_header("content-type")
    |> delete_resp_header("transfer-encoding")
    |> put_resp_header("content-length", "0")
    |> send_resp(200, "")
    |> halt()
  end

  defp config_archive_mutation_success(conn) do
    conn
    |> delete_resp_header("content-type")
    |> delete_resp_header("transfer-encoding")
    |> delete_resp_header("content-encoding")
    |> delete_resp_header("x-minio-config-applied")
    |> put_resp_header("content-length", "0")
    |> send_resp(200, "")
    |> halt()
  end

  defp applied_without_restart?(%{local_reload: local_reload} = result)
       when local_reload in [:ok, :not_needed] do
    Enum.all?(mutation_apply_modes(result), &(&1 in [:hot, :next_cycle]))
  end

  defp applied_without_restart?(_result), do: false

  defp send_empty_success(conn), do: conn |> send_resp(200, "") |> halt()

  defp render_not_implemented(conn, path) do
    render_error(
      conn,
      Error.new(:not_implemented,
        message: "The MinIO admin API endpoint #{path} is not implemented by maxio."
      )
    )
  end

  defp server_info(conn) do
    case Authz.authorize(conn, conn.assigns[:principal], "admin:ServerInfo") do
      :ok ->
        conn
        |> put_resp_content_type("application/json")
        |> send_resp(200, Jason.encode_to_iodata!(server_info_body(conn)))
        |> halt()

      {:error, reason} ->
        Log.warn("admin server info denied",
          action: "admin_server_info",
          required_action: "admin:ServerInfo",
          decision: "deny",
          reason: to_string(reason),
          method: conn.method,
          resource: RawPath.decoded_path(conn),
          auth_type: conn.assigns[:auth_type],
          principal_arn: principal_arn(conn)
        )

        render_error(conn, Error.new(:access_denied))
    end
  end

  # VERIFY-AT-IMPL V-A13：madmin **v3** 的 ServerInfo() 是否也发 `no-cache` query 未抓包核实
  # （v4 确定发；实测 mc RELEASE.2025-08-13 打的是 `/minio/admin/v3/info?metrics=false`）。
  # 无论它发不发，服务端支持这个参数都是正确的：收到就绕过 usage / 盘容量的短 TTL 快照，
  # 这个参数存在的全部意义就是"我要最新的，别给我缓存的"。
  defp server_info_body(conn) do
    ServerInfo.build(
      no_cache: no_cache?(conn),
      host: conn.host,
      scheme: conn.scheme
    )
  end

  defp no_cache?(conn) do
    case conn.query_params["no-cache"] do
      nil -> false
      value -> String.downcase(to_string(value)) not in ["false", "0", ""]
    end
  end

  defp raw_query_route?("GET", "/minio/admin/v3/idp/builtin/policy-entities"), do: true
  defp raw_query_route?("GET", "/minio/admin/v3/get-config-kv"), do: true
  defp raw_query_route?("GET", "/minio/admin/v3/help-config-kv"), do: true
  defp raw_query_route?("PUT", "/minio/admin/v3/set-config-kv"), do: true
  defp raw_query_route?("DELETE", "/minio/admin/v3/del-config-kv"), do: true
  defp raw_query_route?(_method, _path), do: false

  defp principal_arn(conn) do
    case conn.assigns[:principal] do
      %{arn: arn} -> arn
      _other -> nil
    end
  end

  # "已认证"取 SigV4 自己写下的 `:auth_type`，**显式**排除 `:anonymous`——绝不改用
  # `is_map(principal)` 之类的形状推断：SigV4 若哪天把匿名 principal 从原子 `:anonymous`
  # 换成 map 形状，形状推断会让匿名请求静默走进 501（看起来像"功能未实现"，实则鉴权
  # 判定失灵），而显式匹配在同样的改动下仍然正确（铁律 3）。
  # assign 缺失 = 本 plug 被挂到了 SigV4 之前，管线顺序错了必须立刻可见，绝不当成匿名。
  defp authenticated?(conn) do
    case Map.fetch(conn.assigns, :auth_type) do
      {:ok, :anonymous} ->
        false

      {:ok, _auth_type} ->
        conn.assigns[:principal] != :anonymous

      :error ->
        raise PipelineOrderError,
              "admin surface requires assigns.auth_type; mount Maxio.Admin.Plug after " <>
                "Maxio.S3.Plugs.SigV4"
    end
  end

  defp render_error(conn, %Error{} = err) do
    err = %{
      err
      | request_id: err.request_id || request_id(conn),
        resource: err.resource || RawPath.decoded_path(conn)
    }

    {status, body} = ErrorView.render(err)

    Log.warn("admin api error response",
      code: err.code,
      status: status,
      method: conn.method,
      resource: err.resource,
      request_id: err.request_id,
      auth_type: conn.assigns[:auth_type]
    )

    conn
    |> prepare_config_help_error_response(body)
    |> put_resp_content_type("application/json")
    |> send_resp(status, body)
    |> halt()
  end

  defp prepare_config_help_error_response(conn, body) do
    if conn.method == "GET" and
         RawPath.decoded_path(conn) == "/minio/admin/v3/help-config-kv" do
      conn
      |> delete_resp_header("transfer-encoding")
      |> delete_resp_header("content-encoding")
      |> delete_resp_header("x-minio-config-applied")
      |> put_resp_header("content-length", Integer.to_string(IO.iodata_length(body)))
    else
      conn
    end
  end

  # Plug.RequestId 把 id 写进 **响应**头（并进 Logger metadata），客户端自带时才有请求头；
  # 两处都读，保证 admin 错误体里的 RequestId 与访问日志能对上。
  defp request_id(conn) do
    case get_resp_header(conn, "x-request-id") do
      [id | _] -> id
      [] -> conn |> get_req_header("x-request-id") |> List.first()
    end
  end
end
