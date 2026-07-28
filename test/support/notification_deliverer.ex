defmodule Maxio.Test.NotificationDeliverer do
  @moduledoc false

  @behaviour Maxio.S3.NotificationDelivery

  @impl true
  def deliver(event, pid) when is_pid(pid) do
    send(pid, {:maxio_notification, event})
    :ok
  end
end
