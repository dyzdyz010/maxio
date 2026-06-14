defmodule Maxio.IAM.MFADeleteVerifier do
  @moduledoc """
  DB-backed TOTP verifier for S3 MFA Delete.

  The S3 protocol gate remains in `Maxio.S3.MFADelete`; this module only checks
  whether the supplied serial/code is valid for the root principal.
  """
  @behaviour Maxio.S3.MFADelete.Verifier

  alias Maxio.IAM
  alias Maxio.S3.Log

  @impl true
  def verify(%{type: :root} = principal, serial, code) do
    case IAM.verify_mfa_device(principal, serial, code, consume: true) do
      :ok ->
        Log.info("mfa delete verifier accepted",
          principal_arn: principal[:arn],
          mfa_serial_hash: serial_hash(serial),
          mfa_outcome: :accepted
        )

        :ok

      {:error, reason} ->
        Log.warn("mfa delete verifier rejected",
          principal_arn: principal[:arn],
          mfa_serial_hash: serial_hash(serial),
          mfa_outcome: :rejected,
          mfa_reason: reason,
          reason: reason
        )

        {:error, reason}
    end
  rescue
    error ->
      Log.error("mfa delete verifier failed",
        principal_arn: principal[:arn],
        mfa_serial_hash: serial_hash(serial),
        mfa_outcome: :failed,
        mfa_reason: error.__struct__,
        reason: :mfa_verifier_failed
      )

      {:error, :mfa_verifier_failed}
  end

  def verify(principal, serial, _code) do
    Log.warn("mfa delete verifier rejected",
      principal_arn: principal_arn(principal),
      mfa_serial_hash: serial_hash(serial),
      mfa_outcome: :rejected,
      mfa_reason: :mfa_delete_requires_root,
      reason: :mfa_delete_requires_root
    )

    {:error, :mfa_delete_requires_root}
  end

  defp serial_hash(serial) when is_binary(serial) do
    :crypto.hash(:sha256, serial) |> Base.encode16(case: :lower)
  end

  defp serial_hash(_serial), do: nil

  defp principal_arn(%{arn: arn}) when is_binary(arn), do: arn
  defp principal_arn(%{"arn" => arn}) when is_binary(arn), do: arn
  defp principal_arn(_principal), do: nil
end
