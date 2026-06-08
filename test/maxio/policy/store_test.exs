defmodule Maxio.Policy.StoreTest do
  use Maxio.DataCase, async: true
  alias Maxio.Policy.Store

  @policy ~s({"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":"*","Action":"s3:GetObject","Resource":"arn:aws:s3:::b/*"}]})

  test "put → get round-trip（语义等价）" do
    assert :ok = Store.put_bucket_policy("b", @policy)
    assert {:ok, json} = Store.get_bucket_policy("b")
    assert {:ok, decoded} = Jason.decode(json)
    assert decoded["Statement"] |> hd() |> Map.get("Effect") == "Allow"
  end

  test "无 policy → :none / []" do
    assert :none = Store.get_bucket_policy("nope")
    assert [] = Store.statements_for_bucket("nope")
  end

  test "statements_for_bucket 解析为 Statement 列表" do
    Store.put_bucket_policy("b2", @policy)
    assert [%Maxio.Policy.Statement{effect: :allow}] = Store.statements_for_bucket("b2")
  end

  test "put 覆盖（upsert）" do
    Store.put_bucket_policy("b3", @policy)

    deny =
      ~s({"Statement":{"Effect":"Deny","Principal":"*","Action":"s3:*","Resource":["arn:aws:s3:::b3","arn:aws:s3:::b3/*"]}})

    assert :ok = Store.put_bucket_policy("b3", deny)
    assert [%{effect: :deny}] = Store.statements_for_bucket("b3")
  end

  test "delete 幂等" do
    Store.put_bucket_policy("b4", @policy)
    assert :ok = Store.delete_bucket_policy("b4")
    assert :none = Store.get_bucket_policy("b4")
    assert :ok = Store.delete_bucket_policy("b4")
  end

  test "principal_policies MVP 恒 []" do
    assert [] = Store.principal_policies(:anonymous)
    assert [] = Store.principal_policies(%{type: :root})
  end
end
