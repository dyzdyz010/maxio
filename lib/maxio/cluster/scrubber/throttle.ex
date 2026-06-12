defmodule Maxio.Cluster.Scrubber.Throttle do
  @moduledoc """
  Small rate-limit helper for background scrub work.

  Tests pass `no_throttle: true`; production callers can combine a token-bucket
  object-per-second ceiling with a fixed pause between metadata pages.
  """

  defstruct mode: :disabled,
            rate_per_sec: nil,
            burst: 0,
            tokens: 0.0,
            last_ms: 0,
            fixed_ms: 0,
            sleep_fun: &Process.sleep/1

  @type t :: %__MODULE__{
          mode: :disabled | :fixed | :token_bucket,
          rate_per_sec: pos_integer() | nil,
          burst: pos_integer() | 0,
          tokens: float(),
          last_ms: integer(),
          fixed_ms: non_neg_integer(),
          sleep_fun: (non_neg_integer() -> any())
        }

  @spec new(keyword(), integer()) :: t()
  def new(opts, now_ms \\ monotonic_ms()) do
    cond do
      Keyword.get(opts, :no_throttle, false) ->
        %__MODULE__{mode: :disabled, last_ms: now_ms}

      fixed = Keyword.get(opts, :sleep_between_objects_ms) ->
        %__MODULE__{
          mode: :fixed,
          fixed_ms: max(fixed, 0),
          last_ms: now_ms,
          sleep_fun: sleep_fun(opts)
        }

      rate = positive_int(Keyword.get(opts, :max_objects_per_sec)) ->
        burst = positive_int(Keyword.get(opts, :object_burst)) || 1

        %__MODULE__{
          mode: :token_bucket,
          rate_per_sec: rate,
          burst: burst,
          tokens: burst * 1.0,
          last_ms: now_ms,
          sleep_fun: sleep_fun(opts)
        }

      true ->
        %__MODULE__{mode: :disabled, last_ms: now_ms}
    end
  end

  @spec sleep_ms(keyword()) :: non_neg_integer()
  def sleep_ms(opts) do
    cond do
      Keyword.get(opts, :no_throttle, false) ->
        0

      fixed = Keyword.get(opts, :sleep_between_objects_ms) ->
        max(fixed, 0)

      rate = Keyword.get(opts, :max_objects_per_sec) ->
        if is_integer(rate) and rate > 0, do: ceil(1_000 / rate), else: 0

      true ->
        0
    end
  end

  @spec take(t(), integer()) :: {non_neg_integer(), t()}
  def take(state, now_ms \\ monotonic_ms())

  def take(%__MODULE__{mode: :disabled} = state, _now_ms), do: {0, state}

  def take(%__MODULE__{mode: :fixed, fixed_ms: ms} = state, now_ms) do
    {ms, %{state | last_ms: now_ms}}
  end

  def take(%__MODULE__{mode: :token_bucket} = state, now_ms) do
    elapsed_ms = max(now_ms - state.last_ms, 0)
    refilled = min(state.burst * 1.0, state.tokens + elapsed_ms * state.rate_per_sec / 1_000)

    if refilled >= 1.0 do
      {0, %{state | tokens: refilled - 1.0, last_ms: now_ms}}
    else
      sleep_ms = ceil((1.0 - refilled) * 1_000 / state.rate_per_sec)
      {sleep_ms, %{state | tokens: 0.0, last_ms: now_ms + sleep_ms}}
    end
  end

  @spec maybe_wait(t()) :: t()
  def maybe_wait(%__MODULE__{} = state) do
    {ms, state} = take(state)
    if ms > 0, do: state.sleep_fun.(ms)
    state
  end

  @spec maybe_wait(keyword()) :: :ok
  def maybe_wait(opts) when is_list(opts) do
    case sleep_ms(opts) do
      ms when ms > 0 -> Process.sleep(ms)
      _ -> :ok
    end
  end

  @spec maybe_wait_between_batches(keyword()) :: :ok
  def maybe_wait_between_batches(opts) do
    if Keyword.get(opts, :no_throttle, false) do
      :ok
    else
      case Keyword.get(opts, :sleep_between_batches_ms, 0) do
        ms when is_integer(ms) and ms > 0 -> Process.sleep(ms)
        _ -> :ok
      end
    end
  end

  defp monotonic_ms, do: System.monotonic_time(:millisecond)

  defp positive_int(n) when is_integer(n) and n > 0, do: n
  defp positive_int(_n), do: nil

  defp sleep_fun(opts) do
    case Keyword.get(opts, :throttle_sleep_fun) do
      fun when is_function(fun, 1) -> fun
      _ -> &Process.sleep/1
    end
  end
end
