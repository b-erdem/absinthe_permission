defmodule AbsinthePermission.TestSupport.TodoStore do
  @moduledoc """
  In-memory store used by the integration test schema.

  Backed by `Agent`. Tests can call `seed/1` to install a list of todos
  for that test, and `clear/0` to start fresh.
  """

  use Agent

  def start_link(_opts \\ []) do
    Agent.start_link(fn -> %{} end, name: __MODULE__)
  end

  def seed(todos) do
    Agent.update(__MODULE__, fn _ -> Map.new(todos, &{&1.id, &1}) end)
  end

  def clear, do: Agent.update(__MODULE__, fn _ -> %{} end)

  def get(id), do: Agent.get(__MODULE__, &Map.get(&1, id))
end

defmodule AbsinthePermission.TestSupport.TestSchema do
  @moduledoc """
  Schema exercised by the integration tests. Demonstrates every public
  DSL feature.
  """

  use Absinthe.Schema
  use AbsinthePermission

  alias AbsinthePermission.TestSupport.TodoStore

  loaders do
    loader :todo, fn id, _ctx -> TodoStore.get(id) end
  end

  object :creator do
    field(:id, :integer)
    field(:name, :string)

    field :email, :string do
      authorize "view_emails", on_deny: :null
    end
  end

  object :todo do
    field(:id, :integer)
    field(:name, :string)
    field(:state, :string)
    field(:priority, :integer)
    field(:owner_id, :integer)
    field(:creator, :creator)
  end

  query do
    field :public_health, :string do
      resolve(fn _, _ -> {:ok, "ok"} end)
    end

    field :todos, list_of(:todo) do
      authorize "view_todos"
      resolve(fn _, _ -> {:ok, all_todos()} end)
    end

    field :todo, :todo do
      arg(:id, :integer)
      authorize "view_todo"
      resolve(fn %{id: id}, _ -> {:ok, TodoStore.get(id)} end)
    end
  end

  mutation do
    field :update_todo, :todo do
      arg(:id, :integer)
      arg(:state, :string)
      arg(:priority, :integer)

      authorize "edit_todos"
      authorize "close_todos", when: arg(:state) == "CLOSED"
      authorize "set_high_priority", when: arg(:priority) > 5

      resolve(fn _, _ -> {:ok, %{id: 1, name: "Updated"}} end)
    end

    field :update_my_todo, :todo do
      arg(:id, :integer)

      authorize_owner :todo,
        by: arg(:id),
        owner_field: :owner_id,
        if_owner: "edit_own_todo",
        if_other: "edit_others_todo"

      resolve(fn %{id: id}, _ -> {:ok, TodoStore.get(id)} end)
    end

    field :nuke_user, :string do
      arg(:user_id, :integer)
      authorize all: ["admin", "verified_2fa"]
      resolve(fn _, _ -> {:ok, "boom"} end)
    end

    field :open_admin_panel, :string do
      authorize ["admin", "support"]
      resolve(fn _, _ -> {:ok, "panel"} end)
    end
  end

  defp all_todos do
    [
      %{
        id: 1,
        name: "Write README",
        state: "OPEN",
        priority: 1,
        owner_id: 1,
        creator: %{id: 1, name: "alice", email: "alice@example.com"}
      },
      %{
        id: 2,
        name: "Ship 1.0",
        state: "OPEN",
        priority: 9,
        owner_id: 2,
        creator: %{id: 2, name: "bob", email: "bob@example.com"}
      }
    ]
  end
end
