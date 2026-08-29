defmodule Maxio.Admin.ConfigKV.ParserTest do
  use ExUnit.Case, async: true

  import Maxio.Admin.ConfigKV.Parser, only: [parse_set: 2, parse_reset: 1, render: 2]

  import Maxio.Admin.ConfigKV.Registry, only: [entries: 0]

  alias Maxio.Admin.ConfigKV.Parser

  test "set scanner skips LF comments and blank lines while sanitizing only outer whitespace and quotes" do
    # Catches a line splitter that treats comments as settings, loses LF-separated input, or
    # passes transport quoting into the later Schema.parse/3 scalar validation.
    plaintext = "\n# pinned-comment\n\ns3 clock_skew_ms=  \"900000\"  \n"

    assert parse_set(plaintext, entries()) ==
             {:ok, %{wire_subsystem: "s3", patches: [{"clock_skew_ms", "900000"}]}}
  end

  test "mixed quote layers are sanitized in madmin's fixed double-then-single order" do
    # Catches treating both quote kinds as one interchangeable boundary pair. SanitizeValue first
    # removes one double-quote layer and then one single-quote layer, without escape parsing.
    assert parse_set(~s(s3 clock_skew_ms="'900000'"), entries()) ==
             {:ok, %{wire_subsystem: "s3", patches: [{"clock_skew_ms", "900000"}]}}
  end

  test "repeated same-kind quote layers retain one layer after one-shot sanitization" do
    # Catches trim-all primitives that accept overquoted typed values. Each quote kind loses at
    # most one prefix and one suffix, so one complete layer must remain for typed rejection.
    results = [
      parse_set(~s(s3 clock_skew_ms=""900000""), entries()),
      parse_set("s3 clock_skew_ms=''900000''", entries())
    ]

    assert results == [
             {:ok, %{wire_subsystem: "s3", patches: [{"clock_skew_ms", ~s("900000")}]}},
             {:ok, %{wire_subsystem: "s3", patches: [{"clock_skew_ms", "'900000'"}]}}
           ]
  end

  test "set parser preserves raw inner whitespace after outer quote sanitization" do
    # Catches overzealous trimming/tokenizing that would change a raw value before the typed
    # boundary has an opportunity to accept or reject it.
    assert parse_set("s3 clock_skew_ms='1  000'", entries()) ==
             {:ok, %{wire_subsystem: "s3", patches: [{"clock_skew_ms", "1  000"}]}}
  end

  test "a duplicate registered marker on one line is absorbed into the first raw value" do
    # Catches an invented duplicate-key error or one-line last-write-wins, both of which differ
    # from MinIO's first-distinct-marker slicing semantics.
    assert parse_set("s3 clock_skew_ms=1000 clock_skew_ms=2000", entries()) ==
             {:ok,
              %{
                wire_subsystem: "s3",
                patches: [{"clock_skew_ms", "1000 clock_skew_ms=2000"}]
              }}
  end

  test "same-subsystem multi-line patches retain source order for the later last-line fold" do
    # Catches a parser that folds or sorts patches early, preventing the atomic adapter from
    # applying the final line as the authoritative value.
    assert parse_set("s3 clock_skew_ms=1000\ns3 clock_skew_ms=2000\n", entries()) ==
             {:ok,
              %{
                wire_subsystem: "s3",
                patches: [{"clock_skew_ms", "1000"}, {"clock_skew_ms", "2000"}]
              }}
  end

  test "document parser preserves physical line order across public subsystems" do
    # Catches reusing the S5 one-subsystem reducer, losing physical line evidence, or folding
    # duplicate patches before the archive replacement planner applies last-line-wins.
    plaintext =
      "# pinned comment\n\n" <>
        "s3 clock_skew_ms=\"1000\"\n" <>
        "listing sql_hard_limit='100000'\n" <>
        "s3 clock_skew_ms=2000\n" <>
        "prometheus_metrics public=\"true\"\n"

    assert Parser.parse_document(plaintext, entries()) ==
             {:ok,
              [
                %{line: 3, wire_subsystem: "s3", patches: [{"clock_skew_ms", "1000"}]},
                %{
                  line: 4,
                  wire_subsystem: "listing",
                  patches: [{"sql_hard_limit", "100000"}]
                },
                %{line: 5, wire_subsystem: "s3", patches: [{"clock_skew_ms", "2000"}]},
                %{
                  line: 6,
                  wire_subsystem: "prometheus_metrics",
                  patches: [{"public", "true"}]
                }
              ]}
  end

  test "legacy S5 set remains a one-subsystem command over the shared document scanner" do
    # Catches the new archive parser accidentally broadening set-config-kv to cross-subsystem
    # writes, or letting a later unknown key mask the legacy cross-subsystem precedence.
    plaintext = "s3 clock_skew_ms=1000\nlisting sql_hard_limit=100000\n"
    later_unknown = "s3 clock_skew_ms=1\nlisting absent=1"

    assert Parser.parse_set_detailed(later_unknown, entries()) == {:error, :cross_subsystem}
    assert parse_set(later_unknown, entries()) == {:error, :bad_json}

    assert {:ok, [_s3, _listing]} = Parser.parse_document(plaintext, entries())
    assert parse_set(plaintext, entries()) == {:error, :bad_json}
  end

  test "an invalid first raw scalar remains deferred when a valid later line overwrites it" do
    # Catches eager Schema.parse/3 validation of each line, which would reject a batch whose
    # final folded value is the literal valid integer 2000.
    assert parse_set("s3 clock_skew_ms=not-a-number\ns3 clock_skew_ms=2000", entries()) ==
             {:ok,
              %{
                wire_subsystem: "s3",
                patches: [{"clock_skew_ms", "not-a-number"}, {"clock_skew_ms", "2000"}]
              }}
  end

  test "unknown-only set input is rejected while an unknown suffix remains part of the registered value" do
    # Catches a parser that silently accepts a line with no marker, or incorrectly invents a
    # universal unknown-token grammar for a suffix MinIO places inside the preceding value.
    assert parse_set("s3 absent=1", entries()) == {:error, :unknown_key}

    assert parse_set("s3 clock_skew_ms=1000 absent=1", entries()) ==
             {:ok,
              %{
                wire_subsystem: "s3",
                patches: [{"clock_skew_ms", "1000 absent=1"}]
              }}
  end

  test "unknown prefix and cross-subsystem set batches are deliberate BadJSON-class rejections" do
    # Catches silent loss of a token before the first marker, or validation of only the first
    # subsystem while later lines bypass their own exposure and scalar checks.
    assert parse_set("s3 absent=1 clock_skew_ms=1000", entries()) == {:error, :bad_json}

    assert parse_set("s3 clock_skew_ms=1000\nlisting sql_hard_limit=100000", entries()) ==
             {:error, :bad_json}
  end

  test "targets are rejected rather than accepted and ignored" do
    # Catches the unsafe target compatibility branch that would make a caller believe a named
    # target was changed or read despite this first release supporting only the default target.
    assert parse_set("s3:secondary clock_skew_ms=1000", entries()) == {:error, :invalid_argument}
    assert parse_reset("s3:secondary") == {:error, :invalid_argument}
  end

  test "reset parser distinguishes full subsystem reset from a literal subset" do
    # Catches reset parsing that turns a complete subsystem reset into an empty subset, or drops
    # the only requested exposed key.
    assert parse_reset("s3") == {:ok, %{wire_subsystem: "s3", reset: :all}}

    assert parse_reset("listing sql_hard_limit") ==
             {:ok, %{wire_subsystem: "listing", reset: ["sql_hard_limit"]}}
  end

  test "reset parser retains repeated subset keys and accepts repeated full-reset lines as one no-op batch" do
    # Catches a duplicate-key error that breaks idempotent reset, or the pinned upstream
    # whole-body behaviour leaking into Maxio's deliberate same-body full-reset deviation.
    assert parse_reset("s3 clock_skew_ms clock_skew_ms") ==
             {:ok, %{wire_subsystem: "s3", reset: ["clock_skew_ms", "clock_skew_ms"]}}

    assert parse_reset("s3\ns3\n") == {:ok, %{wire_subsystem: "s3", reset: :all}}
  end

  test "renderer quotes whitespace values and ends every response with the stable trailing space and LF" do
    # Catches renderer drift that drops madmin-compatible quoting, removes the final per-KV
    # ASCII space, or emits an extra/missing line ending that changes mc's plaintext bytes.
    integer = IO.iodata_to_binary(render("s3", [{"clock_skew_ms", 900_000}]))
    boolean = IO.iodata_to_binary(render("prometheus_metrics", [{"public", false}]))
    whitespace = IO.iodata_to_binary(render("s3", [{"description", "two words"}]))

    assert integer == "s3 clock_skew_ms=900000 \n"

    assert Base.encode16(integer, case: :lower) ==
             "733320636c6f636b5f736b65775f6d733d393030303030200a"

    assert boolean == "prometheus_metrics public=false \n"
    assert whitespace == "s3 description=\"two words\" \n"
    assert String.ends_with?(integer, <<32, 10>>)
  end
end
