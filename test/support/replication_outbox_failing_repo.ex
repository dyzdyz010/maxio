defmodule Maxio.Test.ReplicationOutboxFailingRepo do
  @moduledoc false

  def transaction(_fun), do: {:error, :forced_replication_scheduler_failure}
end
