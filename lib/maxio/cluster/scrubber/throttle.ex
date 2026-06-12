defmodule Maxio.Cluster.Scrubber.Throttle do
  @moduledoc """
  Small rate-limit helper for background scrub work.

  Tests pass `no_throttle: true`; production callers can combine an object-per-second
  ceiling with a fixed pause between metadata pages.
  """

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

  @spec maybe_wait(keyword()) :: :ok
  def maybe_wait(opts) do
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
end
