defmodule AbsinthePermission.IntegrationTest do
  use ExUnit.Case, async: false

  alias AbsinthePermission.TestSupport.{TestSchema, TodoStore}

  setup do
    TodoStore.clear()

    TodoStore.seed([
      %{id: 1, name: "alice's todo", owner_id: 1},
      %{id: 2, name: "bob's todo", owner_id: 2}
    ])

    %{
      alice: %{id: 1, name: "alice"},
      bob: %{id: 2, name: "bob"}
    }
  end

  defp run(doc, ctx) do
    Absinthe.run(doc, TestSchema, context: ctx)
  end

  defp ctx(user, perms), do: %{current_user: user, permissions: perms}

  # =========================================================================
  # Simple permission checks
  # =========================================================================

  describe "basic field-level authorize" do
    test "no rules → public field always works", %{alice: alice} do
      doc = "{ publicHealth }"
      assert {:ok, %{data: %{"publicHealth" => "ok"}}} = run(doc, ctx(alice, []))
    end

    test "authorize denies when permission is missing", %{alice: alice} do
      doc = "{ todos { id } }"
      assert {:ok, %{errors: [%{message: msg}]}} = run(doc, ctx(alice, []))
      assert msg =~ "view_todos"
    end

    test "authorize allows when permission is present", %{alice: alice} do
      doc = "{ todos { id } }"
      assert {:ok, %{data: %{"todos" => [_ | _]}}} = run(doc, ctx(alice, ["view_todos"]))
    end
  end

  # =========================================================================
  # Conditional rules
  # =========================================================================

  describe "conditional authorize via when:" do
    test "always-on rule + condition rule both pass when both perms held", %{alice: alice} do
      doc = ~s|mutation { updateTodo(id: 1, state: "CLOSED") { id } }|

      ctx = ctx(alice, ["edit_todos", "close_todos"])
      assert {:ok, %{data: %{"updateTodo" => _}}} = run(doc, ctx)
    end

    test "condition rule only fires when condition is true", %{alice: alice} do
      doc = ~s|mutation { updateTodo(id: 1, state: "OPEN") { id } }|

      # No close_todos perm, but state isn't CLOSED so it doesn't fire.
      ctx = ctx(alice, ["edit_todos"])
      assert {:ok, %{data: %{"updateTodo" => _}}} = run(doc, ctx)
    end

    test "condition rule denies when fired and perm missing", %{alice: alice} do
      doc = ~s|mutation { updateTodo(id: 1, state: "CLOSED") { id } }|

      ctx = ctx(alice, ["edit_todos"])
      assert {:ok, %{errors: [%{message: msg}]}} = run(doc, ctx)
      assert msg =~ "close_todos"
    end

    test "comparison: priority > 5", %{alice: alice} do
      doc = "mutation { updateTodo(id: 1, priority: 9) { id } }"

      ctx = ctx(alice, ["edit_todos"])
      assert {:ok, %{errors: [%{message: msg}]}} = run(doc, ctx)
      assert msg =~ "set_high_priority"
    end

    test "comparison: priority <= 5 doesn't fire", %{alice: alice} do
      doc = "mutation { updateTodo(id: 1, priority: 3) { id } }"

      ctx = ctx(alice, ["edit_todos"])
      assert {:ok, %{data: %{"updateTodo" => _}}} = run(doc, ctx)
    end
  end

  # =========================================================================
  # Permission shapes
  # =========================================================================

  describe "permission shapes" do
    test "any-of: list permission grants if user has ANY one", %{alice: alice} do
      doc = "mutation { openAdminPanel }"

      assert {:ok, %{data: %{"openAdminPanel" => _}}} = run(doc, ctx(alice, ["support"]))
      assert {:ok, %{data: %{"openAdminPanel" => _}}} = run(doc, ctx(alice, ["admin"]))
      assert {:ok, %{errors: _}} = run(doc, ctx(alice, ["randomthing"]))
    end

    test "all-of: requires every permission", %{alice: alice} do
      doc = "mutation { nukeUser(userId: 99) }"

      # Missing one
      assert {:ok, %{errors: _}} = run(doc, ctx(alice, ["admin"]))
      assert {:ok, %{errors: _}} = run(doc, ctx(alice, ["verified_2fa"]))

      # Has both
      assert {:ok, %{data: %{"nukeUser" => "boom"}}} =
               run(doc, ctx(alice, ["admin", "verified_2fa"]))
    end
  end

  # =========================================================================
  # Owner-vs-others
  # =========================================================================

  describe "authorize_owner sugar" do
    test "user editing their own todo needs `if_owner` perm", %{alice: alice} do
      doc = "mutation { updateMyTodo(id: 1) { id } }"

      assert {:ok, %{errors: [%{message: msg}]}} = run(doc, ctx(alice, []))
      assert msg =~ "edit_own_todo"

      assert {:ok, %{data: %{"updateMyTodo" => _}}} =
               run(doc, ctx(alice, ["edit_own_todo"]))
    end

    test "user editing another's todo needs `if_other` perm", %{alice: alice} do
      doc = "mutation { updateMyTodo(id: 2) { id } }"

      assert {:ok, %{errors: [%{message: msg}]}} = run(doc, ctx(alice, ["edit_own_todo"]))
      assert msg =~ "edit_others_todo"

      assert {:ok, %{data: %{"updateMyTodo" => _}}} =
               run(doc, ctx(alice, ["edit_others_todo"]))
    end
  end

  # =========================================================================
  # Post-op redaction
  # =========================================================================

  describe "post-op redaction (on_deny: :null)" do
    test "field is nullified when permission missing", %{alice: alice} do
      doc = "{ todos { id name creator { id name email } } }"

      {:ok, %{data: %{"todos" => todos}}} =
        run(doc, ctx(alice, ["view_todos"]))

      assert Enum.all?(todos, &(get_in(&1, ["creator", "email"]) == nil))
      assert Enum.all?(todos, &(get_in(&1, ["creator", "name"]) != nil))
    end

    test "field shown when permission present", %{alice: alice} do
      doc = "{ todos { creator { email } } }"

      {:ok, %{data: %{"todos" => todos}}} =
        run(doc, ctx(alice, ["view_todos", "view_emails"]))

      assert Enum.all?(todos, &(get_in(&1, ["creator", "email"]) != nil))
    end
  end

  # =========================================================================
  # Missing context
  # =========================================================================

  describe "missing context" do
    test "raises by default when context lacks current_user/permissions" do
      doc = "{ todos { id } }"

      assert_raise AbsinthePermission.MissingContextError, ~r/missing required keys/, fn ->
        Absinthe.run(doc, TestSchema, context: %{})
      end
    end
  end

  # =========================================================================
  # Telemetry
  # =========================================================================

  describe "telemetry" do
    test "emits :allow event on successful auth", %{alice: alice} do
      :telemetry.attach(
        "test-allow",
        [:absinthe_permission, :decision, :allow],
        fn _event, _meas, meta, _ -> send(self(), {:allow, meta}) end,
        nil
      )

      try do
        run("{ todos { id } }", ctx(alice, ["view_todos"]))
        assert_receive {:allow, %{field: :todos}}
      after
        :telemetry.detach("test-allow")
      end
    end

    test "emits :deny event on auth failure", %{alice: alice} do
      :telemetry.attach(
        "test-deny",
        [:absinthe_permission, :decision, :deny],
        fn _event, _meas, meta, _ -> send(self(), {:deny, meta}) end,
        nil
      )

      try do
        run("{ todos { id } }", ctx(alice, []))
        assert_receive {:deny, %{field: :todos, decision: %{permission: "view_todos"}}}
      after
        :telemetry.detach("test-deny")
      end
    end
  end

  # =========================================================================
  # Introspection API
  # =========================================================================

  describe "introspection API" do
    test "rules_for/3 returns rules for a field" do
      rules = AbsinthePermission.rules_for(TestSchema, :mutation, :update_todo)

      assert length(rules) == 3
      assert Enum.all?(rules, &match?(%AbsinthePermission.Rule{}, &1))

      perms = Enum.map(rules, & &1.permission)
      assert {:any, ["edit_todos"]} in perms
      assert {:any, ["close_todos"]} in perms
      assert {:any, ["set_high_priority"]} in perms
    end

    test "rules_for/3 returns [] for unknown fields" do
      assert [] == AbsinthePermission.rules_for(TestSchema, :nonexistent, :nope)
    end

    test "loads_for/3 returns loads attached to a field" do
      [load] = AbsinthePermission.loads_for(TestSchema, :mutation, :update_my_todo)
      assert %AbsinthePermission.Load{name: :todo, loader: :todo} = load
    end

    test "loader/2 returns the registered function" do
      fun = AbsinthePermission.loader(TestSchema, :todo)
      assert is_function(fun, 2)
    end

    test "all_rules/1 returns rules grouped by scope" do
      all = AbsinthePermission.all_rules(TestSchema)
      assert is_map(all)
      assert Map.has_key?(all, {:mutation, :update_todo})
    end
  end
end
