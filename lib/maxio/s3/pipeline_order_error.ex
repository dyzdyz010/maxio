defmodule Maxio.S3.PipelineOrderError do
  @moduledoc """
  **管线顺序错误**：某个 plug 依赖的上游 assign 不存在，说明它被挂到了上游 plug 之前。

  这不是请求数据错误，而是**部署期的构造错误**——它对每一个同类请求恒定成立，与客户端
  发了什么无关。因此它的处置规则与业务错误相反：

    * 绝不能被"通用异常 → 500 InternalError"的兜底吞掉。那样错误只以一条与其它偶发 500
      无法区分的日志出现，而 maxio 的意图是**顺序错了要立刻可见**（铁律 3）；
    * 故本异常必须穿过各面 plug 自己的 `try/rescue` 原样上抛，成为未捕获崩溃 —— OTP 会打
      完整 crash report（含 stacktrace 与请求信息），HTTP 适配器仍回 500。客户端拿到的东西
      与被吞掉时完全一样（500、无细节），所以这么做不泄露任何额外信息，只是把服务端一侧
      从"一条普通 warning"提升成"一次刺眼的崩溃"。

  凡是 `assigns` 缺失只可能源于挂载顺序的判定，都必须抛本异常，而不是 `raise "字符串"`
  （后者是 `RuntimeError`，与真正的运行时异常混在一起，无法被 rescue 子句区分）。
  """
  defexception [:message]

  @impl true
  def exception(message) when is_binary(message), do: %__MODULE__{message: message}
end
