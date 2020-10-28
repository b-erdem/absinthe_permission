defmodule PolicyCheckTest do
  use ExUnit.Case

  alias AbsinthePermission.PolicyChecker

  test "has permission" do
    assert true == PolicyChecker.has_permission?("", ["perm1", "perm2", "perm3"])
    assert true == PolicyChecker.has_permission?(nil, ["perm1", "perm2", "perm3"])
    assert false == PolicyChecker.has_permission?("perm1", ["perm2", "perm3"])
    assert false == PolicyChecker.has_permission?(:perm1, ["perm2", "perm3"])
    assert true == PolicyChecker.has_permission?("perm1", ["perm1", "perm2"])
    assert true == PolicyChecker.has_permission?(:perm1, ["perm1", "perm2"])
  end

  test "reject" do
    data = [
      %{id: 1, name: "test1"},
      %{id: 2, name: "test2"},
      %{id: 3, name: "test4"}
    ]

    policies = []
  end

  test "should we allow" do
    policies = []
  end
end
