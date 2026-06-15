defmodule Maxio.S3.RequestParsers.AccelerateTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.Accelerate

  test "parses supported Status values" do
    for status <- ~w(Enabled Suspended) do
      xml = """
      <AccelerateConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Status>#{status}</Status>
      </AccelerateConfiguration>
      """

      assert Accelerate.parse(xml) == {:ok, %{"Status" => status}}
    end
  end

  test "parses namespaced root and empty configuration" do
    xml = """
    <s3:AccelerateConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/" />
    """

    assert Accelerate.parse(xml) == {:ok, %{"Status" => nil}}
  end

  test "rejects unsupported duplicate or misnested Status" do
    assert {:error, :malformed_xml} =
             Accelerate.parse("""
             <AccelerateConfiguration><Status>Disabled</Status></AccelerateConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Accelerate.parse("""
             <AccelerateConfiguration>
               <Status>Enabled</Status>
               <Status>Suspended</Status>
             </AccelerateConfiguration>
             """)

    assert {:error, :malformed_xml} =
             Accelerate.parse("""
             <AccelerateConfiguration>
               <Wrapper><Status>Enabled</Status></Wrapper>
             </AccelerateConfiguration>
             """)
  end

  test "rejects wrong root and mixed text" do
    assert {:error, :malformed_xml} =
             Accelerate.parse("""
             <Wrapper><AccelerateConfiguration><Status>Enabled</Status></AccelerateConfiguration></Wrapper>
             """)

    assert {:error, :malformed_xml} =
             Accelerate.parse("""
             <AccelerateConfiguration>
               unexpected
               <Status>Enabled</Status>
             </AccelerateConfiguration>
             """)
  end
end
