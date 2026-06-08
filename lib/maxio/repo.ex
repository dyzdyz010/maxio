defmodule Maxio.Repo do
  use Ecto.Repo,
    otp_app: :maxio,
    adapter: Ecto.Adapters.Postgres
end
