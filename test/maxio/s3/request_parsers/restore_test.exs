defmodule Maxio.S3.RequestParsers.RestoreTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Restore

  test "parses restore request days and optional tier" do
    xml =
      ~s(<RestoreRequest><Days>7</Days><GlacierJobParameters><Tier>Bulk</Tier></GlacierJobParameters></RestoreRequest>)

    assert {:ok, request} = Restore.parse(xml)
    assert request["Days"] == 7
    assert request["Tier"] == "Bulk"
  end

  test "rejects missing or invalid days" do
    assert {:error, :malformed_xml} = Restore.parse(~s(<RestoreRequest></RestoreRequest>))

    assert {:error, :malformed_xml} =
             Restore.parse(~s(<RestoreRequest><Days>0</Days></RestoreRequest>))
  end

  test "select restore is explicitly unsupported" do
    xml =
      ~s(<RestoreRequest><Days>1</Days><Type>SELECT</Type><SelectParameters></SelectParameters></RestoreRequest>)

    assert {:error, :select_restore} = Restore.parse(xml)
  end
end
