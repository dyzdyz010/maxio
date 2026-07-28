defmodule Maxio.S3.SelectSQLTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.Error
  alias Maxio.S3.SelectSQL

  test "parses select star with table alias, where, and limit" do
    plan = SelectSQL.parse!("SELECT * FROM S3Object s WHERE s._2 = 'keep' LIMIT 2")

    assert plan.projections == :all
    assert plan.alias == "s"
    assert plan.where.left.name == "_2"
    assert plan.where.left.qualifier == "s"
    assert plan.where.op == "="
    assert plan.where.right == %{kind: :literal, type: :string, value: "keep"}
    assert plan.limit == 2
  end

  test "parses positional and quoted header projections" do
    plan = SelectSQL.parse!(~s(SELECT _2, s."Display Name" FROM S3Object AS s))

    assert [%{name: "_2"}, %{name: "Display Name", quoted?: true, qualifier: "s"}] =
             plan.projections
  end

  test "parses JSON-style FROM wildcard, nested fields, and array indexes" do
    plan =
      SelectSQL.parse!(
        ~s(SELECT s.projects[0]."Project Name" FROM S3Object[*] AS s WHERE s.age >= 30 LIMIT 1)
      )

    assert plan.from == "S3Object"
    assert plan.from_path == []
    assert plan.from_wildcard?
    assert plan.alias == "s"
    assert SelectSQL.output_name(hd(plan.projections)) == "Project Name"

    assert SelectSQL.ref_path(hd(plan.projections)) == [
             %{kind: :field, name: "projects", quoted?: false},
             %{kind: :index, index: 0},
             %{kind: :field, name: "Project Name", quoted?: true}
           ]
  end

  test "parses JSON FROM paths with wildcards and bracket field names" do
    plan =
      SelectSQL.parse!(~s(SELECT id FROM S3Object[*]['Rules'][*].id WHERE id != 'x'))

    assert plan.from == "S3Object"
    assert plan.from_wildcard?

    assert plan.from_path == [
             %{kind: :field, name: "Rules", quoted?: true},
             %{kind: :array_wildcard},
             %{kind: :field, name: "id", quoted?: false}
           ]

    refute SelectSQL.from_path_ends_wildcard?(plan)
    assert SelectSQL.from_path_row_name(plan) == {"id", false}
  end

  test "parses JSON FROM object wildcard paths" do
    plan = SelectSQL.parse!(~s(SELECT _1.name FROM S3Object[*].groups.* AS row))

    assert plan.from_path == [
             %{kind: :field, name: "groups", quoted?: false},
             %{kind: :object_wildcard}
           ]

    assert SelectSQL.from_path_ends_wildcard?(plan)
    assert SelectSQL.from_path_row_name(plan) == nil
  end

  test "parses IS MISSING predicates" do
    missing = SelectSQL.parse!("SELECT id FROM S3Object[*].Rules[*].id WHERE id IS MISSING")
    assert missing.where.predicate == :is_missing
    assert missing.where.left.name == "id"

    present =
      SelectSQL.parse!("SELECT _1 FROM S3Object[*].items[*] WHERE _1 IS NOT MISSING LIMIT 1")

    assert present.where.predicate == :is_not_missing
    assert present.where.left.name == "_1"
    assert present.limit == 1
  end

  test "parses boolean WHERE precedence, parentheses, and NULL predicates" do
    plan =
      SelectSQL.parse!(
        "SELECT _1 FROM S3Object WHERE NOT (_2 = 'skip' OR _3 IS NULL) AND _1 IS NOT NULL"
      )

    assert plan.where.kind == :and
    assert plan.where.left.kind == :not
    assert plan.where.left.expr.kind == :or
    assert plan.where.left.expr.left.op == "="
    assert plan.where.left.expr.right.predicate == :is_null
    assert plan.where.right.predicate == :is_not_null
  end

  test "parses IN BETWEEN and LIKE WHERE predicates" do
    in_plan = SelectSQL.parse!("SELECT _1 FROM S3Object WHERE _2 NOT IN ('skip', 'drop')")
    assert in_plan.where.predicate == :not_in

    assert in_plan.where.values == [
             %{kind: :literal, type: :string, value: "skip"},
             %{kind: :literal, type: :string, value: "drop"}
           ]

    between_plan = SelectSQL.parse!("SELECT _1 FROM S3Object WHERE _2 BETWEEN 10 AND 20")
    assert between_plan.where.predicate == :between
    assert between_plan.where.lower == %{kind: :literal, type: :number, value: "10"}
    assert between_plan.where.upper == %{kind: :literal, type: :number, value: "20"}

    like_plan = SelectSQL.parse!("SELECT name FROM S3Object WHERE name LIKE 'A!_%' ESCAPE '!'")
    assert like_plan.where.predicate == :like
    assert like_plan.where.pattern == %{kind: :literal, type: :string, value: "A!_%"}
    assert like_plan.where.escape == %{kind: :literal, type: :string, value: "!"}
    regex = SelectSQL.compile_like_regex!("A!_%", "!")
    assert Regex.match?(regex, "A_da")
    refute Regex.match?(regex, "Ada")
  end

  test "parses aggregate projections and CAST value expressions" do
    plan =
      SelectSQL.parse!(
        "SELECT count(*), count(_2), sum(cast(_2 AS INT)), avg(cast(_3 AS FLOAT)), min(_4), max(_4) FROM S3Object WHERE _1 = 'keep'"
      )

    assert [
             %{kind: :aggregate, function: :count, arg: :all},
             %{kind: :aggregate, function: :count, arg: %{name: "_2"}},
             %{kind: :aggregate, function: :sum, arg: %{kind: :cast, type: :int}},
             %{kind: :aggregate, function: :avg, arg: %{kind: :cast, type: :float}},
             %{kind: :aggregate, function: :min, arg: %{name: "_4"}},
             %{kind: :aggregate, function: :max, arg: %{name: "_4"}}
           ] = plan.projections

    assert SelectSQL.aggregate_plan?(plan)

    assert Enum.map(SelectSQL.referenced_fields(plan), & &1.name) == [
             "_2",
             "_2",
             "_3",
             "_4",
             "_4",
             "_1"
           ]
  end

  test "parses projection aliases and CAST value expressions outside aggregates" do
    plan =
      SelectSQL.parse!(
        "SELECT cast(_2 AS INT) AS score, _1 display_name FROM S3Object WHERE cast(_3 AS FLOAT) >= 2.5"
      )

    assert [
             %{
               kind: :projection,
               alias: "score",
               expr: %{kind: :cast, type: :int, expr: %{name: "_2"}}
             },
             %{kind: :projection, alias: "display_name", expr: %{name: "_1"}}
           ] = plan.projections

    assert %{kind: :cast, type: :float, expr: %{name: "_3"}} = plan.where.left
    assert plan.where.op == ">="
    assert plan.where.right == %{kind: :literal, type: :number, value: "2.5"}
    assert Enum.map(SelectSQL.referenced_fields(plan), & &1.name) == ["_2", "_1", "_3"]
  end

  test "parses CAST timestamp type and numeric type aliases" do
    plan =
      SelectSQL.parse!(
        "SELECT cast(_2 AS TIMESTAMP) AS ts, cast(_3 AS INTEGER), cast(_4 AS DECIMAL), cast(_5 AS DOUBLE) FROM S3Object WHERE cast(_2 AS TIMESTAMP) >= `2026-07-03T10:30Z`"
      )

    assert [
             %{
               kind: :projection,
               alias: "ts",
               expr: %{kind: :cast, type: :timestamp, expr: %{name: "_2"}}
             },
             %{kind: :projection, expr: %{kind: :cast, type: :int, expr: %{name: "_3"}}},
             %{kind: :projection, expr: %{kind: :cast, type: :float, expr: %{name: "_4"}}},
             %{kind: :projection, expr: %{kind: :cast, type: :float, expr: %{name: "_5"}}}
           ] = plan.projections

    assert %{kind: :cast, type: :timestamp, expr: %{name: "_2"}} = plan.where.left

    assert Enum.map(SelectSQL.referenced_fields(plan), & &1.name) == [
             "_2",
             "_3",
             "_4",
             "_5",
             "_2"
           ]
  end

  test "parses string functions as value expressions" do
    plan =
      SelectSQL.parse!(
        "SELECT lower(_1), upper(s.name), character_length(\"Display Name\") AS n FROM S3Object s WHERE char_length(trim(_2)) >= 3"
      )

    assert [
             %{kind: :projection, expr: %{kind: :string_function, function: :lower}},
             %{kind: :projection, expr: %{kind: :string_function, function: :upper}},
             %{
               kind: :projection,
               alias: "n",
               expr: %{kind: :string_function, function: :char_length}
             }
           ] = plan.projections

    assert %{kind: :string_function, function: :char_length} = plan.where.left
    assert %{kind: :string_function, function: :trim} = plan.where.left.arg

    assert Enum.map(SelectSQL.referenced_fields(plan), & &1.name) == [
             "_1",
             "name",
             "Display Name",
             "_2"
           ]
  end

  test "parses SUBSTRING and TRIM string function forms" do
    comma_plan =
      SelectSQL.parse!(
        "SELECT substring(_1, -1, 3), trim(leading 'x' from _2) FROM S3Object WHERE substring(_3 FROM 2 FOR 4) = 'keep'"
      )

    assert [
             %{
               kind: :projection,
               expr: %{kind: :string_function, function: :substring, start: -1, length: 3}
             },
             %{
               kind: :projection,
               expr: %{
                 kind: :string_function,
                 function: :trim,
                 direction: :leading,
                 characters: "x"
               }
             }
           ] = comma_plan.projections

    assert %{kind: :string_function, function: :substring, start: 2, length: 4} =
             comma_plan.where.left

    trim_plan =
      SelectSQL.parse!("SELECT trim('xy' FROM _1), trim(trailing FROM _2) FROM S3Object")

    assert [
             %{kind: :projection, expr: %{function: :trim, direction: :both, characters: "xy"}},
             %{kind: :projection, expr: %{function: :trim, direction: :trailing, characters: " "}}
           ] = trim_plan.projections
  end

  test "parses conditional expressions as value expressions" do
    plan =
      SelectSQL.parse!(
        "SELECT coalesce(_2, 'fallback') AS status, nullif(cast(_3 AS INT), 10) AS score, CASE WHEN lower(_1) = 'ada' THEN upper(_1) ELSE 'other' END AS label FROM S3Object WHERE CASE _4 WHEN 'keep' THEN _1 ELSE null END = 'Ada'"
      )

    assert [
             %{
               kind: :projection,
               alias: "status",
               expr: %{kind: :conditional_function, function: :coalesce}
             },
             %{
               kind: :projection,
               alias: "score",
               expr: %{kind: :conditional_function, function: :nullif}
             },
             %{kind: :projection, alias: "label", expr: %{kind: :case, clauses: clauses}}
           ] = plan.projections

    assert [%{condition: %{left: %{kind: :string_function, function: :lower}}}] = clauses
    assert %{kind: :simple_case, operand: %{name: "_4"}} = plan.where.left

    assert Enum.map(SelectSQL.referenced_fields(plan), & &1.name) == [
             "_2",
             "_3",
             "_1",
             "_1",
             "_4",
             "_1"
           ]
  end

  test "parses arithmetic value expressions with precedence and comparison RHS expressions" do
    plan =
      SelectSQL.parse!(
        "SELECT _1 + _2 * 3 AS total, (_1 + _2) * 3 AS grouped, -cast(_3 AS FLOAT) AS neg FROM S3Object WHERE _4 + 1 = _5 - 2"
      )

    assert [
             %{
               kind: :projection,
               alias: "total",
               expr: %{
                 kind: :arithmetic,
                 op: :add,
                 left: %{name: "_1"},
                 right: %{kind: :arithmetic, op: :multiply}
               }
             },
             %{
               kind: :projection,
               alias: "grouped",
               expr: %{
                 kind: :arithmetic,
                 op: :multiply,
                 left: %{kind: :arithmetic, op: :add},
                 right: %{kind: :literal, value: "3"}
               }
             },
             %{
               kind: :projection,
               alias: "neg",
               expr: %{
                 kind: :unary_minus,
                 expr: %{kind: :cast, type: :float, expr: %{name: "_3"}}
               }
             }
           ] = plan.projections

    assert %{kind: :arithmetic, op: :add, left: %{name: "_4"}} = plan.where.left
    assert %{kind: :arithmetic, op: :subtract, left: %{name: "_5"}} = plan.where.right

    assert Enum.map(SelectSQL.referenced_fields(plan), & &1.name) == [
             "_1",
             "_2",
             "_1",
             "_2",
             "_3",
             "_4",
             "_5"
           ]
  end

  test "parses predicate value expressions boolean literals and CAST expression operands" do
    plan =
      SelectSQL.parse!(
        "SELECT cast(_2 + 1 AS STRING), true, false FROM S3Object WHERE _1 IN (lower(_2), _3 + 1, true) AND _4 BETWEEN _5 - 1 AND _6 + 1 AND name LIKE pattern ESCAPE esc"
      )

    assert [
             %{
               kind: :projection,
               expr: %{kind: :cast, type: :string, expr: %{kind: :arithmetic}}
             },
             %{kind: :projection, expr: %{kind: :literal, type: :boolean, value: true}},
             %{kind: :projection, expr: %{kind: :literal, type: :boolean, value: false}}
           ] = plan.projections

    assert plan.where.kind == :and
    assert plan.where.left.kind == :and
    assert plan.where.left.left.predicate == :in

    assert [%{kind: :string_function, function: :lower}, %{kind: :arithmetic}, %{type: :boolean}] =
             plan.where.left.left.values

    assert plan.where.left.right.predicate == :between
    assert %{kind: :arithmetic, op: :subtract, left: %{name: "_5"}} = plan.where.left.right.lower
    assert %{kind: :arithmetic, op: :add, left: %{name: "_6"}} = plan.where.left.right.upper
    assert plan.where.right.predicate == :like
    assert plan.where.right.pattern.name == "pattern"
    assert plan.where.right.escape.name == "esc"

    assert Enum.map(SelectSQL.referenced_fields(plan), & &1.name) == [
             "_2",
             "_1",
             "_2",
             "_3",
             "_4",
             "_5",
             "_6",
             "name",
             "pattern",
             "esc"
           ]
  end

  test "parses date function value expressions and timestamp literals" do
    plan =
      SelectSQL.parse!(
        "SELECT extract(year FROM to_timestamp(_2)) AS y, date_add(day, 2, `2026-07-01T00:00:00Z`) AS plus_two, to_string(utcnow(), _3) AS now_text FROM S3Object WHERE to_timestamp(_2) BETWEEN `2026-07-01T00:00:00Z` AND date_add(day, 3, `2026-07-01T00:00:00Z`) AND date_diff(day, `2026-07-01T00:00:00Z`, to_timestamp(_2)) >= 1"
      )

    assert [
             %{
               kind: :projection,
               alias: "y",
               expr: %{kind: :date_function, function: :extract, part: :year}
             },
             %{
               kind: :projection,
               alias: "plus_two",
               expr: %{kind: :date_function, function: :date_add, part: :day}
             },
             %{
               kind: :projection,
               alias: "now_text",
               expr: %{
                 kind: :date_function,
                 function: :to_string,
                 timestamp: %{kind: :date_function, function: :utcnow},
                 pattern: %{name: "_3"}
               }
             }
           ] = plan.projections

    assert %{kind: :date_function, function: :to_timestamp, arg: %{name: "_2"}} =
             hd(plan.projections).expr.arg

    assert plan.where.kind == :and
    assert plan.where.left.predicate == :between

    assert %{kind: :literal, type: :timestamp, value: "2026-07-01T00:00:00Z"} =
             plan.where.left.lower

    assert %{kind: :date_function, function: :date_add, part: :day} = plan.where.left.upper
    assert %{kind: :date_function, function: :date_diff, part: :day} = plan.where.right.left
    assert Enum.map(SelectSQL.referenced_fields(plan), & &1.name) == ["_2", "_3", "_2", "_2"]
  end

  test "rejects unsupported expressions as structured S3 errors" do
    assert_raise Error, ~r/NotImplemented/, fn ->
      SelectSQL.parse!("SELECT abs(_1) FROM S3Object")
    end
  end

  test "rejects SQL expressions over the S3 Select size limit" do
    assert_raise Error, ~r/ExpressionTooLong/, fn ->
      SelectSQL.parse!(String.duplicate("a", 262_145))
    end
  end
end
