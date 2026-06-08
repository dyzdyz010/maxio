ExUnit.start()
# M7：:peer 真节点集成测试默认排除（确定性 InProcess 覆盖为主力）；单独跑：mix test --include distributed
ExUnit.configure(exclude: [:distributed])
Ecto.Adapters.SQL.Sandbox.mode(Maxio.Repo, :manual)
