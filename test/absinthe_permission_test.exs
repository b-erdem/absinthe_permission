defmodule AbsinthePermissionTest do
  use ExUnit.Case
  doctest Absinthe.Permission

  defmodule TodoSchema do
    use Absinthe.Schema

    object :creator do
      field(:id, :integer)
      field(:name, :string)
      field(:email, :string)
    end

    object :todo do
      field(:id, :integer)
      field(:name, :string)
      field(:detail, :string)
      field(:creator, :creator)
    end

    query do
      field :get_todo_list, list_of(:todo) do
        meta(
          policies: [
            [required_permission: "can_view_asdf"]
          ]
        )

        resolve(fn _, _ ->
          {:ok,
           [
             %{
               id: 1,
               name: "Todo 1",
               detail: "Finish tests.",
               creator: %{id: 1, name: "Baris", email: "baris@erdem.dev"}
             }
           ]}
        end)
      end

      field :get_todo_by_id, :todo do
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
        arg(:id, :integer)
        arg(:name, :string)
        arg(:detail, :string)

        resolve(fn _, _ ->
          {:ok, %{}}
        end)
      end

      field :delete_todo, :todo do
        arg(:id, :integer)

        resolve(fn _, _ ->
          {:ok, %{}}
        end)
      end
    end

    def middleware(middleware, _field, _object) do
      [Absinthe.Permission] ++ middleware ++ [Absinthe.Permission]
    end
  end

  defmodule ProjectSchema do
    use Absinthe.Schema

    object :project do
      field(:name, :string)
    end

    object :user do
      field(:id, :integer)
      field(:name, :string)
      field(:manager, :user)
      field(:project, :project)
    end

    object :task do
      field(:name, :string)
      field(:description, :string)
      field(:assignee, :user)
      field(:reporter, :user)
    end

    query do
      field :projects, list_of(:project) do
        resolve(fn _, _ ->
          {:ok, []}
        end)
      end
    end

    def middleware(middleware, _field, _object) do
      middleware ++ [Absinthe.Permission]
    end
  end

  test "get todo list" do
    doc = """
      { getTodoList { id, name, detail, creator { id, name, email } } }
    """

    current_user = %{id: 1, name: "Baris", email: "baris@erdem.dev"}
    user_perms = ["can_view_todo_list"]

    {:ok, res} =
      Absinthe.run(doc, TodoSchema,
        context: %{auth: %{current_user: current_user, permissions: user_perms}}
      )
      |> IO.inspect(label: "res")
  end
end
