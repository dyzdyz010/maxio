defmodule Maxio.MetadataTest do
  use ExUnit.Case, async: true

  alias Maxio.Metadata
  alias Maxio.S3.Error

  describe "parse_headers/1" do
    test "keeps the first value for duplicate x-amz-meta names" do
      assert %{"trace" => "first"} =
               Metadata.parse_headers([
                 {"x-amz-meta-trace", "first"},
                 {"x-amz-meta-trace", "second"}
               ])
    end

    test "keeps the first value across case and x-minio-meta aliases" do
      assert %{"trace" => "amz-first"} =
               Metadata.parse_headers([
                 {"X-Amz-Meta-Trace", "amz-first"},
                 {"x-minio-meta-trace", "minio-second"},
                 {"x-amz-meta-TRACE", "amz-third"}
               ])
    end

    test "ignores empty suffix metadata headers while parsing" do
      assert %{"trace" => "ok"} =
               Metadata.parse_headers([
                 {"x-amz-meta-", "ignored"},
                 {"x-minio-meta-", "also-ignored"},
                 {"x-amz-meta-trace", "ok"}
               ])
    end
  end

  describe "validate_headers!/1" do
    test "accepts total request headers at exactly 8 KiB" do
      assert :ok =
               Metadata.validate_headers!([
                 {"x-pad", String.duplicate("z", Metadata.max_header_size() - byte_size("x-pad"))}
               ])
    end

    test "rejects total request headers above 8 KiB" do
      err =
        assert_raise Error, fn ->
          Metadata.validate_headers!([
            {"x-pad", String.duplicate("z", Metadata.max_header_size() - byte_size("x-pad") + 1)}
          ])
        end

      assert err.code == "MetadataTooLarge"
    end

    test "accepts x-minio-meta-* user metadata at exactly 2 KiB" do
      key = "x-minio-meta-big"

      assert :ok =
               Metadata.validate_headers!([
                 {key, String.duplicate("x", Metadata.max_size() - byte_size(key))}
               ])
    end

    test "rejects x-minio-meta-* user metadata above 2 KiB" do
      key = "x-minio-meta-big"

      err =
        assert_raise Error, fn ->
          Metadata.validate_headers!([
            {key, String.duplicate("x", Metadata.max_size() - byte_size(key) + 1)}
          ])
        end

      assert err.code == "MetadataTooLarge"
    end

    test "counts empty-suffix MinIO metadata headers for request-wide size parity" do
      key = "x-minio-meta-"

      err =
        assert_raise Error, fn ->
          Metadata.validate_headers!([
            {key, String.duplicate("x", Metadata.max_size() - byte_size(key) + 1)}
          ])
        end

      assert err.code == "MetadataTooLarge"
    end

    test "counts duplicate metadata headers toward the 2 KiB user metadata limit" do
      key = "x-amz-meta-dupe"
      value = String.duplicate("x", div(Metadata.max_size() - byte_size(key), 2))

      err =
        assert_raise Error, fn ->
          Metadata.validate_headers!([
            {key, value},
            {key, value},
            {key, "overflow"}
          ])
        end

      assert err.code == "MetadataTooLarge"
    end

    test "counts x-amz-meta and x-minio-meta aliases toward the same 2 KiB limit" do
      amz_key = "x-amz-meta-dupe"
      minio_key = "x-minio-meta-dupe"
      value = String.duplicate("x", Metadata.max_size() - byte_size(amz_key))

      err =
        assert_raise Error, fn ->
          Metadata.validate_headers!([
            {amz_key, value},
            {minio_key, "overflow"}
          ])
        end

      assert err.code == "MetadataTooLarge"
    end
  end
end
