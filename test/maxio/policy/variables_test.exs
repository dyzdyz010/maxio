defmodule Maxio.Policy.VariablesTest do
  use ExUnit.Case, async: true
  alias Maxio.Policy.Variables

  test "expands scalar context values case-insensitively and special literals" do
    ctx = %{"aws:username" => "alice", "aws:userid" => "AIDA123"}

    assert {:ok, expanded} =
             Variables.expand_string("home/${AWS:UserName}/${aws:userid}/${*}/${?}/${$}", ctx)

    assert Variables.render_literals(expanded) == "home/alice/AIDA123/*/?/$"
  end

  test "supports default value syntax for missing variables" do
    assert Variables.expand_string("home/${aws:username, 'public'}/*", %{}) ==
             {:ok, "home/public/*"}
  end

  test "serializes scalar non-string context values" do
    assert Variables.expand_string("secure/${aws:SecureTransport}/max/${s3:max-keys}", %{
             "aws:SecureTransport" => true,
             "s3:max-keys" => 25
           }) == {:ok, "secure/true/max/25"}

    assert Variables.expand_string("at/${aws:CurrentTime}", %{
             "aws:CurrentTime" => ~U[2026-06-12 00:00:00Z]
           }) == {:ok, "at/2026-06-12T00:00:00Z"}
  end

  test "unresolved variables fail when context value is missing empty or multivalued" do
    assert :unresolved = Variables.expand_string("home/${aws:username}", %{})
    assert :unresolved = Variables.expand_string("home/${aws:username}", %{"aws:username" => ""})

    assert :unresolved =
             Variables.expand_string("home/${aws:username}", %{"aws:username" => ["a"]})
  end

  test "unresolved condition variables return a sentinel" do
    assert Variables.unresolved?(Variables.expand_condition_value("home/${aws:username}", %{}))
  end
end
