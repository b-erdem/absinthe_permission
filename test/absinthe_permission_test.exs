defmodule AbsinthePermissionTest do
  use ExUnit.Case
  doctest AbsinthePermission

  defmodule TodoDb do
    @behaviour GenServer

    def start_link do
      GenServer.start_link(__MODULE__, [], name: :todo_db)
    end

    def init(_) do
      {:ok, []}
    end

    def fetch(%{key: key, value: val}, _condition, _args, _context, _extras) do
      res = GenServer.call(:todo_db, {:fetch, key, val})
      {:ok, res}
    end

    def get(id) do
      GenServer.call(:todo_db, {:get, id})
    end

    def create(id, name, detail, creator) do
      GenServer.call(:todo_db, {:create, id, name, detail, creator})
    end

    def update(id) do
      GenServer.call(:todo_db, {:update, id})
    end

    def delete(id) do
      GenServer.call(:todo_db, {:delete, id})
    end

    def handle_call({:get, id}, _from, state) do
      {:reply, Enum.find(state, &(&1.id == id)), state}
    end

    def handle_call({:fetch, key, val}, _from, state) do
      todo = Enum.find(state, &(Map.get(&1, key) == val))
      {:reply, todo, state}
    end

    def handle_call({:create, id, name, detail, creator}, _from, state) do
      todo = %{id: id, name: name, detail: detail, creator: creator}
      {:reply, todo, [todo | state]}
    end

    def handle_call({:update, id, name, detail, creator}, _from, state) do
      todo = Enum.find(state, &(&1.id == id))
      new_todo = %{id: todo.id, name: name, detail: detail, creator: todo.creator}
      todos = Enum.reject(state, &(&1.id == id))
      {:reply, new_todo, [new_todo | todos]}
    end

    def handle_call({:delete, id}, _from, state) do
      {:reply, Enum.find(state, &(&1.id == id)), Enum.reject(state, &(&1.id == id))}
    end
  end

  defmodule EctoFetcher do
    @spec fetch(map(), Keyword.t(), Keyword.t(), Keyword.t(), map()) :: {:ok, any}
    def fetch(clause, _condition, _args, _context, extras) do
      repo = Keyword.get(extras, :repo)
      model = Keyword.get(extras, :model)

      {:ok, repo.get_by(model, {clause.key, clause.val})}
    end
  end

  defmodule TodoSchema do
    use Absinthe.Schema

    object :creator do
      field(:id, :integer)
      field(:name, :string)

      field(:email, :string) do
        meta(
          post_op_policies: [
            [
              creator__id: {:current_user_id, :neq},
              required_permission: "can_view_other_users_emails"
            ]
          ]
        )
      end
    end

    object :todo do
      field(:id, :integer)
      field(:name, :string)
      field(:detail, :string)
      field(:creator, :creator)
    end

    object :todo_list do
      field(:data, list_of(:todo)) do
        meta(
          post_op_policies: [
            [
              creator__id: {:current_user_id, :neq},
              required_permission: "can_view_other_users_todos"
            ]
          ]
        )
      end
    end

    query do
      field :get_todo_list, :todo_list do
        meta(
          pre_op_policies: [
            [required_permission: "can_view_todo_list"]
          ]
        )

        resolve(fn _, _ ->
          {:ok,
           %{
             data: [
               %{
                 id: 1,
                 name: "Todo 1",
                 detail: "Finish tests.",
                 creator: %{id: 1, name: "Baris", email: "baris@erdem.dev"}
               },
               %{
                 id: 2,
                 name: "Todo 2",
                 detail: "Write some docs.",
                 creator: %{id: 2, name: "Random", email: "random@guy.com"}
               }
             ]
           }}
        end)
      end

      field :get_todo_by_id, :todo do
        meta(required_permission: "can_view_a_todo")

        arg(:id, :integer)

        resolve(fn _, _ ->
          {:ok, %{}}
        end)
      end
    end

    mutation do
      field :create_todo, :todo do
        arg(:name, :string)
        arg(:detail, :string)
        arg(:creator_id, :integer)

        resolve(fn _, _ ->
          {:ok, %{}}
        end)
      end

      field :update_todo, :todo do
        meta(
          pre_op_policies: [
            [
              remote_context: [
                config: [fetcher_key: :todo_db, remote_key: :id, input_key: :id],
                fields: [creator__id: {:current_user_id, :neq}],
                extras: [model: :todo]
              ],
              required_permission: "can_change_other_users_todo"
            ]
          ]
        )

        arg(:id, :integer)
        arg(:name, :string)
        arg(:detail, :string)

        resolve(fn %{id: id}, _ ->
          {:ok, GenServer.call(:todo_db, {:get, id})}
        end)
      end

      field :delete_todo, :todo do
        meta(
          pre_op_policies: [
            [
              remote_context: [
                config: [fetcher_key: :todo_db, remote_key: :id, input_key: :id],
                fields: [creator__id: {:current_user_id, :neq}],
                extras: [model: :todo],
                required_permission: "can_delete_other_users_todo"
              ]
            ],
            [
              required_permission: "can_delete_any_todo"
            ]
          ]
        )

        arg(:id, :integer)

        resolve(fn _, _ ->
          {:ok, %{}}
        end)
      end
    end

    def middleware(middleware, _field, _object) do
      [AbsinthePermission.Middleware.HasPermission] ++
        middleware ++ [AbsinthePermission.Middleware.HasPermission]
    end
  end

  test "pre op policy -- get todo list permission denied" do
    doc = """
      { getTodoList { data { id, name, detail } } }
    """

    current_user = %{id: 1, name: "Baris", email: "baris@erdem.dev"}
    user_perms = ["can_view_asdf"]

    {:ok, %{errors: [%{message: "Unauthorized"}]}} =
      Absinthe.run(doc, TodoSchema,
        context: %{current_user: current_user, permissions: user_perms}
      )
  end

  test "pre & post op policies -- get todo list permission granted" do
    doc = """
      { getTodoList { data { id, name, detail } } }
    """

    current_user = %{id: 1, name: "Baris", email: "baris@erdem.dev"}
    user_perms = ["can_view_todo_list", "can_view_other_users_todos"]

    {:ok, %{data: %{"getTodoList" => %{"data" => data}}}} =
      Absinthe.run(doc, TodoSchema,
        context: %{current_user: current_user, permissions: user_perms}
      )

    assert length(data) == 2
  end

  test "post operation policy -- can view his own todo list" do
    doc = """
      { getTodoList { data { id, name, detail } } }
    """

    current_user = %{id: 1, name: "Baris", email: "random@guy.com"}
    user_perms = ["can_view_todo_list"]

    {:ok, %{data: %{"getTodoList" => %{"data" => data}}}} =
      Absinthe.run(doc, TodoSchema,
        context: %{current_user: current_user, permissions: user_perms}
      )

    assert length(data) == 1
  end

  test "pre operation policy with remote context -- can update/delete his own todo" do
    doc = """
      mutation { updateTodo(id: 1, name: "Prepare README", detail: "Provide all information in README file.") { id, name, detail } }
    """

    _ = TodoDb.start_link()

    current_user = %{id: 1, name: "Baris", email: "baris@erdem.dev"}
    user_perms = ["perm1", "perm2"]

    _ =
      TodoDb.create(1, "Todo1", "Some descriptions", %{
        id: 2,
        name: "Random",
        email: "random@guy.com"
      })

    {:ok, %{errors: [%{message: "Unauthorized"}]}} =
      Absinthe.run(doc, TodoSchema,
        context: %{current_user: current_user, permissions: user_perms}
      )
  end
end
