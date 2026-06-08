defmodule Maxio.Cors do
  @moduledoc """
  CORS 规则匹配（first-match，官方核验 bake-in）。规则为已解析的 rule map（string-key）。
    * match_preflight(rules, origin, req_method, req_headers) → {:ok, rule} | :no_match
        命中条件：origin ∈ allowed_origins（单*通配）∧ req_method ∈ allowed_methods
                  ∧ 每个 req_header ∈ allowed_headers（单*通配，大小写不敏感）。
    * match_actual(rules, origin, method) → {:ok, rule} | :no_match
        命中条件：origin 匹配 ∧ method 匹配（不看请求头）。
  origin 单* 通配语义：模式中至多一个 *，转义其余后 \\A…\\z 锚定匹配。
  """

  @spec match_preflight([map()], String.t(), String.t(), [String.t()]) :: {:ok, map()} | :no_match
  def match_preflight(rules, origin, req_method, req_headers) do
    find(rules, fn r ->
      origin_match?(r, origin) and method_match?(r, req_method) and headers_match?(r, req_headers)
    end)
  end

  @spec match_actual([map()], String.t(), String.t()) :: {:ok, map()} | :no_match
  def match_actual(rules, origin, method) do
    find(rules, fn r -> origin_match?(r, origin) and method_match?(r, method) end)
  end

  defp find(rules, pred) do
    case Enum.find(rules, pred) do
      nil -> :no_match
      rule -> {:ok, rule}
    end
  end

  defp origin_match?(r, origin) do
    Enum.any?(Map.get(r, "allowed_origins", []), &wildcard_match?(&1, origin, false))
  end

  defp method_match?(r, method) do
    Enum.member?(Map.get(r, "allowed_methods", []), String.upcase(method))
  end

  defp headers_match?(r, req_headers) do
    allowed = Map.get(r, "allowed_headers", [])
    Enum.all?(req_headers, fn h -> Enum.any?(allowed, &wildcard_match?(&1, h, true)) end)
  end

  # 单* 通配匹配；ci=大小写不敏感（AllowedHeader 用）。
  defp wildcard_match?(pattern, value, ci) do
    regex_src = pattern |> Regex.escape() |> String.replace("\\*", ".*")
    flags = if ci, do: "iu", else: "u"

    case Regex.compile("\\A" <> regex_src <> "\\z", flags) do
      {:ok, re} -> Regex.match?(re, value)
      {:error, _} -> false
    end
  end
end
