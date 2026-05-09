defmodule AbsinthePermission.RuleTest do
  use ExUnit.Case, async: true
  doctest AbsinthePermission.Rule

  alias AbsinthePermission.Rule

  describe "normalize_permission/1" do
    test "binary → any-of-one" do
      assert {:any, ["x"]} == Rule.normalize_permission("x")
    end

    test "list of binaries → any-of" do
      assert {:any, ["a", "b"]} == Rule.normalize_permission(["a", "b"])
    end

    test "nil → nil" do
      assert nil == Rule.normalize_permission(nil)
    end

    test "tuple form" do
      assert {:all, ["a", "b"]} == Rule.normalize_permission({:all, ["a", "b"]})
      assert {:any, ["a", "b"]} == Rule.normalize_permission({:any, ["a", "b"]})
    end

    test "keyword-list sugar `all: [...]` and `any: [...]`" do
      assert {:all, ["a", "b"]} == Rule.normalize_permission([{:all, ["a", "b"]}])
      assert {:any, ["a", "b"]} == Rule.normalize_permission([{:any, ["a", "b"]}])
    end

    test "rejects non-string permissions" do
      assert_raise ArgumentError, ~r/permission must be a string/, fn ->
        Rule.normalize_permission([:atom_perm])
      end
    end
  end
end
