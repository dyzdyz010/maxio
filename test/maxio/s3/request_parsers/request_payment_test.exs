defmodule Maxio.S3.RequestParsers.RequestPaymentTest do
  use ExUnit.Case, async: true

  alias Maxio.S3.RequestParsers.RequestPayment

  test "parses supported Payer values" do
    for payer <- ~w(Requester BucketOwner) do
      xml = """
      <RequestPaymentConfiguration xmlns="http://s3.amazonaws.com/doc/2006-03-01/">
        <Payer>#{payer}</Payer>
      </RequestPaymentConfiguration>
      """

      assert RequestPayment.parse(xml) == {:ok, %{"Payer" => payer}}
    end
  end

  test "parses namespaced root and payer" do
    xml = """
    <s3:RequestPaymentConfiguration xmlns:s3="http://s3.amazonaws.com/doc/2006-03-01/">
      <s3:Payer>Requester</s3:Payer>
    </s3:RequestPaymentConfiguration>
    """

    assert RequestPayment.parse(xml) == {:ok, %{"Payer" => "Requester"}}
  end

  test "rejects missing duplicate or unsupported Payer" do
    assert {:error, :malformed_xml} =
             RequestPayment.parse("""
             <RequestPaymentConfiguration />
             """)

    assert {:error, :malformed_xml} =
             RequestPayment.parse("""
             <RequestPaymentConfiguration>
               <Payer>Owner</Payer>
             </RequestPaymentConfiguration>
             """)

    assert {:error, :malformed_xml} =
             RequestPayment.parse("""
             <RequestPaymentConfiguration>
               <Payer>Requester</Payer>
               <Payer>BucketOwner</Payer>
             </RequestPaymentConfiguration>
             """)
  end

  test "rejects wrong root and nested payer" do
    assert {:error, :malformed_xml} =
             RequestPayment.parse("""
             <Wrapper>
               <RequestPaymentConfiguration><Payer>Requester</Payer></RequestPaymentConfiguration>
             </Wrapper>
             """)

    assert {:error, :malformed_xml} =
             RequestPayment.parse("""
             <RequestPaymentConfiguration>
               <Wrapper><Payer>Requester</Payer></Wrapper>
             </RequestPaymentConfiguration>
             """)
  end

  test "rejects non-whitespace mixed text outside Payer" do
    assert {:error, :malformed_xml} =
             RequestPayment.parse("""
             <RequestPaymentConfiguration>
               unexpected
               <Payer>Requester</Payer>
             </RequestPaymentConfiguration>
             """)
  end
end
