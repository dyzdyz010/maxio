defmodule Maxio.ObjectAclSidecar do
  @moduledoc """
  Metadata-only object ACL sidecar mutation.

  PutObjectAcl changes object metadata, so under Route B it must mutate the same sidecar
  authority that scanner later uses to reconcile PG. This module reads sidecar copies,
  establishes a canonical target version by read quorum, updates ACL fields plus
  generation, and writes the full meta back to write quorum endpoints.
  """

  alias Maxio.{MetaReconcile, ObjectMeta, Sidecar, Storage}
  alias Maxio.Cluster.{Paths, Router, Topology, Transport}
  alias Maxio.Storage.Erasure.Config

  @type update_result ::
          {:ok, non_neg_integer()}
          | {:error, :not_found | :read_quorum | :write_quorum | :invalid_key | :no_topology}

  @spec update(String.t(), String.t(), String.t(), String.t(), map(), keyword()) ::
          update_result()
  def update(bucket, key, version_id, canned, grants_doc, opts \\ []) do
    opts = ObjectMeta.put_effective_topology(opts)

    with {:ok, rel} <- Paths.object_rel(bucket, key, version_id),
         {:ok, %{endpoints: endpoints, read_quorum: rq, write_quorum: wq}} <-
           endpoint_config(bucket, key, opts) do
      transport = Transport.impl(opts)
      copies = read_sidecars(transport, endpoints, rel)

      case MetaReconcile.reconcile(copies, rq, {:version, version_id}) do
        {:ok, entry, _divergent} ->
          case canonical_full_meta(entry, copies) do
            nil ->
              {:error, :read_quorum}

            meta ->
              {updated_meta, generation} = update_acl(meta, entry, version_id, canned, grants_doc)

              case commit_sidecars(transport, endpoints, rel, updated_meta, wq, opts) do
                :ok -> {:ok, generation}
                {:error, :write_quorum} -> {:error, :write_quorum}
              end
          end

        {:error, :read_quorum} ->
          if Enum.all?(copies, &(&1 == :missing)),
            do: {:error, :not_found},
            else: {:error, :read_quorum}
      end
    else
      {:error, :invalid_key} -> {:error, :invalid_key}
      {:error, :no_topology} -> {:error, :no_topology}
    end
  end

  defp read_sidecars(transport, endpoints, rel) do
    Enum.map(endpoints, fn {node, drive} ->
      case transport.get_sidecar(node, Path.join(drive, rel)) do
        {:ok, meta} -> %{node: node, drive: drive, meta: meta}
        {:error, _} -> :missing
      end
    end)
  end

  defp canonical_full_meta(entry, copies) do
    sig = Sidecar.signature(entry)

    Enum.find_value(copies, fn
      %{meta: %{"versions" => versions} = meta} when is_list(versions) ->
        if Enum.any?(versions, fn version -> Sidecar.signature(version) == sig end) do
          meta
        end

      _ ->
        nil
    end)
  end

  defp update_acl(meta, entry, version_id, canned, grants_doc) do
    generation = next_generation(entry)

    updated_entry =
      entry
      |> Map.put("acl_canned", canned)
      |> Map.put("acl_grants", grants_doc)
      |> Map.put("generation", generation)

    versions =
      meta
      |> Map.get("versions", [])
      |> Enum.map(fn
        %{"version_id" => ^version_id} -> updated_entry
        other -> other
      end)

    {Map.put(meta, "versions", versions), generation}
  end

  defp next_generation(%{"generation" => generation}) when is_integer(generation),
    do: generation + 1

  defp next_generation(_entry), do: 1

  defp commit_sidecars(transport, endpoints, rel, meta, write_quorum, opts) do
    prepared = prepare_sidecars(transport, endpoints, rel, meta)

    if length(prepared) < write_quorum do
      cleanup_prepared(transport, prepared)
      {:error, :write_quorum}
    else
      commit_opts =
        opts
        |> Keyword.take([:fsync, :rename_fun])
        |> Keyword.put(:meta_only, true)

      committed =
        prepared
        |> Task.async_stream(
          fn %{node: node, tmp_dir: tmp_dir, final_dir: final_dir} = target ->
            case transport.commit_object(node, tmp_dir, final_dir, commit_opts) do
              :ok -> {:ok, target}
              _ -> {:error, target}
            end
          end,
          timeout: :infinity,
          max_concurrency: max(length(prepared), 1)
        )
        |> Enum.map(fn
          {:ok, result} -> result
          _ -> :error
        end)

      ok_count = Enum.count(committed, &match?({:ok, _}, &1))

      committed
      |> Enum.each(fn
        {:error, target} -> cleanup_prepared(transport, [target])
        _ -> :ok
      end)

      if ok_count >= write_quorum, do: :ok, else: {:error, :write_quorum}
    end
  end

  defp prepare_sidecars(transport, endpoints, rel, meta) do
    endpoints
    |> Task.async_stream(
      fn {node, drive} ->
        prepare_sidecar(transport, node, drive, rel, meta)
      end,
      timeout: :infinity,
      max_concurrency: max(length(endpoints), 1)
    )
    |> Enum.flat_map(fn
      {:ok, {:ok, target}} -> [target]
      _ -> []
    end)
  end

  defp prepare_sidecar(transport, node, drive, rel, meta) do
    case transport.begin_tmp(node, drive) do
      {:ok, tmp_dir} ->
        case transport.put_sidecar(node, tmp_dir, meta) do
          :ok ->
            {:ok, %{node: node, tmp_dir: tmp_dir, final_dir: Path.join(drive, rel)}}

          _ ->
            _ = transport.delete_shard(node, tmp_dir)
            :error
        end

      _ ->
        :error
    end
  end

  defp cleanup_prepared(transport, prepared) do
    Enum.each(prepared, fn %{node: node, tmp_dir: tmp_dir} ->
      _ = transport.delete_shard(node, tmp_dir)
      :ok
    end)
  end

  defp endpoint_config(bucket, key, opts) do
    case Keyword.get(opts, :topology) do
      %{} = topology ->
        set_id = Router.set_for(bucket, key, topology)
        endpoints = Topology.endpoints_from(topology, set_id)
        {read_quorum, write_quorum} = quorums(topology.data_shards, topology.parity_shards)
        {:ok, %{endpoints: endpoints, read_quorum: read_quorum, write_quorum: write_quorum}}

      _ ->
        configured_endpoint_config(bucket, key, opts)
    end
  rescue
    _ -> {:error, :no_topology}
  end

  defp configured_endpoint_config(bucket, key, opts) do
    cond do
      Topology.configured?() ->
        set_id = Router.set_for(bucket, key)
        endpoints = Topology.endpoints(set_id)
        ec = Topology.ec_params()
        {read_quorum, write_quorum} = quorums(ec[:data_shards], ec[:parity_shards])
        {:ok, %{endpoints: endpoints, read_quorum: read_quorum, write_quorum: write_quorum}}

      Storage.backend() == Maxio.Storage.ErasureCoded ->
        cfg =
          Config.load!(Keyword.take(opts, [:drives, :data_shards, :parity_shards, :block_size]))

        endpoints = Enum.map(cfg.drives, fn drive -> {Node.self(), drive} end)

        {:ok,
         %{endpoints: endpoints, read_quorum: cfg.read_quorum, write_quorum: cfg.write_quorum}}

      true ->
        {:error, :no_topology}
    end
  end

  defp quorums(k, 0) when is_integer(k) and k > 0, do: {k, k}

  defp quorums(k, m) when is_integer(k) and is_integer(m) and k > 0 and m >= 0 do
    n = k + m
    write_quorum = if m == div(n, 2), do: k + 1, else: k
    {k, write_quorum}
  end
end
