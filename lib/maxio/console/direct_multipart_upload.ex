defmodule Maxio.Console.DirectMultipartUpload do
  @moduledoc """
  Console-side registry for browser-direct multipart uploads.

  The registry is a recovery and management index only. S3 multipart upload rows
  and ListParts remain the authoritative source for upload existence and part
  state.
  """
  import Ecto.Query
  require Logger

  alias Maxio.Console.DirectMultipartUpload.History
  alias Maxio.Console.DirectMultipartUpload.Upload, as: RegistryUpload
  alias Maxio.Multipart
  alias Maxio.Multipart.{Part, Upload}
  alias Maxio.Repo

  @direct_multipart_marker_param "x-maxio-console-direct-multipart"
  @registry_intent_param "x-maxio-console-registry"
  @file_name_param "x-maxio-console-file-name"
  @file_size_param "x-maxio-console-file-size"
  @file_last_modified_param "x-maxio-console-file-last-modified"
  @part_size_param "x-maxio-console-part-size"
  @request_payer_param "x-maxio-console-request-payer"
  @max_object_size 5 * 1_024 * 1_024 * 1_024 * 1_024
  @max_parts 10_000
  @max_part_size 5 * 1_024 * 1_024 * 1_024
  @max_file_name_bytes 1024
  @history_default_limit 50
  @history_export_limit 1_000
  @history_retention_default 200
  @max_bulk_abort 100
  @prune_default_limit 100
  @prune_max_limit 1_000
  @terminal_states ["completed", "aborted"]
  @scopes ["folder", "recursive", "bucket"]
  @max_search_chars 256

  @type register_attrs :: %{
          required(:principal_arn) => String.t(),
          required(:access_key) => String.t(),
          required(:file_name) => String.t(),
          required(:file_size) => pos_integer(),
          required(:file_last_modified) => non_neg_integer(),
          required(:part_size) => pos_integer(),
          optional(:request_payer) => boolean()
        }

  @type registry_intent_metadata :: %{
          required(:file_name) => String.t(),
          required(:file_size) => pos_integer(),
          required(:file_last_modified) => non_neg_integer(),
          required(:part_size) => pos_integer(),
          optional(:request_payer) => boolean()
        }

  @type terminal_attrs :: %{
          optional(:etag) => String.t(),
          optional(:version_id) => String.t(),
          optional(:size) => non_neg_integer()
        }

  @type prune_summary :: %{
          required(:dry_run) => boolean(),
          required(:bucket) => String.t() | nil,
          required(:prefix) => String.t(),
          required(:scope) => String.t(),
          required(:query) => String.t() | nil,
          required(:principal_arn) => String.t() | nil,
          required(:access_key) => String.t() | nil,
          required(:all_owners) => boolean(),
          required(:older_than_seconds) => pos_integer(),
          required(:min_file_size) => non_neg_integer() | nil,
          required(:max_file_size) => non_neg_integer() | nil,
          required(:limit) => pos_integer(),
          required(:matched) => non_neg_integer(),
          required(:selected) => non_neg_integer(),
          required(:skipped) => non_neg_integer(),
          required(:would_abort) => non_neg_integer(),
          required(:aborted) => non_neg_integer(),
          required(:not_found) => non_neg_integer(),
          required(:failed) => non_neg_integer(),
          required(:errors) => [map()]
        }

  @doc "Adds the browser-direct multipart marker to a presigned S3 query."
  @spec marker_query(map()) :: map()
  def marker_query(query \\ %{}) when is_map(query) do
    Map.merge(%{@direct_multipart_marker_param => "1"}, query)
  end

  @doc """
  Builds the signed query intent used to atomically register a Console direct MPU.

  The returned values are encoded into the S3 CreateMultipartUpload presigned URL.
  Since SigV4 signs query parameters, any browser/client tampering is rejected by
  authentication before the S3 handler can create an upload row.
  """
  @spec registry_intent_query(registry_intent_metadata()) ::
          {:ok, map()} | {:error, atom()}
  def registry_intent_query(attrs) when is_map(attrs) do
    with {:ok, normalized} <- normalize_registry_intent_attrs(attrs) do
      {:ok,
       marker_query(%{
         @registry_intent_param => "1",
         @file_name_param => normalized.file_name,
         @file_size_param => Integer.to_string(normalized.file_size),
         @file_last_modified_param => Integer.to_string(normalized.file_last_modified),
         @part_size_param => Integer.to_string(normalized.part_size),
         @request_payer_param => if(normalized.request_payer, do: "1", else: "0")
       })}
    end
  end

  @doc "Returns true when a query belongs to the Console browser-direct MPU scope."
  @spec direct_multipart_query?(map() | nil) :: boolean()
  def direct_multipart_query?(query) when is_map(query),
    do: Map.get(query, @direct_multipart_marker_param) == "1"

  def direct_multipart_query?(_query), do: false

  @doc """
  Parses the signed Console registry intent from an S3 CreateMultipartUpload query.

  Returned attrs are suitable for `register/2`; `principal` comes from successful
  SigV4 authentication and supplies ownership fields that are not trusted from
  the browser.
  """
  @spec registry_intent_attrs(map(), map()) :: {:ok, register_attrs()} | {:error, atom()}
  def registry_intent_attrs(query, principal) when is_map(query) and is_map(principal) do
    with "1" <- Map.get(query, @direct_multipart_marker_param),
         "1" <- Map.get(query, @registry_intent_param),
         {:ok, file_name} <- parse_file_name(Map.get(query, @file_name_param)),
         {:ok, file_size} <- parse_file_size(Map.get(query, @file_size_param)),
         {:ok, file_last_modified} <-
           parse_file_last_modified(Map.get(query, @file_last_modified_param)),
         {:ok, part_size} <- parse_part_size(Map.get(query, @part_size_param), file_size),
         {:ok, request_payer} <- parse_request_payer(Map.get(query, @request_payer_param)),
         {:ok, principal_arn} <- principal_arn(principal),
         {:ok, access_key} <- principal_access_key(principal) do
      {:ok,
       %{
         principal_arn: principal_arn,
         access_key: access_key,
         file_name: file_name,
         file_size: file_size,
         file_last_modified: file_last_modified,
         part_size: part_size,
         request_payer: request_payer
       }}
    else
      {:error, reason} -> {:error, reason}
      _other -> {:error, :invalid_registry_intent}
    end
  end

  def registry_intent_attrs(_query, _principal), do: {:error, :invalid_registry_intent}

  @doc "Register or refresh a Console direct multipart upload after S3 CreateMultipartUpload returns an UploadId."
  @spec register(Upload.t(), register_attrs()) ::
          {:ok, RegistryUpload.t()} | {:error, Ecto.Changeset.t()}
  def register(%Upload{} = upload, attrs) do
    now = DateTime.utc_now()

    registry_attrs =
      attrs
      |> Map.take([
        :principal_arn,
        :access_key,
        :file_name,
        :file_size,
        :file_last_modified,
        :part_size,
        :request_payer
      ])
      |> Map.merge(%{
        multipart_upload_id: upload.id,
        bucket_name: upload.bucket_name,
        key: upload.key,
        upload_id: upload.upload_id,
        status: "active",
        inserted_at: now,
        updated_at: now
      })

    %RegistryUpload{}
    |> RegistryUpload.changeset(registry_attrs)
    |> Repo.insert(
      on_conflict:
        {:replace,
         [
           :multipart_upload_id,
           :bucket_name,
           :key,
           :principal_arn,
           :access_key,
           :file_name,
           :file_size,
           :file_last_modified,
           :part_size,
           :status,
           :updated_at
         ]},
      conflict_target: [:upload_id],
      returning: true
    )
  end

  @doc "List active registry rows visible to a Console principal under a bucket/prefix."
  @spec list_active(String.t(), String.t(), String.t(), keyword()) :: [RegistryUpload.t()]
  def list_active(bucket_name, prefix, principal_arn, opts \\ []) do
    scope = normalize_scope(Keyword.get(opts, :scope, "recursive"), "recursive")
    query_prefix = query_prefix(prefix, scope)
    search = normalize_search_query(Keyword.get(opts, :query))

    RegistryUpload
    |> where(
      [r],
      r.bucket_name == ^bucket_name and r.principal_arn == ^principal_arn and
        r.status == "active"
    )
    |> where([r], like(r.key, ^(escape_like(query_prefix) <> "%")))
    |> where_folder_scope(prefix, scope)
    |> maybe_where_registry_search(search)
    |> order_by([r], asc: r.key, desc: r.inserted_at)
    |> Repo.all()
    |> attach_part_stats()
  end

  @doc """
  Abort active Console direct MPU registry rows that match an operator policy.

  This is an operator-only maintenance path. It never reads object bytes and it
  still delegates the terminal mutation to `Multipart.abort/2`; registry rows
  remain a management index, not S3 MPU authority.
  """
  @spec prune_active(keyword()) :: {:ok, prune_summary()} | {:error, term()}
  def prune_active(opts \\ [])

  def prune_active(opts) when is_list(opts) do
    with {:ok, policy} <- normalize_prune_policy(opts) do
      query = prune_candidate_query(policy)
      matched = Repo.aggregate(query, :count, :id)

      candidates =
        query
        |> order_by([r, u], asc: r.bucket_name, asc: r.key, asc: u.inserted_at, asc: r.upload_id)
        |> limit(^policy.limit)
        |> Repo.all()

      summary = prune_summary(policy, matched, length(candidates))

      if policy.dry_run do
        Enum.each(candidates, &log_prune_candidate(&1, :would_abort, policy))
        {:ok, %{summary | would_abort: length(candidates)}}
      else
        {:ok, Enum.reduce(candidates, summary, &abort_prune_candidate(&1, &2, policy))}
      end
    end
  end

  def prune_active(_opts), do: {:error, :invalid_prune_policy}

  @doc "List recent terminal history rows visible to a Console principal under a bucket/prefix."
  @spec list_history(String.t(), String.t(), String.t(), keyword()) :: [History.t()]
  def list_history(bucket_name, prefix, principal_arn, opts \\ []) do
    scope = normalize_scope(Keyword.get(opts, :scope, "recursive"), "recursive")
    query_prefix = query_prefix(prefix, scope)
    limit = normalize_history_limit(Keyword.get(opts, :limit, @history_default_limit))
    terminal_state = normalize_terminal_state(Keyword.get(opts, :terminal_state))
    search = normalize_search_query(Keyword.get(opts, :query))

    History
    |> where(
      [h],
      h.bucket_name == ^bucket_name and h.principal_arn == ^principal_arn
    )
    |> where([h], like(h.key, ^(escape_like(query_prefix) <> "%")))
    |> where_folder_scope(prefix, scope)
    |> maybe_where_terminal_state(terminal_state)
    |> maybe_where_history_search(search)
    |> order_by([h], desc: h.terminal_at, desc: h.inserted_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @doc "Returns the allowed terminal history states for Console filters."
  @spec terminal_states() :: [String.t()]
  def terminal_states, do: @terminal_states

  @doc "Returns the allowed direct multipart operation scopes for Console filters."
  @spec scopes() :: [String.t()]
  def scopes, do: @scopes

  @doc "Normalizes Console direct multipart scope input."
  @spec normalize_scope(term(), String.t()) :: String.t()
  def normalize_scope(value, default \\ "recursive")
  def normalize_scope(value, _default) when value in @scopes, do: value

  def normalize_scope(value, _default) when value in [:folder, :current, :direct_child],
    do: "folder"

  def normalize_scope(value, _default) when value in [:recursive, :subtree], do: "recursive"
  def normalize_scope(value, _default) when value in [:bucket, :all], do: "bucket"
  def normalize_scope(value, _default) when value in ["current", "direct_child"], do: "folder"
  def normalize_scope("subtree", _default), do: "recursive"
  def normalize_scope("all", _default), do: "bucket"
  def normalize_scope(_value, default) when default in @scopes, do: default
  def normalize_scope(_value, _default), do: "recursive"

  @doc "Normalizes terminal history state input."
  @spec normalize_terminal_state(term()) :: String.t() | nil
  def normalize_terminal_state(value) when value in @terminal_states, do: value
  def normalize_terminal_state("all"), do: nil
  def normalize_terminal_state(_value), do: nil

  @doc "Normalizes direct multipart history/search query input."
  @spec normalize_search_query(term()) :: String.t() | nil
  def normalize_search_query(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> nil
      String.length(value) > @max_search_chars -> String.slice(value, 0, @max_search_chars)
      true -> value
    end
  end

  def normalize_search_query(_value), do: nil

  @doc "Maximum rows returned by a single Console CSV export."
  @spec history_export_limit() :: pos_integer()
  def history_export_limit, do: @history_export_limit

  @doc "Find a resumable upload by browser file fingerprint."
  @spec lookup_for_file(String.t(), String.t(), String.t(), pos_integer(), non_neg_integer()) ::
          {:ok, RegistryUpload.t()} | {:error, :not_found | :ambiguous_upload}
  def lookup_for_file(bucket_name, key, principal_arn, file_size, file_last_modified) do
    rows =
      RegistryUpload
      |> where(
        [r],
        r.bucket_name == ^bucket_name and r.key == ^key and r.principal_arn == ^principal_arn and
          r.file_size == ^file_size and r.file_last_modified == ^file_last_modified and
          r.status == "active"
      )
      |> order_by([r], desc: r.inserted_at)
      |> limit(2)
      |> Repo.all()
      |> attach_part_stats()

    case rows do
      [] -> {:error, :not_found}
      [row] -> {:ok, row}
      [_first, _second] -> {:error, :ambiguous_upload}
    end
  end

  @doc "Fetch an active registry row owned by the principal."
  @spec get_owned(String.t(), String.t(), String.t(), String.t()) ::
          {:ok, RegistryUpload.t()} | {:error, :not_found}
  def get_owned(bucket_name, key, upload_id, principal_arn) do
    case Repo.get_by(RegistryUpload,
           bucket_name: bucket_name,
           key: key,
           upload_id: upload_id,
           principal_arn: principal_arn,
           status: "active"
         ) do
      nil -> {:error, :not_found}
      row -> {:ok, row |> attach_part_stats()}
    end
  end

  @doc """
  Records a completed Console direct MPU terminal event.

  Normal S3 multipart uploads do not have a Console registry row and are ignored.
  The history row is a non-secret display/audit snapshot; S3 object metadata and
  multipart parts remain the authority for object contents.
  """
  @spec record_completed(Upload.t(), terminal_attrs()) ::
          {:ok, History.t()} | :ok | {:error, term()}
  def record_completed(%Upload{} = upload, attrs \\ %{}) when is_map(attrs) do
    case registry_for_upload(upload) do
      {:ok, registry} ->
        record_terminal(registry, upload, "completed", attrs)

      {:error, :not_found} ->
        :ok
    end
  end

  @doc "Records an aborted Console direct MPU terminal event when a registry row exists."
  @spec record_aborted(Upload.t() | RegistryUpload.t()) ::
          {:ok, History.t()} | :ok | {:error, term()}
  def record_aborted(%Upload{} = upload) do
    case registry_for_upload(upload) do
      {:ok, registry} -> record_terminal(registry, upload, "aborted", %{})
      {:error, :not_found} -> :ok
    end
  end

  def record_aborted(%RegistryUpload{} = registry) do
    case registry_upload(registry) do
      {:ok, upload} -> record_terminal(registry, upload, "aborted", %{})
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  @doc "Returns the active Console registry snapshot for a multipart upload, if any."
  @spec registry_for_upload(Upload.t()) :: {:ok, RegistryUpload.t()} | {:error, :not_found}
  def registry_for_upload(%Upload{id: upload_id} = upload) do
    case Repo.get_by(RegistryUpload, multipart_upload_id: upload_id, status: "active") do
      nil -> {:error, :not_found}
      registry -> {:ok, registry |> Map.put(:multipart_upload, upload) |> attach_part_stats()}
    end
  end

  @doc "Abort an active registry upload owned by the principal."
  @spec abort(String.t(), String.t()) :: :ok | {:error, term()}
  def abort(registry_id, principal_arn) do
    with :ok <- validate_uuid(registry_id) do
      query =
        from r in RegistryUpload,
          where:
            r.id == ^registry_id and r.principal_arn == ^principal_arn and r.status == "active",
          preload: [:multipart_upload]

      case Repo.one(query) do
        nil ->
          {:error, :not_found}

        %RegistryUpload{multipart_upload: %Upload{} = upload} = registry ->
          registry = attach_part_stats(registry)

          with :ok <- Multipart.abort(upload) do
            record_terminal_best_effort(registry, upload, "aborted", %{})
            :ok
          end
      end
    end
  end

  @doc "Abort an active registry upload only when it is visible in the supplied scope."
  @spec abort_scoped(String.t(), String.t(), String.t(), String.t(), keyword()) ::
          :ok | {:error, term()}
  def abort_scoped(registry_id, bucket_name, prefix, principal_arn, opts \\ []) do
    with :ok <- validate_uuid(registry_id) do
      if MapSet.member?(
           visible_registry_ids(bucket_name, prefix, principal_arn, opts),
           registry_id
         ) do
        abort(registry_id, principal_arn)
      else
        {:error, :not_found}
      end
    end
  end

  @doc "Abort a bounded set of active registry uploads owned by the principal."
  @spec abort_many([String.t()], String.t()) :: %{
          aborted: non_neg_integer(),
          not_found: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def abort_many(ids, principal_arn) when is_list(ids) do
    {selected, skipped} =
      ids
      |> normalize_abort_ids()
      |> Enum.split(@max_bulk_abort)

    selected
    |> abort_selected(principal_arn)
    |> Map.put(:skipped, length(skipped))
  end

  def abort_many(_ids, _principal_arn),
    do: %{aborted: 0, not_found: 0, failed: 0, skipped: 0}

  @doc "Abort a bounded set of active registry uploads visible in the supplied scope."
  @spec abort_many_scoped([String.t()], String.t(), String.t(), String.t(), keyword()) :: %{
          aborted: non_neg_integer(),
          not_found: non_neg_integer(),
          failed: non_neg_integer(),
          skipped: non_neg_integer()
        }
  def abort_many_scoped(ids, bucket_name, prefix, principal_arn, opts \\ [])

  def abort_many_scoped(ids, bucket_name, prefix, principal_arn, opts) when is_list(ids) do
    {selected, skipped} =
      ids
      |> normalize_abort_ids()
      |> Enum.split(@max_bulk_abort)

    visible_ids = visible_registry_ids(bucket_name, prefix, principal_arn, opts)

    {visible_selected, hidden_selected} =
      Enum.split_with(selected, &MapSet.member?(visible_ids, &1))

    visible_selected
    |> abort_selected(principal_arn)
    |> Map.update!(:not_found, &(&1 + length(hidden_selected)))
    |> Map.put(:skipped, length(skipped))
  end

  def abort_many_scoped(_ids, _bucket_name, _prefix, _principal_arn, _opts),
    do: %{aborted: 0, not_found: 0, failed: 0, skipped: 0}

  defp normalize_abort_ids(ids) do
    ids
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> Enum.uniq()
  end

  defp abort_selected(ids, principal_arn) do
    Enum.reduce(ids, %{aborted: 0, not_found: 0, failed: 0}, fn id, acc ->
      case abort(id, principal_arn) do
        :ok -> Map.update!(acc, :aborted, &(&1 + 1))
        {:error, :not_found} -> Map.update!(acc, :not_found, &(&1 + 1))
        {:error, _reason} -> Map.update!(acc, :failed, &(&1 + 1))
      end
    end)
  end

  defp visible_registry_ids(bucket_name, prefix, principal_arn, opts) do
    bucket_name
    |> list_active(prefix, principal_arn,
      scope: Keyword.get(opts, :scope),
      query: Keyword.get(opts, :query)
    )
    |> Enum.map(& &1.id)
    |> MapSet.new()
  end

  defp validate_uuid(value) when is_binary(value) do
    case Ecto.UUID.cast(value) do
      {:ok, _uuid} -> :ok
      :error -> {:error, :not_found}
    end
  end

  defp validate_uuid(_value), do: {:error, :not_found}

  defp query_prefix(_prefix, "bucket"), do: ""
  defp query_prefix(prefix, _scope) when is_binary(prefix), do: prefix
  defp query_prefix(_prefix, _scope), do: ""

  defp where_folder_scope(query, prefix, "folder") do
    deep_pattern = escape_like(prefix || "") <> "%/%"
    where(query, [row, ...], not like(row.key, ^deep_pattern))
  end

  defp where_folder_scope(query, _prefix, _scope), do: query

  defp maybe_where_terminal_state(query, nil), do: query

  defp maybe_where_terminal_state(query, terminal_state) do
    where(query, [h], h.terminal_state == ^terminal_state)
  end

  defp maybe_where_registry_search(query, nil), do: query

  defp maybe_where_registry_search(query, search) do
    pattern = "%" <> escape_like(search) <> "%"

    where(
      query,
      [r, ...],
      ilike(r.key, ^pattern) or ilike(r.file_name, ^pattern) or ilike(r.upload_id, ^pattern)
    )
  end

  defp maybe_where_history_search(query, nil), do: query

  defp maybe_where_history_search(query, search) do
    pattern = "%" <> escape_like(search) <> "%"

    where(
      query,
      [h, ...],
      ilike(h.key, ^pattern) or ilike(h.file_name, ^pattern) or ilike(h.upload_id, ^pattern)
    )
  end

  defp prune_candidate_query(policy) do
    cutoff = DateTime.add(policy.now, -policy.older_than_seconds, :second)
    query_prefix = query_prefix(policy.prefix, policy.scope)

    RegistryUpload
    |> join(:inner, [r], u in assoc(r, :multipart_upload))
    |> where([r, u], r.status == "active" and u.inserted_at <= ^cutoff)
    |> maybe_where_bucket(policy.bucket)
    |> where([r, _u], like(r.key, ^(escape_like(query_prefix) <> "%")))
    |> where_folder_scope(policy.prefix, policy.scope)
    |> maybe_where_registry_search(policy.query)
    |> maybe_where_owner(policy)
    |> maybe_where_access_key(policy.access_key)
    |> maybe_where_min_file_size(policy.min_file_size)
    |> maybe_where_max_file_size(policy.max_file_size)
  end

  defp maybe_where_bucket(query, nil), do: query
  defp maybe_where_bucket(query, bucket), do: where(query, [r, ...], r.bucket_name == ^bucket)

  defp maybe_where_owner(query, %{all_owners: true}), do: query

  defp maybe_where_owner(query, %{principal_arn: principal_arn}) when is_binary(principal_arn),
    do: where(query, [r, ...], r.principal_arn == ^principal_arn)

  defp maybe_where_owner(query, _policy), do: query

  defp maybe_where_access_key(query, nil), do: query

  defp maybe_where_access_key(query, access_key),
    do: where(query, [r, ...], r.access_key == ^access_key)

  defp maybe_where_min_file_size(query, nil), do: query

  defp maybe_where_min_file_size(query, size),
    do: where(query, [r, ...], r.file_size >= ^size)

  defp maybe_where_max_file_size(query, nil), do: query

  defp maybe_where_max_file_size(query, size),
    do: where(query, [r, ...], r.file_size <= ^size)

  defp abort_prune_candidate(%RegistryUpload{} = registry, summary, policy) do
    case safe_abort_prune_candidate(registry) do
      :ok ->
        log_prune_candidate(registry, :aborted, policy)
        Map.update!(summary, :aborted, &(&1 + 1))

      {:error, :not_found} ->
        log_prune_candidate(registry, :not_found, policy)
        Map.update!(summary, :not_found, &(&1 + 1))

      {:error, reason} ->
        log_prune_candidate(registry, :failed, policy, reason)

        summary
        |> Map.update!(:failed, &(&1 + 1))
        |> Map.update!(:errors, &[prune_error(registry, reason) | &1])
    end
  end

  defp safe_abort_prune_candidate(%RegistryUpload{} = registry) do
    abort(registry.id, registry.principal_arn)
  rescue
    exception -> {:error, {:exception, exception.__struct__, Exception.message(exception)}}
  catch
    kind, reason -> {:error, {kind, reason}}
  end

  defp prune_summary(policy, matched, selected) do
    %{
      dry_run: policy.dry_run,
      bucket: policy.bucket,
      prefix: policy.prefix,
      scope: policy.scope,
      query: policy.query,
      principal_arn: policy.principal_arn,
      access_key: policy.access_key,
      all_owners: policy.all_owners,
      older_than_seconds: policy.older_than_seconds,
      min_file_size: policy.min_file_size,
      max_file_size: policy.max_file_size,
      limit: policy.limit,
      matched: matched,
      selected: selected,
      skipped: max(matched - selected, 0),
      would_abort: 0,
      aborted: 0,
      not_found: 0,
      failed: 0,
      errors: []
    }
  end

  defp prune_error(%RegistryUpload{} = registry, reason) do
    %{
      registry_id: registry.id,
      bucket: registry.bucket_name,
      key: registry.key,
      upload_id: registry.upload_id,
      principal_arn: registry.principal_arn,
      reason: inspect(reason)
    }
  end

  defp log_prune_candidate(registry, status, policy, reason \\ nil)

  defp log_prune_candidate(%RegistryUpload{} = registry, status, policy, nil) do
    Logger.info("console direct multipart prune candidate",
      action: :console_direct_multipart_prune,
      bucket: registry.bucket_name,
      key: registry.key,
      upload_id: registry.upload_id,
      registry_id: registry.id,
      principal_arn: registry.principal_arn,
      status: status,
      dry_run: policy.dry_run
    )
  end

  defp log_prune_candidate(%RegistryUpload{} = registry, status, policy, reason) do
    Logger.warning("console direct multipart prune candidate failed",
      action: :console_direct_multipart_prune,
      bucket: registry.bucket_name,
      key: registry.key,
      upload_id: registry.upload_id,
      registry_id: registry.id,
      principal_arn: registry.principal_arn,
      status: status,
      dry_run: policy.dry_run,
      reason: inspect(reason)
    )
  end

  defp normalize_prune_policy(opts) do
    dry_run = truthy?(Keyword.get(opts, :dry_run, true))
    confirm_abort = truthy?(Keyword.get(opts, :confirm_abort, false))
    all_owners = truthy?(Keyword.get(opts, :all_owners, false))

    with {:ok, now} <- normalize_prune_now(Keyword.get(opts, :now, DateTime.utc_now())),
         {:ok, older_than_seconds} <-
           positive_integer(Keyword.get(opts, :older_than_seconds), :older_than_seconds),
         {:ok, limit} <- prune_limit(Keyword.get(opts, :limit, @prune_default_limit)),
         {:ok, min_file_size} <- optional_non_negative_integer(Keyword.get(opts, :min_file_size)),
         {:ok, max_file_size} <- optional_non_negative_integer(Keyword.get(opts, :max_file_size)),
         :ok <- validate_size_bounds(min_file_size, max_file_size),
         {:ok, bucket} <- optional_non_empty_string(Keyword.get(opts, :bucket)),
         {:ok, principal_arn} <- optional_non_empty_string(Keyword.get(opts, :principal_arn)),
         {:ok, access_key} <- optional_non_empty_string(Keyword.get(opts, :access_key)),
         :ok <- validate_prune_owner_scope(all_owners, principal_arn, access_key),
         :ok <- validate_prune_confirmation(dry_run, confirm_abort) do
      {:ok,
       %{
         now: now,
         dry_run: dry_run,
         confirm_abort: confirm_abort,
         all_owners: all_owners,
         older_than_seconds: older_than_seconds,
         limit: limit,
         bucket: bucket,
         prefix: normalize_prefix(Keyword.get(opts, :prefix, "")),
         scope: normalize_scope(Keyword.get(opts, :scope, "recursive"), "recursive"),
         query: normalize_search_query(Keyword.get(opts, :query)),
         principal_arn: principal_arn,
         access_key: access_key,
         min_file_size: min_file_size,
         max_file_size: max_file_size
       }}
    end
  end

  defp normalize_prune_now(%DateTime{} = now), do: {:ok, now}
  defp normalize_prune_now(_now), do: {:error, :invalid_now}

  defp validate_prune_confirmation(true = _dry_run, _confirm_abort), do: :ok
  defp validate_prune_confirmation(false = _dry_run, true = _confirm_abort), do: :ok

  defp validate_prune_confirmation(false = _dry_run, false = _confirm_abort),
    do: {:error, :confirm_abort_required}

  defp validate_prune_owner_scope(true, principal_arn, access_key)
       when is_binary(principal_arn) or is_binary(access_key),
       do: {:error, :ambiguous_owner_scope}

  defp validate_prune_owner_scope(true = _all_owners, _principal_arn, _access_key), do: :ok

  defp validate_prune_owner_scope(false, principal_arn, access_key)
       when is_binary(principal_arn) or is_binary(access_key),
       do: :ok

  defp validate_prune_owner_scope(false, _principal_arn, _access_key),
    do: {:error, :owner_scope_required}

  defp validate_size_bounds(nil, _max_file_size), do: :ok
  defp validate_size_bounds(_min_file_size, nil), do: :ok

  defp validate_size_bounds(min_file_size, max_file_size) when min_file_size <= max_file_size,
    do: :ok

  defp validate_size_bounds(_min_file_size, _max_file_size), do: {:error, :invalid_size_range}

  defp optional_non_empty_string(nil), do: {:ok, nil}
  defp optional_non_empty_string(""), do: {:ok, nil}

  defp optional_non_empty_string(value) when is_binary(value) do
    value = String.trim(value)
    if value == "", do: {:ok, nil}, else: {:ok, value}
  end

  defp optional_non_empty_string(_value), do: {:error, :invalid_string}

  defp normalize_prefix(value) when is_binary(value), do: value
  defp normalize_prefix(_value), do: ""

  defp positive_integer(value, _field) when is_integer(value) and value > 0, do: {:ok, value}

  defp positive_integer(value, field) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> {:ok, integer}
      _other -> {:error, {:invalid_positive_integer, field}}
    end
  end

  defp positive_integer(_value, field), do: {:error, {:invalid_positive_integer, field}}

  defp optional_non_negative_integer(nil), do: {:ok, nil}

  defp optional_non_negative_integer(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp optional_non_negative_integer(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, :invalid_non_negative_integer}
    end
  end

  defp optional_non_negative_integer(_value), do: {:error, :invalid_non_negative_integer}

  defp prune_limit(value) do
    with {:ok, limit} <- positive_integer(value, :limit) do
      {:ok, min(limit, @prune_max_limit)}
    end
  end

  defp truthy?(value) when value in [true, "true", "1", 1, true], do: true
  defp truthy?(_value), do: false

  defp registry_upload(%RegistryUpload{multipart_upload: %Upload{} = upload}), do: {:ok, upload}

  defp registry_upload(%RegistryUpload{multipart_upload_id: upload_id}) do
    case Repo.get(Upload, upload_id) do
      nil -> {:error, :not_found}
      upload -> {:ok, upload}
    end
  end

  defp record_terminal_best_effort(registry, upload, terminal_state, attrs) do
    case record_terminal(registry, upload, terminal_state, attrs) do
      {:ok, _history} ->
        :ok

      :ok ->
        :ok

      {:error, reason} ->
        Logger.warning("console direct multipart history write failed",
          action: :console_direct_multipart_history,
          bucket: registry.bucket_name,
          key: registry.key,
          upload_id: registry.upload_id,
          terminal_state: terminal_state,
          reason: inspect(reason)
        )

        :ok
    end
  end

  defp record_terminal(%RegistryUpload{} = registry, %Upload{} = upload, terminal_state, attrs) do
    case Repo.get_by(History, upload_id: registry.upload_id) do
      %History{} ->
        :ok

      nil ->
        insert_terminal_history(registry, upload, terminal_state, attrs)
    end
  end

  defp insert_terminal_history(registry, upload, terminal_state, attrs) do
    registry = ensure_part_stats(registry)
    now = DateTime.utc_now()
    uploaded_size = Map.get(attrs, :size) || registry.uploaded_size || 0

    history_attrs = %{
      upload_id: registry.upload_id,
      terminal_state: terminal_state,
      bucket_name: registry.bucket_name,
      key: registry.key,
      principal_arn: registry.principal_arn,
      access_key: registry.access_key,
      file_name: registry.file_name,
      file_size: registry.file_size,
      file_last_modified: registry.file_last_modified,
      part_size: registry.part_size,
      part_count: registry.part_count || 0,
      uploaded_size: uploaded_size,
      etag: Map.get(attrs, :etag),
      version_id: Map.get(attrs, :version_id),
      content_type: upload.content_type,
      storage_class: upload.storage_class,
      request_payer: registry.request_payer || false,
      sse_algorithm: upload.sse_algorithm,
      sse_customer_key_required: upload.sse_algorithm == "SSE-C",
      terminal_at: now
    }

    case %History{} |> History.changeset(history_attrs) |> Repo.insert() do
      {:ok, %History{} = history} ->
        prune_history(history.principal_arn, history.bucket_name)
        {:ok, history}

      {:error, _reason} = error ->
        error
    end
  end

  defp prune_history(principal_arn, bucket_name) do
    limit = history_retention_limit()

    if limit > 0 do
      old_ids =
        History
        |> where([h], h.principal_arn == ^principal_arn and h.bucket_name == ^bucket_name)
        |> order_by([h], desc: h.terminal_at, desc: h.inserted_at)
        |> offset(^limit)
        |> select([h], h.id)

      Repo.delete_all(from h in History, where: h.id in subquery(old_ids))
    end

    :ok
  end

  defp attach_part_stats([]), do: []

  defp attach_part_stats(rows) when is_list(rows) do
    ids = Enum.map(rows, & &1.multipart_upload_id)
    stats = part_stats(ids)

    Enum.map(rows, &attach_part_stats(&1, stats))
  end

  defp attach_part_stats(%RegistryUpload{} = row) do
    stats = part_stats([row.multipart_upload_id])
    attach_part_stats(row, stats)
  end

  defp attach_part_stats(%RegistryUpload{} = row, stats) do
    {part_count, uploaded_size} = Map.get(stats, row.multipart_upload_id, {0, 0})
    %{row | part_count: part_count, uploaded_size: uploaded_size}
  end

  defp ensure_part_stats(
         %RegistryUpload{part_count: part_count, uploaded_size: uploaded_size} = row
       )
       when is_integer(part_count) and is_integer(uploaded_size),
       do: row

  defp ensure_part_stats(%RegistryUpload{} = row), do: attach_part_stats(row)

  defp part_stats([]), do: %{}

  defp part_stats(upload_ids) do
    Part
    |> where([p], p.upload_id in ^upload_ids)
    |> group_by([p], p.upload_id)
    |> select([p], {p.upload_id, count(p.id), coalesce(sum(p.size), 0)})
    |> Repo.all()
    |> Map.new(fn {upload_id, count, size} ->
      {upload_id, {integer_value(count), integer_value(size)}}
    end)
  end

  defp integer_value(%Decimal{} = value), do: Decimal.to_integer(value)
  defp integer_value(value) when is_integer(value), do: value
  defp integer_value(nil), do: 0

  defp normalize_history_limit(value) when is_integer(value) and value > 0, do: value

  defp normalize_history_limit(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 -> integer
      _other -> @history_default_limit
    end
  end

  defp normalize_history_limit(_value), do: @history_default_limit

  defp history_retention_limit do
    :maxio
    |> Application.get_env(:console, [])
    |> Keyword.get(:direct_multipart_history_limit, @history_retention_default)
    |> normalize_history_limit()
  end

  defp escape_like(str) do
    str
    |> String.replace("\\", "\\\\")
    |> String.replace("%", "\\%")
    |> String.replace("_", "\\_")
  end

  defp normalize_registry_intent_attrs(attrs) do
    with {:ok, file_name} <- parse_file_name(Map.get(attrs, :file_name)),
         {:ok, file_size} <- parse_file_size(Map.get(attrs, :file_size)),
         {:ok, file_last_modified} <-
           parse_file_last_modified(Map.get(attrs, :file_last_modified)),
         {:ok, part_size} <- parse_part_size(Map.get(attrs, :part_size), file_size),
         {:ok, request_payer} <- parse_request_payer(Map.get(attrs, :request_payer, false)) do
      {:ok,
       %{
         file_name: file_name,
         file_size: file_size,
         file_last_modified: file_last_modified,
         part_size: part_size,
         request_payer: request_payer
       }}
    end
  end

  defp parse_file_name(value) when is_binary(value) do
    value = String.trim(value)

    cond do
      value == "" -> {:error, :invalid_file_name}
      byte_size(value) > @max_file_name_bytes -> {:error, :invalid_file_name}
      String.contains?(value, ["\r", "\n", <<0>>]) -> {:error, :invalid_file_name}
      true -> {:ok, value}
    end
  end

  defp parse_file_name(_value), do: {:error, :invalid_file_name}

  defp parse_file_size(value) when is_integer(value) and value in 1..@max_object_size,
    do: {:ok, value}

  defp parse_file_size(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer in 1..@max_object_size -> {:ok, integer}
      _other -> {:error, :invalid_size}
    end
  end

  defp parse_file_size(_value), do: {:error, :invalid_size}

  defp parse_file_last_modified(value) when is_integer(value) and value >= 0,
    do: {:ok, value}

  defp parse_file_last_modified(value) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} when integer >= 0 -> {:ok, integer}
      _other -> {:error, :invalid_file_last_modified}
    end
  end

  defp parse_file_last_modified(_value), do: {:error, :invalid_file_last_modified}

  defp parse_part_size(value, size) when is_binary(value) do
    case Integer.parse(value) do
      {integer, ""} -> parse_part_size(integer, size)
      _other -> {:error, :invalid_part_size}
    end
  end

  defp parse_part_size(value, size) when is_integer(value) do
    cond do
      value < 1 -> {:error, :invalid_part_size}
      value > @max_part_size -> {:error, :invalid_part_size}
      div(size + value - 1, value) > @max_parts -> {:error, :too_many_parts}
      true -> {:ok, value}
    end
  end

  defp parse_part_size(_value, _size), do: {:error, :invalid_part_size}

  defp parse_request_payer(value) when value in [true, "true", "1", "requester"],
    do: {:ok, true}

  defp parse_request_payer(value) when value in [false, nil, "", "false", "0"],
    do: {:ok, false}

  defp parse_request_payer(_value), do: {:error, :invalid_request_payer}

  defp principal_arn(principal) do
    case Map.get(principal, :arn) || Map.get(principal, "arn") do
      arn when is_binary(arn) and arn != "" -> {:ok, arn}
      _other -> {:error, :invalid_registry_intent}
    end
  end

  defp principal_access_key(principal) do
    case Map.get(principal, :session_access_key) || Map.get(principal, "session_access_key") ||
           Map.get(principal, :access_key) || Map.get(principal, "access_key") do
      access_key when is_binary(access_key) and access_key != "" -> {:ok, access_key}
      _other -> {:error, :invalid_registry_intent}
    end
  end
end
