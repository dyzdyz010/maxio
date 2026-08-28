defmodule Maxio.Admin.EnvelopeTest do
  use ExUnit.Case, async: false

  import ExUnit.CaptureLog

  alias Maxio.Admin.Envelope
  alias Maxio.Auth.SigningSecret

  @fixture_dir Path.expand("../../fixtures/minio_admin_envelope", __DIR__)

  setup_all do
    madmin =
      @fixture_dir
      |> Path.join("v3_0_109_vectors.json")
      |> File.read!()
      |> Jason.decode!()

    sio =
      @fixture_dir
      |> Path.join("sio_v0_3_1_vectors.json")
      |> File.read!()
      |> Jason.decode!()

    {:ok, madmin: madmin, sio: sio}
  end

  test "signing-secret capability is opaque to inspection and JSON", %{madmin: fixture} do
    secret = SigningSecret.new(fixture["password_utf8"])

    assert inspect(secret) == "#Maxio.Auth.SigningSecret<redacted>"
    refute inspect(%{caller_secret: secret}) =~ fixture["password_utf8"]
    assert_raise Protocol.UndefinedError, fn -> Jason.encode!(secret) end
  end

  test "decrypts every pinned madmin-go algorithm and frame boundary", %{madmin: fixture} do
    secret = SigningSecret.new(fixture["password_utf8"])

    for vector <- fixture["vectors"] do
      envelope = decode_hex!(vector["envelope_hex"])
      expected = decode_hex!(vector["expected_plaintext_hex"])

      assert {:ok, ^expected} = Envelope.decrypt(secret, envelope), vector["name"]
    end
  end

  test "deterministic encryption is byte-exact with every Go oracle", %{madmin: fixture} do
    secret = SigningSecret.new(fixture["password_utf8"])
    salt = decode_hex!(fixture["salt_hex"])
    nonce = decode_hex!(fixture["base_nonce_hex"])

    for vector <- fixture["vectors"] do
      plaintext = decode_hex!(vector["expected_plaintext_hex"])
      expected = decode_hex!(vector["envelope_hex"])

      assert {:ok, ^expected} =
               Envelope.encrypt(secret, plaintext,
                 algorithm_id: vector["algorithm_id"],
                 salt: salt,
                 nonce: nonce
               ),
             vector["name"]
    end
  end

  test "matches official secure-io AES headerless stream vectors", %{sio: vectors} do
    for vector <- Enum.filter(vectors, &(&1["Algorithm"] == "AES-128-GCM")) do
      assert {:ok, plaintext} =
               Envelope.decrypt_sio(
                 :aes_gcm,
                 decode_hex!(vector["Key"]),
                 decode_hex!(vector["Nonce"]),
                 decode_hex!(vector["Ciphertext"]),
                 associated_data: decode_hex!(vector["AssociatedData"]),
                 frame_size: vector["BufSize"]
               )

      assert plaintext == decode_hex!(vector["Plaintext"])
    end
  end

  test "wrong secret, bit flips, and truncation release no plaintext", %{madmin: fixture} do
    vector = Enum.find(fixture["vectors"], &(&1["name"] == "id2_len32768"))
    envelope = decode_hex!(vector["envelope_hex"])
    secret = SigningSecret.new(fixture["password_utf8"])
    wrong = SigningSecret.new("wrong-" <> fixture["password_utf8"])

    assert {:error, :not_authentic} = Envelope.decrypt(wrong, envelope)

    <<prefix::binary-size(16_500), byte, suffix::binary>> = envelope
    tampered = prefix <> <<Bitwise.bxor(byte, 1)>> <> suffix

    assert {:error, :not_authentic} = Envelope.decrypt(secret, tampered)

    assert {:error, :not_authentic} =
             Envelope.decrypt(secret, binary_part(envelope, 0, byte_size(envelope) - 1))
  end

  test "unsupported and short envelope headers return only small error atoms" do
    secret = SigningSecret.new("maxio-envelope-secret")

    assert {:error, :unexpected_header} = Envelope.decrypt(secret, <<0, 1, 2>>)

    assert {:error, :unsupported_algorithm} =
             Envelope.decrypt(
               secret,
               :binary.copy(<<0>>, 32) <> <<255>> <> :binary.copy(<<0>>, 8)
             )
  end

  test "Argon2 and PBKDF2 request-local derivations do not escape process state", %{
    madmin: fixture
  } do
    sentinel = fixture["password_utf8"]

    for algorithm_id <- [0, 2] do
      vector = Enum.find(fixture["vectors"], &(&1["name"] == "id#{algorithm_id}_len1"))
      secret = SigningSecret.new(sentinel)
      envelope = decode_hex!(vector["envelope_hex"])
      before_dictionary = Process.info(self(), :dictionary)

      assert 1 == :erlang.trace(self(), true, [:procs, :send])

      result =
        try do
          Envelope.decrypt(secret, envelope)
        after
          :erlang.trace(self(), false, [:procs, :send])
        end

      assert {:ok, <<17>>} = result
      refute inspect(result) =~ sentinel
      assert Process.info(self(), :dictionary) == before_dictionary
      refute_receive {:trace, _, :spawn, _, _}
      refute_receive {:trace, _, :send, _, _}
      refute state_contains_secret?(Application.get_all_env(:maxio), sentinel)
      refute state_contains_secret?(:persistent_term.get(), sentinel)
      refute ets_contains_secret?(sentinel)

      log =
        capture_log(fn ->
          assert {:error, :not_authentic} =
                   Envelope.decrypt(SigningSecret.new("wrong"), envelope)
        end)

      refute log =~ sentinel
    end
  end

  defp decode_hex!(hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, decoded} -> decoded
      :error -> raise "invalid fixture hex"
    end
  end

  defp ets_contains_secret?(secret) do
    Enum.any?(:ets.all(), fn table ->
      try do
        state_contains_secret?(:ets.tab2list(table), secret)
      rescue
        ArgumentError -> false
      end
    end)
  end

  defp state_contains_secret?(term, secret) when is_binary(term), do: term == secret

  defp state_contains_secret?(term, secret) when is_list(term),
    do: Enum.any?(term, &state_contains_secret?(&1, secret))

  defp state_contains_secret?(term, secret) when is_tuple(term),
    do: term |> Tuple.to_list() |> state_contains_secret?(secret)

  defp state_contains_secret?(%{__struct__: _module} = term, secret),
    do: term |> Map.from_struct() |> state_contains_secret?(secret)

  defp state_contains_secret?(term, secret) when is_map(term),
    do:
      Enum.any?(term, fn {key, value} ->
        state_contains_secret?(key, secret) or state_contains_secret?(value, secret)
      end)

  defp state_contains_secret?(_term, _secret), do: false
end
