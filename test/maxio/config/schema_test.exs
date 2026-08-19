defmodule Maxio.Config.SchemaTest do
  @moduledoc """
  白名单 schema 的**静态**漂移守卫（设计 §13 T1 第一行）。

  D3 把白名单放进代码而不是 DB，正是为了让"schema 说有这个键"与"代码真的读这个键"
  可以被静态断言。没有这条守卫，白名单会慢慢退化成一张没人读的许愿单：运维
  `mix maxio.config.set` 成功、`version` 递增、审计有行，但那个键在 lib/ 里根本
  没有读取点——一次教科书级的静默失败（铁律 3）。

  ## 为什么先剥注释再扫（这条守卫自己曾经是空转的）

  第一版守卫直接在**整份文件正文**上 `String.contains?`。于是
  `lib/maxio/config/deployment_id.ex` 里那句解释守卫如何工作的注释——它逐字包含
  `Maxio.Config.get(:cluster, :deployment_id`——自己就把守卫喂饱了：把唯一真实读取点换成
  `Application.get_env(:maxio, :cluster, [])[:deployment_id]`，四条用例照样全绿。
  一条读散文的守卫比没有守卫更坏，因为它让人以为有防线。

  所以扫描前先剥掉 `#` 行注释与 `\"\"\"` 文档串/长串（`strip_source/1`，本文件自带回归），
  断言只对**代码**成立。

  ## 两条守卫都从 `Schema.keys()` 派生

  第二版之前，"旧直读点已下线"是一张**手写的 4 条模式黑名单**：`cluster.deployment_id`
  一条都没有，`s3.clock_skew_ms` 只拦一种管道形态。注入
  `Application.get_env(:maxio, :s3, [])[:clock_skew_ms]` 与
  `Application.get_env(:maxio, :cluster, [])[:deployment_id]`，四条用例仍然全绿。
  手写清单的问题不是写漏了，是它**不随白名单增长**：新键进白名单，黑名单不动，防线自动失效。

  现在两条守卫都遍历 `Schema.keys()`，新增白名单键会自动进入两条守卫的射程。

  ## 直读守卫覆盖到哪、覆盖不到哪（诚实边界）

  它以"该子系统的 Application env 访问"为锚：某文件一旦出现
  `Application.*_env*(:maxio, :<子系统>`，该文件里这个子系统的白名单键就**不得**再有
  非门面的出现点。这同时覆盖了两种真实形态：

    * 直接式：`Application.get_env(:maxio, :s3, [])[:clock_skew_ms]`（同一行）；
    * 间接式：`s3 = Application.get_env(:maxio, :s3, [])` … 稍后 `s3[:clock_skew_ms]`
      （同一文件——Elixir 的绑定是模块局部的，跨文件传不出去）。

  覆盖不到的残余形态：A 模块导出整份 keyword（`def s3_config, do: Application.fetch_env!(...)`），
  B 模块再从中取键。真出现这种写法时，静态守卫拦不住它——那属于代码评审的职责，
  这里如实写明，不假装覆盖。
  """
  use ExUnit.Case, async: true

  alias Maxio.Config.Schema

  @lib_root Path.expand("../../../lib", __DIR__)

  test "白名单里的每个键在 lib/ 中都有经门面的读取点" do
    sources = source_files()

    for {subsystem, key} <- Schema.keys() do
      assert Enum.any?(sources, fn {_path, body} ->
               Enum.any?(facade_needles(subsystem, key), &String.contains?(body, &1))
             end),
             """
             whitelisted config key #{inspect({subsystem, key})} has no facade read point in lib/.
             Either wire a `Maxio.Config.get(:#{subsystem}, :#{key}, ...)` read point or remove it
             from Maxio.Config.Schema — a whitelisted key nobody reads makes `mix maxio.config.set`
             report success for a change that can never take effect.
             """
    end
  end

  test "白名单键的旧直读点已全部下线（同一个键绝不能两个答案）" do
    # D2：一旦某键进白名单，它的**所有**读取点必须同批换成门面。留一个 Application env
    # 直读点，就会出现"CLI 说生效了、热路径却仍读旧值"的分歧。
    sources = source_files()

    stale =
      for {subsystem, key} <- Schema.keys(),
          {path, body} <- sources,
          app_env_read?(body, subsystem),
          line <- stale_key_lines(body, subsystem, key),
          do: {Path.relative_to(path, @lib_root), "#{subsystem}.#{key}", line}

    assert stale == [], """
    whitelisted config keys are still reachable from Application env in files that also read that
    subsystem's env directly (file, key, offending line):
    #{inspect(stale, pretty: true)}

    Route every read through Maxio.Config.get/2,3 or fetch!/2 — two answers for one key is exactly
    the drift the config store exists to prevent.
    """
  end

  test "注释与文档串在扫描前被剥掉（守卫绝不能靠读散文自证）" do
    heredoc = ~S(""")

    fixture =
      Enum.join(
        [
          "defmodule Probe do",
          "  @moduledoc " <> heredoc,
          "  散文里写 Maxio.Config.get(:cluster, :deployment_id) 只是解释，不是读取点。",
          "  " <> heredoc,
          "",
          "  # 注释里写 Maxio.Config.get(:listing, :sql_hard_limit) 同理。",
          "  def real, do: Maxio.Config.get(:s3, :clock_skew_ms, 1)",
          ~S|  def interpolated, do: "n=#{1 + 1}" <> to_string(Maxio.Config.get(:cluster, :deployment_id))|,
          "  def char_literal, do: ?#",
          "end"
        ],
        "\n"
      )

    stripped = strip_source(fixture)

    # 这正是 deployment_id.ex 里那句注释的形态：散文逐字包含门面调用，第一版守卫就是被它喂饱的。
    refute stripped =~ "只是解释"
    refute stripped =~ "Maxio.Config.get(:listing, :sql_hard_limit)"

    # 真实代码必须活下来——包括同一行里先有字符串插值 #{...} 再有门面调用的形态，
    # 以及 ?# 字符字面量；否则剥注释会把守卫从"读散文"变成"看不见代码"，同样是空转。
    assert stripped =~ "Maxio.Config.get(:s3, :clock_skew_ms, 1)"
    assert stripped =~ "to_string(Maxio.Config.get(:cluster, :deployment_id))"
    assert stripped =~ "def char_literal, do: ?#"
  end

  test "禁止清单与白名单不相交（一个键不可能既可写又被禁止）" do
    whitelisted = MapSet.new(Map.keys(Schema.entries()))
    forbidden = MapSet.new(Schema.forbidden_keys())

    assert MapSet.disjoint?(whitelisted, forbidden)

    for {subsystem, _key} <- whitelisted do
      refute subsystem in Schema.forbidden_subsystems()
    end
  end

  test "每个白名单条目都声明了 type / apply / doc，apply 只取三个合法值" do
    for {{subsystem, key}, entry} <- Schema.entries() do
      assert Map.has_key?(entry, :type), "#{inspect({subsystem, key})} missing :type"

      assert entry.apply in [:hot, :next_cycle, :restart],
             "#{inspect({subsystem, key})} bad apply"

      assert is_binary(entry.doc) and entry.doc != "", "#{inspect({subsystem, key})} missing :doc"
    end
  end

  # 门面有两个读取形态：get/2,3（带默认）与 fetch!/2（缺失即硬失败）。两个都算数，
  # 但两个都必须写成**字面量**调用，否则这条守卫看不见它。
  defp facade_needles(subsystem, key) do
    for fun <- ["get", "fetch!"], prefix <- ["Maxio.Config.", "Config."] do
      "#{prefix}#{fun}(:#{subsystem}, :#{key}"
    end
  end

  defp app_env_read?(body, subsystem) do
    Regex.match?(
      ~r/Application\.(get_env|fetch_env!?|compile_env!?)\(\s*:maxio\s*,\s*:#{Regex.escape(to_string(subsystem))}\b/,
      body
    )
  end

  # 门面读取点写在同一行（`get_all/1` 走子系统整体，故也放行整份文件）。行内没有门面调用
  # 却出现该键的裸原子，就是一个绕过门面的读取点。
  defp stale_key_lines(body, subsystem, key) do
    if String.contains?(body, "Config.get_all(:#{subsystem})") do
      []
    else
      needles = facade_needles(subsystem, key)
      atom = ~r/(?<![\w]):#{Regex.escape(to_string(key))}\b/

      body
      |> String.split("\n")
      |> Enum.filter(fn line ->
        Regex.match?(atom, line) and not Enum.any?(needles, &String.contains?(line, &1))
      end)
      |> Enum.map(&String.trim/1)
    end
  end

  defp source_files do
    @lib_root
    |> Path.join("**/*.ex")
    |> Path.wildcard()
    |> Enum.map(&{&1, strip_source(File.read!(&1))})
  end

  # 只剥两样东西：`\"\"\"` 串（moduledoc / doc / 长字符串）与 `#` 行注释。不是 Elixir 解析器，
  # 也不需要是——守卫要的是"这行是代码还是散文"，不是 AST。两个例外必须放过：
  # 字符串插值 `#{` 与字符编码 `?#`，否则剥注释会连真实代码一起吃掉。
  defp strip_source(body) do
    body
    |> String.replace(~r/""".*?"""/s, "")
    |> String.split("\n")
    |> Enum.map(&strip_line_comment/1)
    |> Enum.join("\n")
  end

  defp strip_line_comment(line) do
    case Regex.run(~r/(?<!\?)#(?!\{)/, line, return: :index) do
      [{start, _len}] -> binary_part(line, 0, start)
      nil -> line
    end
  end
end
