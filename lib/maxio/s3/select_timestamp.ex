defmodule Maxio.S3.SelectTimestamp do
  @moduledoc false

  @enforce_keys [:naive, :offset_minutes, :precision, :nanosecond]
  defstruct [:naive, :offset_minutes, :precision, :nanosecond, frac_digits: 0]

  @type part ::
          :year | :month | :day | :hour | :minute | :second | :timezone_hour | :timezone_minute
  @type precision :: :year | :month | :day | :minute | :second | :fraction
  @type t :: %__MODULE__{
          naive: NaiveDateTime.t(),
          offset_minutes: integer(),
          precision: precision(),
          nanosecond: 0..999_999_999,
          frac_digits: non_neg_integer()
        }

  @unix_epoch_gregorian_seconds :calendar.datetime_to_gregorian_seconds({{1970, 1, 1}, {0, 0, 0}})

  @timestamp_regex ~r/^(?<year>\d{4})(?:-(?<month>\d{2})(?:-(?<day>\d{2}))?)?T(?:(?<hour>\d{2}):(?<minute>\d{2})(?::(?<second>\d{2})(?:\.(?<fraction>\d{1,9}))?)?)?(?<offset>Z|[+-]\d{2}:\d{2})?$/

  @month_abbreviations ~w(Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec)
  @month_names ~w(January February March April May June July August September October November December)

  @spec parse(term()) :: {:ok, t()} | :error
  def parse(%__MODULE__{} = timestamp), do: {:ok, timestamp}

  def parse(value) when is_binary(value) do
    case Regex.named_captures(@timestamp_regex, value) do
      nil ->
        :error

      captures ->
        build(
          captures["year"],
          captures["month"],
          captures["day"],
          captures["hour"],
          captures["minute"],
          captures["second"],
          captures["fraction"],
          captures["offset"]
        )
    end
  end

  def parse(_value), do: :error

  @spec utc_now() :: t()
  def utc_now do
    now = System.os_time(:nanosecond)
    seconds = div(now, 1_000_000_000)
    nanosecond = rem(now, 1_000_000_000)

    {{year, month, day}, {hour, minute, second}} =
      :calendar.gregorian_seconds_to_datetime(@unix_epoch_gregorian_seconds + seconds)

    naive =
      NaiveDateTime.new!(
        Date.new!(year, month, day),
        Time.new!(hour, minute, second, {div(nanosecond, 1_000), 6})
      )

    %__MODULE__{
      naive: naive,
      offset_minutes: 0,
      precision: :fraction,
      nanosecond: nanosecond,
      frac_digits: 9
    }
  end

  @spec to_string(t()) :: String.t()
  def to_string(%__MODULE__{naive: naive, precision: :year}) do
    pad4(naive.year) <> "T"
  end

  def to_string(%__MODULE__{naive: naive, precision: :month}) do
    pad4(naive.year) <> "-" <> pad2(naive.month) <> "T"
  end

  def to_string(%__MODULE__{naive: naive, precision: :day}) do
    date_string(naive) <> "T"
  end

  def to_string(%__MODULE__{naive: naive, precision: :minute, offset_minutes: offset}) do
    date_string(naive) <> "T" <> time_string(naive, :minute) <> offset_string(offset)
  end

  def to_string(%__MODULE__{naive: naive, precision: :second, offset_minutes: offset}) do
    date_string(naive) <> "T" <> time_string(naive, :second) <> offset_string(offset)
  end

  def to_string(%__MODULE__{
        naive: naive,
        precision: :fraction,
        offset_minutes: offset,
        nanosecond: nanosecond,
        frac_digits: frac_digits
      }) do
    date_string(naive) <>
      "T" <> time_string(naive, :fraction, frac_digits, nanosecond) <> offset_string(offset)
  end

  @spec format(t(), String.t()) :: {:ok, String.t()} | :error
  def format(%__MODULE__{} = timestamp, pattern) when is_binary(pattern) do
    case format_pattern(pattern, timestamp, []) do
      {:ok, iodata} -> {:ok, IO.iodata_to_binary(iodata)}
      :error -> :error
    end
  end

  def format(_timestamp, _pattern), do: :error

  @spec extract(part(), t()) :: integer()
  def extract(:year, %__MODULE__{naive: naive}), do: naive.year
  def extract(:month, %__MODULE__{naive: naive}), do: naive.month
  def extract(:day, %__MODULE__{naive: naive}), do: naive.day
  def extract(:hour, %__MODULE__{naive: naive}), do: naive.hour
  def extract(:minute, %__MODULE__{naive: naive}), do: naive.minute
  def extract(:second, %__MODULE__{naive: naive}), do: naive.second

  def extract(:timezone_hour, %__MODULE__{offset_minutes: offset}),
    do: div(offset, 60)

  def extract(:timezone_minute, %__MODULE__{offset_minutes: offset}) do
    sign = if offset < 0, do: -1, else: 1
    sign * rem(abs(offset), 60)
  end

  @spec add(part(), integer(), t()) :: t()
  def add(:year, amount, %__MODULE__{} = timestamp) do
    add_months(timestamp, amount * 12, :year)
  end

  def add(:month, amount, %__MODULE__{} = timestamp) do
    add_months(timestamp, amount, :month)
  end

  def add(:day, amount, %__MODULE__{} = timestamp) do
    add_seconds(timestamp, amount * 86_400, :day)
  end

  def add(:hour, amount, %__MODULE__{} = timestamp) do
    add_seconds(timestamp, amount * 3_600, :hour)
  end

  def add(:minute, amount, %__MODULE__{} = timestamp) do
    add_seconds(timestamp, amount * 60, :minute)
  end

  def add(:second, amount, %__MODULE__{} = timestamp) do
    add_seconds(timestamp, amount, :second)
  end

  @spec diff(part(), t(), t()) :: integer()
  def diff(:year, left, right) do
    %{year: left_year} = utc_naive(left)
    %{year: right_year} = utc_naive(right)

    right_year - left_year
  end

  def diff(:month, left, right) do
    %{year: left_year, month: left_month} = utc_naive(left)
    %{year: right_year, month: right_month} = utc_naive(right)

    right_year * 12 + right_month - (left_year * 12 + left_month)
  end

  def diff(:day, left, right),
    do: trunc((utc_nanoseconds(right) - utc_nanoseconds(left)) / 86_400_000_000_000)

  def diff(:hour, left, right),
    do: trunc((utc_nanoseconds(right) - utc_nanoseconds(left)) / 3_600_000_000_000)

  def diff(:minute, left, right),
    do: trunc((utc_nanoseconds(right) - utc_nanoseconds(left)) / 60_000_000_000)

  def diff(:second, left, right),
    do: trunc((utc_nanoseconds(right) - utc_nanoseconds(left)) / 1_000_000_000)

  @spec compare(t(), t()) :: :lt | :eq | :gt
  def compare(left, right) do
    case utc_nanoseconds(left) - utc_nanoseconds(right) do
      diff when diff < 0 -> :lt
      0 -> :eq
      _diff -> :gt
    end
  end

  defp build(year, month, day, hour, minute, second, fraction, offset) do
    input_precision = precision(month, day, hour, second, fraction)

    with {:ok, year} <- parse_integer(year),
         {:ok, month} <- parse_default_integer(month, 1),
         {:ok, day} <- parse_default_integer(day, 1),
         {:ok, hour} <- parse_default_integer(hour, 0),
         {:ok, minute} <- parse_default_integer(minute, 0),
         {:ok, second} <- parse_default_integer(second, 0),
         {:ok, microsecond, nanosecond, frac_digits} <- parse_fraction(fraction),
         {:ok, offset_minutes} <- parse_offset(offset),
         {:ok, date} <- Date.new(year, month, day),
         {:ok, time} <- Time.new(hour, minute, second, {microsecond, min(frac_digits, 6)}),
         {:ok, naive} <- NaiveDateTime.new(date, time) do
      {:ok,
       %__MODULE__{
         naive: naive,
         offset_minutes: offset_minutes,
         precision: input_precision,
         nanosecond: nanosecond,
         frac_digits: frac_digits
       }}
    else
      _other -> :error
    end
  end

  defp parse_integer(value) do
    case Integer.parse(value) do
      {integer, ""} -> {:ok, integer}
      _other -> :error
    end
  end

  defp parse_default_integer("", default), do: {:ok, default}
  defp parse_default_integer(value, _default), do: parse_integer(value)

  defp parse_fraction(""), do: {:ok, 0, 0, 0}

  defp parse_fraction(value) do
    digits = String.length(value)

    with {:ok, nanosecond} <-
           value
           |> String.pad_trailing(9, "0")
           |> parse_integer() do
      {:ok, div(nanosecond, 1_000), nanosecond, digits}
    end
  end

  defp parse_offset(""), do: {:ok, 0}
  defp parse_offset("Z"), do: {:ok, 0}

  defp parse_offset(<<sign, hour::binary-size(2), ":", minute::binary-size(2)>>)
       when sign in [?+, ?-] do
    with {:ok, hour} when hour <= 23 <- parse_integer(hour),
         {:ok, minute} when minute <= 59 <- parse_integer(minute) do
      multiplier = if sign == ?-, do: -1, else: 1
      {:ok, multiplier * (hour * 60 + minute)}
    else
      _other -> :error
    end
  end

  defp parse_offset(_offset), do: :error

  defp precision(_month, _day, _hour, _second, fraction) when fraction != "", do: :fraction
  defp precision(_month, _day, _hour, second, _fraction) when second != "", do: :second
  defp precision(_month, _day, hour, _second, _fraction) when hour != "", do: :minute
  defp precision(_month, day, _hour, _second, _fraction) when day != "", do: :day
  defp precision(month, _day, _hour, _second, _fraction) when month != "", do: :month
  defp precision(_month, _day, _hour, _second, _fraction), do: :year

  defp add_months(%__MODULE__{naive: naive} = timestamp, amount, part) do
    total = naive.year * 12 + (naive.month - 1) + amount
    year = floor_div(total, 12)
    month = rem_nonnegative(total, 12) + 1
    day = min(naive.day, Calendar.ISO.days_in_month(year, month))
    date = Date.new!(year, month, day)

    new_naive =
      NaiveDateTime.new!(
        date,
        Time.new!(naive.hour, naive.minute, naive.second, naive.microsecond)
      )

    %{
      timestamp
      | naive: new_naive,
        precision: max_precision(timestamp.precision, precision_for_part(part))
    }
  end

  defp add_seconds(%__MODULE__{} = timestamp, amount, part) do
    %{
      timestamp
      | naive: NaiveDateTime.add(timestamp.naive, amount, :second),
        precision: max_precision(timestamp.precision, precision_for_part(part))
    }
  end

  defp precision_for_part(:year), do: :year
  defp precision_for_part(:month), do: :month
  defp precision_for_part(:day), do: :day
  defp precision_for_part(:hour), do: :minute
  defp precision_for_part(:minute), do: :minute
  defp precision_for_part(:second), do: :second

  defp max_precision(left, right) do
    if precision_rank(left) >= precision_rank(right), do: left, else: right
  end

  defp precision_rank(:year), do: 1
  defp precision_rank(:month), do: 2
  defp precision_rank(:day), do: 3
  defp precision_rank(:minute), do: 4
  defp precision_rank(:second), do: 5
  defp precision_rank(:fraction), do: 6

  defp format_pattern("", _timestamp, acc), do: {:ok, Enum.reverse(acc)}

  defp format_pattern(<<"''", rest::binary>>, timestamp, acc),
    do: format_pattern(rest, timestamp, [?' | acc])

  defp format_pattern(<<?', rest::binary>>, timestamp, acc) do
    with {:ok, literal, rest} <- take_format_literal(rest, []) do
      format_pattern(rest, timestamp, [literal | acc])
    end
  end

  defp format_pattern(<<char, rest::binary>> = pattern, timestamp, acc) do
    cond do
      format_token_char?(char) ->
        {token, rest} = take_same_char(pattern, char, 0)

        case format_token(token, timestamp) do
          {:ok, value} -> format_pattern(rest, timestamp, [value | acc])
          :error -> :error
        end

      ascii_letter?(char) ->
        :error

      true ->
        format_pattern(rest, timestamp, [<<char>> | acc])
    end
  end

  defp take_format_literal(<<?', ?', rest::binary>>, acc),
    do: take_format_literal(rest, [?' | acc])

  defp take_format_literal(<<?', rest::binary>>, acc),
    do: {:ok, acc |> Enum.reverse() |> IO.iodata_to_binary(), rest}

  defp take_format_literal(<<char, rest::binary>>, acc),
    do: take_format_literal(rest, [char | acc])

  defp take_format_literal(<<>>, _acc), do: :error

  defp take_same_char(<<char, rest::binary>>, char, count),
    do: take_same_char(rest, char, count + 1)

  defp take_same_char(rest, char, count), do: {String.duplicate(<<char>>, count), rest}

  defp format_token(token, %__MODULE__{
         naive: naive,
         offset_minutes: offset,
         nanosecond: nanosecond
       }) do
    case token do
      "y" -> {:ok, Integer.to_string(naive.year)}
      "yy" -> {:ok, naive.year |> rem(100) |> pad2()}
      "yyyy" -> {:ok, pad4(naive.year)}
      "M" -> {:ok, Integer.to_string(naive.month)}
      "MM" -> {:ok, pad2(naive.month)}
      "MMM" -> {:ok, Enum.at(@month_abbreviations, naive.month - 1)}
      "MMMM" -> {:ok, Enum.at(@month_names, naive.month - 1)}
      "MMMMM" -> {:ok, Enum.at(@month_names, naive.month - 1) |> binary_part(0, 1)}
      "d" -> {:ok, Integer.to_string(naive.day)}
      "dd" -> {:ok, pad2(naive.day)}
      "a" -> {:ok, if(naive.hour < 12, do: "AM", else: "PM")}
      "h" -> {:ok, naive.hour |> hour12() |> Integer.to_string()}
      "hh" -> {:ok, naive.hour |> hour12() |> pad2()}
      "H" -> {:ok, Integer.to_string(naive.hour)}
      "HH" -> {:ok, pad2(naive.hour)}
      "m" -> {:ok, Integer.to_string(naive.minute)}
      "mm" -> {:ok, pad2(naive.minute)}
      "s" -> {:ok, Integer.to_string(naive.second)}
      "ss" -> {:ok, pad2(naive.second)}
      "n" -> {:ok, Integer.to_string(nanosecond)}
      <<?S, _rest::binary>> = token -> format_fraction_token(token, nanosecond)
      <<?X, _rest::binary>> = token -> format_offset_token(token, offset, :upper)
      <<?x, _rest::binary>> = token -> format_offset_token(token, offset, :lower)
      _other -> :error
    end
  end

  defp format_fraction_token(token, nanosecond) when byte_size(token) in 1..9 do
    {:ok, nanosecond |> div(pow10(9 - byte_size(token))) |> Integer.to_string()}
  end

  defp format_fraction_token(_token, _nanosecond), do: :error

  defp pow10(0), do: 1
  defp pow10(exponent), do: Enum.reduce(1..exponent, 1, fn _step, acc -> acc * 10 end)

  defp format_offset_token(token, 0, :upper) when byte_size(token) in [1, 2, 3, 4, 5],
    do: {:ok, "Z"}

  defp format_offset_token(token, offset, :upper) do
    case byte_size(token) do
      1 -> {:ok, offset_hours_colonless(offset, :padded, :signed)}
      size when size in [2, 4] -> {:ok, offset_hhmm(offset, :padded, :signed)}
      size when size in [3, 5] -> {:ok, offset_hh_mm(offset, :padded, :signed)}
      _other -> :error
    end
  end

  defp format_offset_token(token, offset, :lower) do
    case byte_size(token) do
      1 -> {:ok, offset_hours_colonless(offset, :unpadded, :positive_unsigned)}
      size when size in [2, 4] -> {:ok, offset_hhmm(offset, :unpadded, :positive_unsigned)}
      size when size in [3, 5] -> {:ok, offset_hh_mm(offset, :padded, :signed)}
      _other -> :error
    end
  end

  defp hour12(0), do: 12
  defp hour12(hour) when hour <= 12, do: hour
  defp hour12(hour), do: hour - 12

  defp offset_hours_colonless(offset, padding, sign_mode) do
    sign_prefix(offset, sign_mode) <> maybe_pad2(div(abs(offset), 60), padding)
  end

  defp offset_hhmm(offset, padding, sign_mode) do
    absolute = abs(offset)

    sign_prefix(offset, sign_mode) <>
      maybe_pad2(div(absolute, 60), padding) <> pad2(rem(absolute, 60))
  end

  defp offset_hh_mm(offset, padding, sign_mode) do
    absolute = abs(offset)

    sign_prefix(offset, sign_mode) <>
      maybe_pad2(div(absolute, 60), padding) <> ":" <> pad2(rem(absolute, 60))
  end

  defp sign_prefix(offset, :signed) when offset < 0, do: "-"
  defp sign_prefix(_offset, :signed), do: "+"
  defp sign_prefix(offset, :positive_unsigned) when offset < 0, do: "-"
  defp sign_prefix(_offset, :positive_unsigned), do: ""

  defp maybe_pad2(integer, :padded), do: pad2(integer)
  defp maybe_pad2(integer, :unpadded), do: Integer.to_string(integer)

  defp format_token_char?(char), do: char in ~c"yMdahHmsSnXx"
  defp ascii_letter?(char), do: char in ?A..?Z or char in ?a..?z

  defp utc_nanoseconds(%__MODULE__{naive: naive, offset_minutes: offset, nanosecond: nanosecond}) do
    {{year, month, day}, {hour, minute, second}} = NaiveDateTime.to_erl(naive)
    base = :calendar.datetime_to_gregorian_seconds({{year, month, day}, {hour, minute, second}})
    base * 1_000_000_000 + nanosecond - offset * 60 * 1_000_000_000
  end

  defp utc_naive(%__MODULE__{naive: naive, offset_minutes: offset}) do
    {{year, month, day}, {hour, minute, second}} = NaiveDateTime.to_erl(naive)

    {{year, month, day}, {hour, minute, second}} =
      {{year, month, day}, {hour, minute, second}}
      |> :calendar.datetime_to_gregorian_seconds()
      |> Kernel.-(offset * 60)
      |> :calendar.gregorian_seconds_to_datetime()

    NaiveDateTime.new!(
      Date.new!(year, month, day),
      Time.new!(hour, minute, second)
    )
  end

  defp date_string(naive),
    do: pad4(naive.year) <> "-" <> pad2(naive.month) <> "-" <> pad2(naive.day)

  defp time_string(naive, :minute), do: pad2(naive.hour) <> ":" <> pad2(naive.minute)

  defp time_string(naive, :second) do
    time_string(naive, :minute) <> ":" <> pad2(naive.second)
  end

  defp time_string(naive, :fraction, frac_digits, nanosecond) do
    fraction =
      nanosecond
      |> Integer.to_string()
      |> String.pad_leading(9, "0")
      |> String.slice(0, frac_digits)

    time_string(naive, :second) <> "." <> fraction
  end

  defp offset_string(0), do: "Z"

  defp offset_string(offset) do
    sign = if offset < 0, do: "-", else: "+"
    absolute = abs(offset)
    sign <> pad2(div(absolute, 60)) <> ":" <> pad2(rem(absolute, 60))
  end

  defp pad2(integer) when integer < 10, do: "0" <> Integer.to_string(integer)
  defp pad2(integer), do: Integer.to_string(integer)

  defp pad4(integer) when integer < 10, do: "000" <> Integer.to_string(integer)
  defp pad4(integer) when integer < 100, do: "00" <> Integer.to_string(integer)
  defp pad4(integer) when integer < 1000, do: "0" <> Integer.to_string(integer)
  defp pad4(integer), do: Integer.to_string(integer)

  defp floor_div(left, right) when left >= 0, do: div(left, right)
  defp floor_div(left, right), do: -div(-left + right - 1, right)

  defp rem_nonnegative(left, right) do
    rem = rem(left, right)
    if rem < 0, do: rem + right, else: rem
  end
end
