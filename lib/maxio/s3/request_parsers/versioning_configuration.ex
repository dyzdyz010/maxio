defmodule Maxio.S3.RequestParsers.VersioningConfiguration do
  @moduledoc """
  PutBucketVersioning 的 XML body 解析（saxy SAX）。提取 <Status>（Enabled|Suspended）与
  <MfaDelete>（Enabled|Disabled）。容忍命名空间前缀与 xmlns。空 body（无 Status）→ status nil。
  非法 Status/MfaDelete 值 → :malformed_xml（铁律 3，绝不静默当默认）。
  返回 {:ok, %{status, mfa_delete}} | {:error, :malformed_xml}。
  """
  @behaviour Saxy.Handler

  @spec parse(binary()) ::
          {:ok, %{status: String.t() | nil, mfa_delete: String.t() | nil}}
          | {:error, :malformed_xml}
  def parse(xml) when is_binary(xml) do
    with {:ok, %{status: status, mfa_delete: mfa}} <- run(xml),
         :ok <- validate(status, ["Enabled", "Suspended"]),
         :ok <- validate(mfa, ["Enabled", "Disabled"]) do
      {:ok, %{status: status, mfa_delete: mfa}}
    else
      _ -> {:error, :malformed_xml}
    end
  end

  defp run(xml) do
    case Saxy.parse_string(xml, __MODULE__, %{status: nil, mfa_delete: nil, in: nil, text: nil}) do
      {:ok, state} -> {:ok, state}
      {:error, _} -> {:error, :malformed_xml}
    end
  end

  defp validate(nil, _allowed), do: :ok
  defp validate(v, allowed) when is_binary(v), do: if(v in allowed, do: :ok, else: :error)

  @impl true
  def handle_event(:start_document, _p, s), do: {:ok, s}

  @impl true
  def handle_event(:start_element, {name, _attrs}, s) do
    case local(name) do
      "Status" -> {:ok, %{s | in: :status, text: ""}}
      "MfaDelete" -> {:ok, %{s | in: :mfa, text: ""}}
      _ -> {:ok, %{s | in: nil}}
    end
  end

  @impl true
  def handle_event(:characters, c, %{text: t} = s) when is_binary(t), do: {:ok, %{s | text: t <> c}}
  def handle_event(:characters, _c, s), do: {:ok, s}

  @impl true
  def handle_event(:end_element, name, s) do
    case local(name) do
      "Status" -> {:ok, %{s | status: trim(s.text), in: nil, text: nil}}
      "MfaDelete" -> {:ok, %{s | mfa_delete: trim(s.text), in: nil, text: nil}}
      _ -> {:ok, %{s | in: nil, text: nil}}
    end
  end

  @impl true
  def handle_event(:end_document, _d, s), do: {:ok, s}

  defp trim(nil), do: nil
  defp trim(t), do: String.trim(t)

  defp local(name) do
    case String.split(name, ":") do
      [_ns, l] -> l
      [l] -> l
    end
  end
end
