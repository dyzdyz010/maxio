defmodule Maxio.Compat.StreamingStressConfig do
  @moduledoc """
  Shared parameters for the opt-in streaming stress compatibility suite.

  Defaults stay small enough for local/precommit execution while env overrides
  let operators turn the same suite into a larger soak run and keep the artifact
  parameter record aligned with what the tests execute.
  """

  @object_bytes_env "MAXIO_STREAMING_STRESS_OBJECT_BYTES"
  @repetitions_env "MAXIO_STREAMING_STRESS_REPETITIONS"
  @chunk_sizes_env "MAXIO_STREAMING_STRESS_CHUNK_SIZES"
  @failure_attempts_env "MAXIO_STREAMING_STRESS_FAILURE_ATTEMPTS"
  @concurrency_env "MAXIO_STREAMING_STRESS_CONCURRENCY"
  @multipart_uploads_env "MAXIO_STREAMING_STRESS_MULTIPART_UPLOADS"

  @default_object_bytes 4 * 1024 * 1024
  @default_repetitions 3
  @default_chunk_sizes [64 * 1024, 256 * 1024, 1024 * 1024]
  @default_failure_attempts 3
  @default_concurrency 2
  @default_multipart_uploads 2

  def load!(env_fun \\ &System.get_env/1) do
    %{
      object_bytes: positive_env!(env_fun, @object_bytes_env, @default_object_bytes),
      repetitions: positive_env!(env_fun, @repetitions_env, @default_repetitions),
      chunk_sizes: chunk_sizes_env!(env_fun, @chunk_sizes_env, @default_chunk_sizes),
      failure_attempts: positive_env!(env_fun, @failure_attempts_env, @default_failure_attempts),
      concurrency: positive_env!(env_fun, @concurrency_env, @default_concurrency),
      multipart_uploads:
        positive_env!(env_fun, @multipart_uploads_env, @default_multipart_uploads)
    }
  end

  def artifact_evidence!(env_fun \\ &System.get_env/1) do
    config = load!(env_fun)

    %{
      "profile" => "local_safe_default_with_env_overrides",
      "env" => %{
        "object_bytes" => @object_bytes_env,
        "repetitions" => @repetitions_env,
        "chunk_sizes" => @chunk_sizes_env,
        "failure_attempts" => @failure_attempts_env,
        "concurrency" => @concurrency_env,
        "multipart_uploads" => @multipart_uploads_env
      },
      "parameters" => %{
        "object_bytes" => config.object_bytes,
        "repetitions" => config.repetitions,
        "chunk_sizes" => config.chunk_sizes,
        "failure_attempts" => config.failure_attempts,
        "concurrency" => config.concurrency,
        "multipart_uploads" => config.multipart_uploads
      },
      "scenarios" => [
        "repeated aws-chunked PutObject large decoded-byte verification",
        "multipart aws-chunked checksum trailer retry/no-pollution verification",
        "concurrent aws-chunked PutObject decoded-byte verification",
        "concurrent multipart aws-chunked retry and complete verification"
      ]
    }
  end

  defp positive_env!(env_fun, name, default) do
    case blank_to_nil(env_fun.(name)) do
      nil -> default
      value -> parse_positive!(name, value)
    end
  end

  defp chunk_sizes_env!(env_fun, name, default) do
    case blank_to_nil(env_fun.(name)) do
      nil ->
        default

      value ->
        sizes =
          value
          |> String.split(",", trim: true)
          |> Enum.map(&parse_positive!(name, String.trim(&1)))

        if sizes == [] do
          raise ArgumentError, "#{name} must contain at least one positive integer"
        end

        sizes
    end
  end

  defp parse_positive!(name, value) do
    case Integer.parse(value) do
      {integer, ""} when integer > 0 ->
        integer

      _other ->
        raise ArgumentError, "#{name} must be a positive integer, got #{inspect(value)}"
    end
  end

  defp blank_to_nil(nil), do: nil

  defp blank_to_nil(value) when is_binary(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end
end
