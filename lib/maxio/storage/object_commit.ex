defmodule Maxio.Storage.ObjectCommit do
  @moduledoc """
  Coordinates the optional staged PutObject commit callback shared by every
  storage backend.

  The coordinator owns the reversible window between byte publication and the
  caller's metadata commit. Backends register rollback/finalize callbacks before
  making final bytes visible. Success finalizes; all failure exits roll back.
  """

  @type prepared :: map()
  @type commit_opts :: keyword()

  require Logger

  alias Maxio.Storage.ObjectCommit.Control

  @spec run(
          keyword(),
          prepared(),
          commit_opts(),
          (commit_opts() -> result),
          (-> term())
        ) :: result
        when result: var
  def run(opts, prepared, default_commit_opts, publish_fun, discard_fun)
      when is_list(opts) and is_map(prepared) and is_function(publish_fun, 1) and
             is_function(discard_fun, 0) do
    # 协议 §5：Control 创建时立即持有 staging discard callback——owner 在 publisher
    # 注册前死亡时由 Control 执行 discard（此前该窗口的 staged tmp 只能靠 generic 清扫）。
    {:ok, control} = Control.start(self(), discard_fun)
    identity = Control.identity()

    run_controlled(
      Keyword.get(opts, :around_object_commit),
      prepared
      |> Map.put(:object_commit_identity, identity)
      |> Map.put(:object_commit_control, control),
      default_commit_opts,
      publish_fun,
      discard_fun,
      control,
      identity
    )
  end

  defp run_controlled(
         around,
         prepared,
         default_commit_opts,
         publish_fun,
         discard_fun,
         control,
         identity
       ) do
    publish_count = :atomics.new(1, [])

    guarded_publish = fn commit_opts ->
      commit_opts =
        commit_opts
        |> validate_commit_opts!()
        |> Keyword.put(:object_commit_control, control)
        |> Keyword.put(:object_commit_identity, identity)

      case :atomics.exchange(publish_count, 1, 1) do
        0 ->
          :ok = Control.arm_publisher(control, self())
          publish_fun.(commit_opts)

        _already_published ->
          raise ArgumentError, "object commit publish_fun must be called once"
      end
    end

    try do
      result =
        case around do
          nil ->
            guarded_publish.(default_commit_opts)

          callback when is_function(callback, 2) ->
            callback.(prepared, guarded_publish)

          invalid ->
            raise ArgumentError,
                  ":around_object_commit must be a function of arity 2, got: #{inspect(invalid)}"
        end

      case :atomics.get(publish_count, 1) do
        1 ->
          complete(control, result, discard_fun, identity)

        0 ->
          case result do
            {:error, _reason} = error ->
              rollback(control, identity)
              discard_fun.()
              error

            _other ->
              raise ArgumentError,
                    "around_object_commit returned successfully without publishing staged bytes"
          end
      end
    rescue
      error ->
        rollback(control, identity)
        discard_fun.()
        reraise(error, __STACKTRACE__)
    catch
      kind, reason ->
        rollback(control, identity)
        discard_fun.()
        :erlang.raise(kind, reason, __STACKTRACE__)
    end
  end

  defp complete(control, {:error, _reason} = error, discard_fun, identity) do
    rollback(control, identity)
    discard_fun.()
    error
  end

  defp complete(control, result, discard_fun, identity) do
    case Control.finalize(control) do
      :ok ->
        result

      {:error, :not_registered} ->
        Logger.error("object commit finalize refused without backend registration",
          action: :object_commit_finalize,
          commit_identity: identity,
          reason: "not_registered"
        )

        discard_fun.()
        {:error, {:object_commit_finalize_failed, :not_registered}}

      {:error, reason} ->
        Logger.error("object commit finalize failed",
          action: :object_commit_finalize,
          commit_identity: identity,
          reason: inspect(reason)
        )

        result
    end
  end

  defp rollback(control, identity) do
    case Control.rollback(control) do
      :ok ->
        :ok

      {:error, reason} ->
        Logger.error("object commit rollback failed",
          action: :object_commit_rollback,
          commit_identity: identity,
          reason: inspect(reason)
        )
    end
  end

  defp validate_commit_opts!(commit_opts) do
    if Keyword.keyword?(commit_opts) do
      commit_opts
    else
      raise ArgumentError, "object commit options must be a keyword list"
    end
  end
end
