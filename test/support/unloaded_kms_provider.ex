defmodule Maxio.Test.UnloadedKMSProvider do
  @moduledoc false

  @behaviour Maxio.KMS.Provider

  @impl true
  def generate_data_key(_key_id, _context), do: {:error, :not_used}

  @impl true
  def decrypt_data_key(_envelope, _context), do: {:error, :not_used}

  def default_key_id, do: "alias/unloaded-provider"

  def production_hsm?, do: true
end
