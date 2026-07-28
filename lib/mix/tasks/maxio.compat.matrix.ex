defmodule Mix.Tasks.Maxio.Compat.Matrix do
  @shortdoc "Run the S3 compatibility matrix harness"
  @moduledoc """
  Run the S3 compatibility matrix harness and write a versioned JSON artifact.

      mix maxio.compat.matrix
      mix maxio.compat.matrix --json --fail-on-attention
      mix maxio.compat.matrix --suite authz_matrix --skip-external-probes
      mix maxio.compat.matrix --include-external-smoke --no-internal-suites

  Defaults run internal self-signed S3 compatibility suites and record external
  aws-cli/mc/boto3 availability evidence. Missing external clients are
  reporting-only unless `--fail-on-attention` or `--strict` is explicit.

  External smoke checks are explicit opt-in via `--include-external-smoke`.
  They use an already-running S3 endpoint and credentials from flags, env, or
  application config; this task does not start Maxio for those checks. The
  smoke matrix covers bucket lifecycle, object metadata, ranged reads, copy,
  and cleanup where the selected external client supports those operations.
  """

  use Mix.Task

  alias Maxio.Compat.Matrix

  @impl true
  def run(args) do
    case Matrix.run(args) do
      {:ok, result} ->
        Matrix.print_result(result)

      {:error, %{exit_code: 64} = result} ->
        Matrix.print_result(result)
        Mix.raise("compat matrix usage error")

      {:error, result} ->
        Matrix.print_result(result)
        Mix.raise("compat matrix #{result.gate_status}")
    end
  end
end
