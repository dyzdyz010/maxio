defmodule Maxio.Auth.CredentialStore.MemoryStore do
  @moduledoc """
  ETS credential backend used by tests and local development.

  Long-term credentials are stored as `{access_key, secret_key, principal}`.
  Temporary session credentials are stored as
  `{access_key, secret_key, principal, session_meta}` and require a matching
  session token on lookup.

  ## 表的持有者必须是被监督的长期进程

  ETS 表随**创建者进程**一起消亡。若表由"第一个碰它的调用方"惰性创建，那个调用方通常是
  一次性的请求/测试进程：它一退出，整张凭据表（含 `put_access_key/1` 写入的 STS 临时凭据）
  就被静默清空，随后的合法请求会莫名其妙认证失败；更糟的是 BEAM 对 owner 死亡后的表回收是
  **异步**的，`:ets.whereis/1` 仍可能返回一个正在被销毁的表，于是紧随其后的写入抛
  `ArgumentError` 冲出鉴权路径（本应是结构化 S3 错误，AGENTS.md §3）。

  因此本模块自己就是那个被监督的持有者进程（与 `Maxio.S3.InFlight` 同一约定）：表在
  `init/1` 里创建，生命周期等于监督树。`ensure_table/0` 只在**没有** GenServer 的场景
  （`mix run --no-start` 之类不起应用的 CLI）启动一个独立临时 owner；应用随后启动时，临时
  owner 用 ETS `give_away/3` 把原表（含全部凭据）移交给受监督进程。调用方永远不直接持有表。
  """
  @behaviour Maxio.Auth.CredentialStore

  use GenServer

  alias Maxio.Auth.SessionToken

  @table :maxio_credentials
  @takeover_timeout 5_000
  @takeover_gift_tag {__MODULE__, :table_takeover}

  @doc false
  def start_link(opts \\ []), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    case take_table_ownership() do
      :ok -> {:ok, %{}}
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_call(:ensure_table, _from, state) do
    case table_owner() do
      owner when owner == self() -> {:reply, :ok, state}
      owner -> {:stop, {:credential_table_owner_changed, owner}, state}
    end
  end

  @impl true
  def get_secret(access_key), do: get_secret(access_key, [])

  @impl true
  def get_secret(access_key, opts) do
    ensure_table()

    case :ets.lookup(@table, access_key) do
      [{^access_key, secret_key, principal}] ->
        if session_token?(Keyword.get(opts, :session_token)) do
          {:error, :invalid_token}
        else
          {:ok, %{secret_key: secret_key, principal: principal}}
        end

      [{^access_key, secret_key, principal, meta}] ->
        session_secret(secret_key, principal, meta, opts)

      [] ->
        maybe_bootstrap_root_for(access_key, opts)
    end
  end

  @impl true
  def put_access_key(%{access_key: ak, secret_key: sk, session_token: token} = attrs) do
    ensure_table()

    case Map.get(attrs, :expires_at) do
      %DateTime{} = expires_at ->
        principal =
          attrs
          |> default_principal(ak)
          |> Map.put(:credential_type, :session)
          |> Map.put_new(:session_access_key, ak)
          |> Map.put_new(:session_expires_at, expires_at)

        meta = %{
          session_token_sha256: SessionToken.hash(token),
          expires_at: expires_at,
          status: Map.get(attrs, :status, :active)
        }

        :ets.insert(@table, {ak, sk, principal, meta})
        :ok

      _other ->
        {:error, :invalid_attrs}
    end
  end

  def put_access_key(%{access_key: ak, secret_key: sk} = attrs) do
    ensure_table()
    :ets.insert(@table, {ak, sk, default_principal(attrs, ak)})
    :ok
  end

  def put_access_key(_), do: {:error, :invalid_attrs}

  @impl true
  def list_keys do
    ensure_table()

    @table
    |> :ets.tab2list()
    |> Enum.flat_map(fn
      {ak, _sk, principal} -> [%{access_key: ak, principal: principal}]
      {_ak, _sk, _principal, _meta} -> []
    end)
  end

  @impl true
  def invalidate({:access_key, access_key}) when is_binary(access_key) do
    ensure_table()
    :ets.delete(@table, access_key)
    :ok
  end

  def invalidate(:all) do
    ensure_table()
    :ets.delete_all_objects(@table)
    bootstrap_root()
    :ok
  end

  def invalidate(_scope), do: :ok

  defp maybe_bootstrap_root_for(access_key, opts) do
    if access_key == root_access_key() do
      bootstrap_root()

      case :ets.lookup(@table, access_key) do
        [{^access_key, secret_key, principal}] ->
          if session_token?(Keyword.get(opts, :session_token)) do
            {:error, :invalid_token}
          else
            {:ok, %{secret_key: secret_key, principal: principal}}
          end

        [] ->
          :error
      end
    else
      :error
    end
  end

  defp session_secret(secret_key, principal, meta, opts) do
    now = Keyword.get(opts, :now) || DateTime.utc_now()
    token = Keyword.get(opts, :session_token)

    cond do
      Map.get(meta, :status) != :active ->
        {:error, :invalid_token}

      DateTime.compare(Map.fetch!(meta, :expires_at), now) != :gt ->
        {:error, :expired_token}

      not session_token?(token) ->
        {:error, :missing_session_token}

      not SessionToken.verify(token, Map.fetch!(meta, :session_token_sha256)) ->
        {:error, :invalid_token}

      true ->
        {:ok, %{secret_key: secret_key, principal: principal}}
    end
  end

  defp default_principal(attrs, access_key) do
    Map.get(attrs, :principal, %{
      type: :iam_user,
      access_key: access_key,
      arn: "arn:aws:iam:::user/#{access_key}"
    })
  end

  defp ensure_table do
    case Process.whereis(__MODULE__) do
      nil -> ensure_temporary_owner()
      pid when pid == self() -> :ok
      _pid -> GenServer.call(__MODULE__, :ensure_table)
    end
  end

  # `mix run --no-start` 仍需可用，但不能再把表交给一次性 CLI/请求进程。这里起一个不与
  # 调用方链接的 VM 生命周期临时 owner；若多个调用方并发首触，只有成功创建 named table
  # 的进程留下，其余调用方观察赢家的表后继续。应用 GenServer 启动时会显式接管它。
  defp ensure_temporary_owner do
    case table_owner() do
      :undefined -> start_temporary_owner()
      _owner -> :ok
    end
  end

  defp start_temporary_owner do
    caller = self()
    ref = make_ref()
    pid = spawn(fn -> initialize_temporary_owner(caller, ref) end)
    monitor_ref = Process.monitor(pid)

    receive do
      {:credential_table_ready, ^ref, ^pid} ->
        Process.demonitor(monitor_ref, [:flush])
        :ok

      {:credential_table_already_exists, ^ref, ^pid} ->
        Process.demonitor(monitor_ref, [:flush])
        ensure_temporary_owner()

      {:DOWN, ^monitor_ref, :process, ^pid, reason} ->
        raise "credential table temporary owner exited during startup: #{inspect(reason)}"
    after
      @takeover_timeout ->
        Process.demonitor(monitor_ref, [:flush])
        raise "credential table temporary owner did not start within #{@takeover_timeout}ms"
    end
  end

  defp initialize_temporary_owner(caller, ref) do
    case new_table() do
      :ok ->
        bootstrap_root()
        send(caller, {:credential_table_ready, ref, self()})
        temporary_owner_loop()

      {:error, :already_exists} ->
        send(caller, {:credential_table_already_exists, ref, self()})
    end
  end

  defp temporary_owner_loop do
    receive do
      {:take_credential_table, new_owner, ref} when is_pid(new_owner) ->
        try do
          true = :ets.give_away(@table, new_owner, {@takeover_gift_tag, ref})
        rescue
          error ->
            send(new_owner, {:credential_table_takeover_failed, ref, Exception.message(error)})
            temporary_owner_loop()
        end
    end
  end

  defp take_table_ownership do
    case table_owner() do
      :undefined -> create_owned_table([])
      owner when owner == self() -> bootstrap_root()
      owner -> take_existing_table(owner)
    end
  end

  defp take_existing_table(owner) do
    case table_snapshot() do
      {:ok, snapshot} -> request_table_takeover(owner, snapshot)
      {:error, reason} -> {:error, {:credential_table_snapshot_failed, owner, reason}}
    end
  end

  defp request_table_takeover(owner, snapshot) do
    ref = make_ref()
    monitor_ref = Process.monitor(owner)
    send(owner, {:take_credential_table, self(), ref})

    receive do
      {:"ETS-TRANSFER", @table, ^owner, {@takeover_gift_tag, ^ref}} ->
        Process.demonitor(monitor_ref, [:flush])
        confirm_transferred_table_owner(owner)

      {:credential_table_takeover_failed, ^ref, reason} ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:credential_table_takeover_failed, owner, reason}}

      {:DOWN, ^monitor_ref, :process, ^owner, reason} ->
        recover_after_owner_exit(owner, reason, snapshot)
    after
      @takeover_timeout ->
        Process.demonitor(monitor_ref, [:flush])
        {:error, {:credential_table_takeover_timeout, owner}}
    end
  end

  # `:"ETS-TRANSFER"` 只是 mailbox 中的普通 term，任何本地进程都能伪造同形消息。官方
  # `:ets.give_away/3` 的真实后置条件是接收方已经成为 owner，因此启动成功必须同时验证
  # ETS 状态；只匹配消息内容会让恶意/故障 owner 在未移交表时骗过 `init/1`。
  defp confirm_transferred_table_owner(previous_owner) do
    case table_owner() do
      current when current == self() ->
        bootstrap_root()

      current ->
        {:error, {:credential_table_transfer_not_owned, previous_owner, current}}
    end
  end

  # 若旧 owner 正好在接管请求到达前退出，ETS 会随它消亡。启动进程已在发送请求前取得一致
  # 快照，因此可在同一 init 阶段重建并恢复；若 give_away 已完成但 DOWN 先被消费，则直接确认
  # 当前 owner。两条路径都不会让 GenServer 在“不拥有表”的假状态下完成启动。
  defp recover_after_owner_exit(owner, reason, snapshot) do
    case table_owner() do
      current when current == self() ->
        bootstrap_root()

      :undefined ->
        create_owned_table(snapshot)

      current ->
        {:error, {:credential_table_owner_changed_during_takeover, owner, current, reason}}
    end
  end

  defp create_owned_table(snapshot) do
    case new_table() do
      :ok ->
        if snapshot != [], do: :ets.insert(@table, snapshot)
        bootstrap_root()

      {:error, :already_exists} ->
        {:error, {:credential_table_create_raced, table_owner()}}
    end
  end

  defp new_table do
    try do
      :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
      :ok
    rescue
      ArgumentError -> {:error, :already_exists}
    end
  end

  defp table_owner do
    case :ets.whereis(@table) do
      :undefined -> :undefined
      _table -> :ets.info(@table, :owner)
    end
  end

  defp table_snapshot do
    {:ok, :ets.tab2list(@table)}
  rescue
    ArgumentError -> {:error, :table_unavailable}
  end

  defp bootstrap_root do
    s3 = Application.fetch_env!(:maxio, :s3)
    ak = Keyword.fetch!(s3, :root_user)
    sk = Keyword.fetch!(s3, :root_password)
    principal = %{type: :root, access_key: ak, arn: "arn:aws:iam:::root"}
    :ets.insert(@table, {ak, sk, principal})
    :ok
  end

  defp root_access_key do
    :maxio
    |> Application.fetch_env!(:s3)
    |> Keyword.fetch!(:root_user)
  end

  defp session_token?(nil), do: false
  defp session_token?(""), do: false
  defp session_token?(_token), do: true
end
