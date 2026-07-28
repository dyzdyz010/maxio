defmodule Maxio.Compat.StreamingStressConfigTest do
  use ExUnit.Case, async: true

  alias Maxio.Compat.StreamingStressConfig

  test "load! returns local-safe defaults" do
    config = StreamingStressConfig.load!(fn _name -> nil end)

    assert config == %{
             object_bytes: 4 * 1024 * 1024,
             repetitions: 3,
             chunk_sizes: [64 * 1024, 256 * 1024, 1024 * 1024],
             failure_attempts: 3,
             concurrency: 2,
             multipart_uploads: 2
           }
  end

  test "load! applies positive environment overrides" do
    env = %{
      "MAXIO_STREAMING_STRESS_OBJECT_BYTES" => "8388608",
      "MAXIO_STREAMING_STRESS_REPETITIONS" => "5",
      "MAXIO_STREAMING_STRESS_CHUNK_SIZES" => "131072, 524288",
      "MAXIO_STREAMING_STRESS_FAILURE_ATTEMPTS" => "4",
      "MAXIO_STREAMING_STRESS_CONCURRENCY" => "3",
      "MAXIO_STREAMING_STRESS_MULTIPART_UPLOADS" => "4"
    }

    config = StreamingStressConfig.load!(&Map.get(env, &1))

    assert config.object_bytes == 8 * 1024 * 1024
    assert config.repetitions == 5
    assert config.chunk_sizes == [128 * 1024, 512 * 1024]
    assert config.failure_attempts == 4
    assert config.concurrency == 3
    assert config.multipart_uploads == 4
  end

  test "load! rejects invalid overrides" do
    env = %{"MAXIO_STREAMING_STRESS_CHUNK_SIZES" => "65536, nope"}

    assert_raise ArgumentError, ~r/MAXIO_STREAMING_STRESS_CHUNK_SIZES/, fn ->
      StreamingStressConfig.load!(&Map.get(env, &1))
    end
  end

  test "artifact evidence includes concurrency and multipart stress parameters" do
    evidence = StreamingStressConfig.artifact_evidence!(fn _name -> nil end)

    assert evidence["env"]["concurrency"] == "MAXIO_STREAMING_STRESS_CONCURRENCY"
    assert evidence["env"]["multipart_uploads"] == "MAXIO_STREAMING_STRESS_MULTIPART_UPLOADS"
    assert evidence["parameters"]["concurrency"] == 2
    assert evidence["parameters"]["multipart_uploads"] == 2

    assert "concurrent aws-chunked PutObject decoded-byte verification" in evidence["scenarios"]

    assert "concurrent multipart aws-chunked retry and complete verification" in evidence[
             "scenarios"
           ]
  end
end
