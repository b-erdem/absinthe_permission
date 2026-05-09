defmodule AbsinthePermission.ConditionTest do
  use ExUnit.Case, async: true
  doctest AbsinthePermission.Condition

  alias AbsinthePermission.Condition

  describe "format/1" do
    test "literal" do
      assert "1" == Condition.format({:literal, 1})
      assert ~s|"x"| == Condition.format({:literal, "x"})
    end

    test "arg / loaded / current_user paths" do
      assert "arg(:state)" == Condition.format({:arg, :state})
      assert "loaded(:todo).owner_id" == Condition.format({:loaded, [:todo, :owner_id]})
      assert "current_user.id" == Condition.format({:current_user, [:id]})
    end

    test "comparisons" do
      cmp = {:cmp, [:eq, {:arg, :state}, {:literal, "CLOSED"}]}
      assert ~s|arg(:state) == "CLOSED"| == Condition.format(cmp)

      gt = {:cmp, [:gt, {:arg, :n}, {:literal, 5}]}
      assert "arg(:n) > 5" == Condition.format(gt)
    end

    test "combinators" do
      a = {:cmp, [:eq, {:arg, :a}, {:literal, 1}]}
      b = {:cmp, [:eq, {:arg, :b}, {:literal, 2}]}

      assert "(arg(:a) == 1 and arg(:b) == 2)" == Condition.format({:and, [a, b]})
      assert "not arg(:a) == 1" == Condition.format({:not, a})
    end
  end

  describe "valid_op?/1" do
    test "every supported op" do
      for op <- [:eq, :neq, :gt, :gte, :lt, :lte, :in, :not_in] do
        assert Condition.valid_op?(op), "#{op} should be valid"
      end
    end

    test "rejects others" do
      refute Condition.valid_op?(:approx_eq)
    end
  end
end
