defmodule Maxio.Test.BlockingNotifyTransport do
  @moduledoc false

  def broadcast(_pubsub, _topic, event) do
    owner = Application.fetch_env!(:maxio, :blocking_notify_test_owner)
    send(owner, {:blocking_notify_attempt, event, self()})

    receive do
      {:release_blocking_notify, ^event} -> :ok
    after
      5_000 -> exit(:blocking_notify_test_timeout)
    end
  end
end
