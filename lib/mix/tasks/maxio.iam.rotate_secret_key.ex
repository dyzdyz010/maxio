defmodule Mix.Tasks.Maxio.Iam.RotateSecretKey do
  @shortdoc "Dry-run or rotate the IAM signing-secret envelope key"
  @moduledoc """
  Rotates the current IAM signing-secret envelope key through a writable local
  keyring file.

  The task is dry-run by default. A real rotation requires `--confirm`.

      mix maxio.iam.rotate_secret_key --keyring-file priv/iam-keyring.json
      mix maxio.iam.rotate_secret_key --keyring-file priv/iam-keyring.json --confirm
      mix maxio.iam.rotate_secret_key --keyring-file priv/iam-keyring.json --confirm --no-rewrap
  """
  use Mix.Task

  alias Mix.Tasks.Maxio.Iam.Mfa.Output

  @usage "usage: mix maxio.iam.rotate_secret_key --keyring-file PATH [--key-id ID] [--key-b64 BASE64] [--dry-run | --confirm] [--no-rewrap] [--json]"
  @switches [
    keyring_file: :string,
    key_id: :string,
    key_b64: :string,
    dry_run: :boolean,
    confirm: :boolean,
    no_rewrap: :boolean,
    json: :boolean
  ]

  @impl true
  def run(argv) do
    {opts, rest, invalid} = OptionParser.parse(argv, strict: @switches)
    Output.reject_invalid!(rest, invalid, @usage)

    if Keyword.get(opts, :dry_run, false) and Keyword.get(opts, :confirm, false) do
      Mix.raise("--dry-run and --confirm are mutually exclusive")
    end

    Mix.Task.run("app.start")

    task_opts =
      []
      |> put_required(:keyring_file, Keyword.get(opts, :keyring_file))
      |> maybe_put(:key_id, Keyword.get(opts, :key_id))
      |> maybe_put(:key_b64, Keyword.get(opts, :key_b64))
      |> Keyword.put(:dry_run, not Keyword.get(opts, :confirm, false))
      |> Keyword.put(:rewrap, not Keyword.get(opts, :no_rewrap, false))

    case Maxio.IAM.rotate_signing_secret_key(task_opts) do
      {:ok, report} ->
        print_report(report, Keyword.get(opts, :json, false))

      {:error, report} ->
        print_report(report, Keyword.get(opts, :json, false))
        Mix.raise("iam signing secret rotation blocked: #{inspect(report.errors)}")
    end
  end

  defp put_required(_opts, _key, nil), do: Mix.raise(@usage)
  defp put_required(opts, key, value), do: Keyword.put(opts, key, value)

  defp maybe_put(opts, _key, nil), do: opts
  defp maybe_put(opts, key, value), do: Keyword.put(opts, key, value)

  defp print_report(report, true), do: Output.print_json(json_report(report))

  defp print_report(report, false) do
    IO.puts(
      "[maxio iam.rotate_secret_key] status=#{report.status} dry_run=#{report.dry_run} " <>
        "keyring_file=#{inspect(report.keyring_file)} previous_key_id=#{inspect(report.previous_key_id)} " <>
        "next_key_id=#{inspect(report.next_key_id)} key_count=#{report.key_count} " <>
        "errors=#{length(report.errors)}"
    )

    if report.rewrap do
      IO.puts(
        "[maxio iam.rotate_secret_key.rewrap] status=#{report.rewrap.status} " <>
          "scanned=#{Map.get(report.rewrap, :scanned, 0)} " <>
          "candidates=#{Map.get(report.rewrap, :candidates, 0)} " <>
          "rewrapped=#{Map.get(report.rewrap, :rewrapped, 0)} " <>
          "errors=#{Map.get(report.rewrap, :errors, 0)}"
      )
    end
  end

  defp json_report(report) do
    %{
      status: to_string(report.status),
      dry_run: report.dry_run,
      keyring_file: report.keyring_file,
      previous_key_id: report.previous_key_id,
      next_key_id: report.next_key_id,
      key_count: report.key_count,
      current_key_started_at: report.current_key_started_at,
      rewrap: report.rewrap && Output.json_value(report.rewrap),
      errors: Enum.map(report.errors, &inspect/1)
    }
  end
end
