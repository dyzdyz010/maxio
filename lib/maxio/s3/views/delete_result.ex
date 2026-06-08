defmodule Maxio.S3.Views.DeleteResult do
  @moduledoc "DeleteObjects 响应 XML（DeleteResult）。verbose 含每个 Deleted；quiet 仅 Error。"
  import Saxy.XML
  alias Maxio.S3.XML

  @spec render(%{
          deleted: [String.t()],
          errors: [%{key: String.t(), code: String.t(), message: String.t()}]
        }) :: iodata()
  def render(%{deleted: deleted, errors: errors}) do
    deleted_elems =
      Enum.map(deleted, fn key ->
        element("Deleted", [], [element("Key", [], characters(key))])
      end)

    error_elems =
      Enum.map(errors, fn e ->
        element("Error", [], [
          element("Key", [], characters(e.key)),
          element("Code", [], characters(e.code)),
          element("Message", [], characters(e.message))
        ])
      end)

    root = element("DeleteResult", [{"xmlns", XML.namespace()}], deleted_elems ++ error_elems)
    XML.encode(root)
  end
end
