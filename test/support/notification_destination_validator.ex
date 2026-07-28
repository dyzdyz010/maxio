defmodule Maxio.Test.NotificationDestinationValidator do
  @moduledoc false

  @behaviour Maxio.S3.NotificationDestinationValidator

  @impl true
  def validate(bucket, config, pid) when is_pid(pid) do
    send(pid, {:maxio_notification_destination_validation, bucket, config})
    :ok
  end

  def validate(bucket, config, opts) when is_list(opts) do
    pid = Keyword.fetch!(opts, :pid)
    result = Keyword.get(opts, :result, :ok)

    send(pid, {:maxio_notification_destination_validation, bucket, config})
    result
  end
end
