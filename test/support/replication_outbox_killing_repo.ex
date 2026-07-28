defmodule Maxio.Test.ReplicationOutboxKillingRepo do
  @moduledoc false

  def transaction(_fun), do: Process.exit(self(), :kill)
end
