Application.put_env(:absinthe_permission, :fetchers,
  todo_db: {AbsinthePermissionTest.TodoDb, :fetch},
  ecto: {AbsinthePermissionTest.EctoFetcher, :fetch}
)

ExUnit.start()
