defmodule AbsinthePermission.EvaluatorTest do
  use ExUnit.Case, async: true

  alias AbsinthePermission.{Decision, Evaluator, Load, Rule}

  describe "condition_fires?/4" do
    test ":always is always true" do
      assert Evaluator.condition_fires?(:always, %{}, %{}, %{})
    end

    test "{:cmp, [:eq, lhs, rhs]} compares values" do
      cond_ = {:cmp, [:eq, {:arg, :state}, {:literal, "CLOSED"}]}

      assert Evaluator.condition_fires?(cond_, %{state: "CLOSED"}, %{}, %{})
      refute Evaluator.condition_fires?(cond_, %{state: "OPEN"}, %{}, %{})
      refute Evaluator.condition_fires?(cond_, %{}, %{}, %{})
    end

    test ":gt / :lt comparisons" do
      gt = {:cmp, [:gt, {:arg, :n}, {:literal, 5}]}

      assert Evaluator.condition_fires?(gt, %{n: 9}, %{}, %{})
      refute Evaluator.condition_fires?(gt, %{n: 5}, %{}, %{})
      refute Evaluator.condition_fires?(gt, %{n: 1}, %{}, %{})
      refute Evaluator.condition_fires?(gt, %{n: nil}, %{}, %{})
    end

    test ":in compares against a literal list" do
      in_list = {:cmp, [:in, {:arg, :role}, {:literal, ["admin", "support"]}]}

      assert Evaluator.condition_fires?(in_list, %{role: "admin"}, %{}, %{})
      assert Evaluator.condition_fires?(in_list, %{role: "support"}, %{}, %{})
      refute Evaluator.condition_fires?(in_list, %{role: "user"}, %{}, %{})
    end

    test ":and / :or / :not combinators" do
      a = {:cmp, [:eq, {:arg, :a}, {:literal, 1}]}
      b = {:cmp, [:eq, {:arg, :b}, {:literal, 2}]}

      assert Evaluator.condition_fires?({:and, [a, b]}, %{a: 1, b: 2}, %{}, %{})
      refute Evaluator.condition_fires?({:and, [a, b]}, %{a: 1, b: 9}, %{}, %{})

      assert Evaluator.condition_fires?({:or, [a, b]}, %{a: 1, b: 9}, %{}, %{})
      assert Evaluator.condition_fires?({:or, [a, b]}, %{a: 9, b: 2}, %{}, %{})
      refute Evaluator.condition_fires?({:or, [a, b]}, %{a: 9, b: 9}, %{}, %{})

      assert Evaluator.condition_fires?({:not, a}, %{a: 9}, %{}, %{})
      refute Evaluator.condition_fires?({:not, a}, %{a: 1}, %{}, %{})
    end

    test ":fun escape hatch — anonymous fn/1" do
      cond_ = {:fun, fn %{args: a} -> a[:state] == "CLOSED" end}

      assert Evaluator.condition_fires?(cond_, %{state: "CLOSED"}, %{}, %{})
      refute Evaluator.condition_fires?(cond_, %{state: "OPEN"}, %{}, %{})
    end
  end

  describe "eval_expr/4" do
    test "literal pass-through" do
      assert "x" == Evaluator.eval_expr({:literal, "x"}, %{}, %{}, %{})
    end

    test "arg lookup" do
      assert "y" == Evaluator.eval_expr({:arg, :name}, %{name: "y"}, %{}, %{})
      assert nil == Evaluator.eval_expr({:arg, :missing}, %{}, %{}, %{})
    end

    test "loaded path traversal" do
      loaded = %{todo: %{owner: %{id: 42}}}
      assert 42 == Evaluator.eval_expr({:loaded, [:todo, :owner, :id]}, %{}, %{}, loaded)
    end

    test "current_user path" do
      ctx = %{current_user: %{id: 7, profile: %{name: "alice"}}}
      assert 7 == Evaluator.eval_expr({:current_user, [:id]}, %{}, ctx, %{})
      assert "alice" == Evaluator.eval_expr({:current_user, [:profile, :name]}, %{}, ctx, %{})
    end

    test "missing intermediate map key returns nil" do
      ctx = %{current_user: %{id: 7}}
      assert nil == Evaluator.eval_expr({:current_user, [:profile, :name]}, %{}, ctx, %{})
    end
  end

  describe "has_permission?/2" do
    test "nil = no requirement" do
      assert Evaluator.has_permission?(nil, [])
    end

    test "any-of: at least one needed" do
      assert Evaluator.has_permission?({:any, ["admin", "support"]}, ["support"])
      refute Evaluator.has_permission?({:any, ["admin", "support"]}, ["user"])
    end

    test "all-of: all needed" do
      assert Evaluator.has_permission?({:all, ["admin", "2fa"]}, ["admin", "2fa", "extra"])
      refute Evaluator.has_permission?({:all, ["admin", "2fa"]}, ["admin"])
    end
  end

  describe "evaluate_pre/6" do
    defp simple_rule(perm, condition \\ :always, opts \\ []) do
      %Rule{
        phase: :pre,
        permission: AbsinthePermission.Rule.normalize_permission(perm),
        condition: condition,
        on_deny: Keyword.get(opts, :on_deny, :error),
        error_message: Keyword.get(opts, :error_message),
        location: %{file: "test", line: 0}
      }
    end

    defmodule NoLoadersSchema do
      def __absinthe_permission_loader__(_), do: nil
    end

    test "all rules pass → :allow" do
      rules = [simple_rule("a"), simple_rule("b")]
      ctx = %{permissions: ["a", "b"]}

      decision = Evaluator.evaluate_pre(rules, [], NoLoadersSchema, %{}, ctx)
      assert decision.verdict == :allow
      assert length(decision.matched_rules) == 2
    end

    test "first failing rule causes deny" do
      rules = [simple_rule("a"), simple_rule("b")]
      ctx = %{permissions: ["a"]}

      decision = Evaluator.evaluate_pre(rules, [], NoLoadersSchema, %{}, ctx)
      assert decision.verdict == :deny
      assert decision.permission == "b"
      assert decision.reason == :missing_permission
    end

    test "rules with non-firing condition are skipped" do
      cond_state = {:cmp, [:eq, {:arg, :state}, {:literal, "CLOSED"}]}
      rules = [simple_rule("close_todos", cond_state)]
      ctx = %{permissions: []}

      # State is "OPEN" so the rule doesn't fire — allow.
      decision = Evaluator.evaluate_pre(rules, [], NoLoadersSchema, %{state: "OPEN"}, ctx)
      assert decision.verdict == :allow
      assert decision.matched_rules == []
    end

    defmodule TodoLoaderSchema do
      def __absinthe_permission_loader__(:todo), do: fn id, _ -> %{id: id, owner_id: 99} end
      def __absinthe_permission_loader__(_), do: nil
    end

    test "loads resolve before rules evaluate" do
      load = %Load{name: :todo, loader: :todo, by: {:arg, :id}, remote_key: nil}

      cond_ = {:cmp, [:eq, {:loaded, [:todo, :owner_id]}, {:literal, 99}]}
      rules = [simple_rule("ok", cond_)]
      ctx = %{permissions: ["ok"]}

      decision = Evaluator.evaluate_pre(rules, [load], TodoLoaderSchema, %{id: 1}, ctx)

      assert decision.verdict == :allow
      assert decision.loaded.todo.owner_id == 99
    end

    test "missing loader → :load_failed" do
      load = %Load{name: :nope, loader: :nope, by: {:literal, 1}, remote_key: nil}
      decision = Evaluator.evaluate_pre([], [load], NoLoadersSchema, %{}, %{permissions: []})
      assert decision.verdict == :deny
      assert decision.reason == :load_failed
    end
  end

  describe "Decision struct helpers" do
    test "allow/1 / deny/1 build the right verdict" do
      assert %Decision{verdict: :allow, field: :foo} = Decision.allow(field: :foo)

      assert %Decision{verdict: :deny, reason: :missing_permission} =
               Decision.deny(reason: :missing_permission)
    end
  end
end
