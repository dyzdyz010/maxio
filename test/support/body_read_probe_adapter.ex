defmodule Maxio.Test.BodyReadProbeAdapter do
  @moduledoc false

  def send_resp({owner, state}, status, headers, body) do
    {:ok, sent_body, next_state} =
      Plug.Adapters.Test.Conn.send_resp(state, status, headers, body)

    {:ok, sent_body, {owner, next_state}}
  end

  def read_req_body({owner, state}, opts) do
    send(owner, :body_reader_called)

    case Plug.Adapters.Test.Conn.read_req_body(state, opts) do
      {status, body, next_state} -> {status, body, {owner, next_state}}
    end
  end
end
