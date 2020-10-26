defmodule Absinthe.Permission.PolicyCheck do
  @spec has_permission?(atom | binary, any) :: boolean
  def has_permission?(nil, _), do: true

  def has_permission?(perm, user_perms) when is_atom(perm) do
    Atom.to_string(perm) in user_perms
  end

  def has_permission?(perm, user_perms) when is_binary(perm) do
    perm in user_perms
  end

  def should_we_allow?(args, conds, user_context) do
    perms = allowed?(args, conds, user_context, [])

    case perms do
      [] ->
        true

      perms ->
        perms
        |> higher_permission
        |> has_permission?(user_context.permissions)
    end
  end

  def reject(val, filters, args, user_context) do
    reject(val, fn x -> checker(x, filters, Map.to_list(args), user_context) end)
  end

  def reject(val, fun) when is_list(val) do
    Enum.reject(val, fun)
  end

  def reject(val, fun) do
    Enum.reject([val], fun) |> List.first()
  end

  defp higher_permission(permissions) do
    # TODO: if all conditions have same priority,
    # then instead of choosing first permission
    # we can give all permissions.
    # If user has one of them, then grant the access.
    # Should be discussed.
    if all_same_priority?(permissions) do
      permissions |> Enum.at(0) |> elem(0)
    else
      permissions
      |> Enum.max_by(fn {_k, v} -> v end)
      |> elem(0)
    end
  end

  defp all_same_priority?(permissions) do
    permissions
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.group_by(fn v -> v end)
    |> Map.keys()
    |> length == 1
  end

  defp allowed?([], _, _user_context, perms) do
    perms
  end

  defp allowed?([{_input_key, _input_val} | _tail] = args, conditions, user_context, perms) do
    check_conds(conditions, args, user_context, perms)
  end

  defp check_conds([], _args, _user_context, perms) do
    perms
  end

  defp check_conds(
         [condition | conds],
         [{_input_key, _input_val} | _tail] = args,
         user_context,
         perms
       ) do
    case check_cond(condition, args, user_context) do
      {true, counter} ->
        perm = Keyword.get(condition, :required_permission) |> String.to_atom()

        new_perm =
          case Keyword.get(perms, perm) do
            nil ->
              {perm, counter}

            curr_val ->
              case curr_val == counter do
                true -> {perm, curr_val}
                false -> {perm, counter}
              end
          end

        check_conds(conds, args, user_context, [new_perm | perms])

      _ ->
        check_conds(conds, args, user_context, perms)
    end
  end

  defp check_cond(condition, args, user_context) do
    check_clause(condition, condition, args, user_context, {true, 0})
  end

  defp check_clause(_, _, _, _, {counter, false}), do: {false, counter}

  defp check_clause([], _condition, _args, _user_context, state), do: state

  defp check_clause([{:remote_context, context} | clauses], condition, args, user_context, state) do
    {model, context_} = Keyword.pop(context, :model)
    {remote_key, context__} = Keyword.pop(context_, :remote_key)
    {input_key, context___} = Keyword.pop(context__, :input_key)
    input_val = Keyword.get(args, input_key)
    {preload, context____} = Keyword.pop(context___, :preload)

    {:ok, result} =
      FetchModel.run(
        model: model,
        preload: preload,
        clause: {remote_key, input_val},
        tenant: user_context.tenant
      )

    res = checker(result, context____, args, user_context)

    check_clause(clauses, condition, args, user_context, res |> satisfied?(state))
  end

  defp check_clause(
         [{:user_context, context} | clauses],
         condition,
         args,
         %{current_user: current_user} = user_context,
         state
       ) do
    {remote_key, context_} = Keyword.pop(context, :remote_key)
    {input_key, context__} = Keyword.pop(context_, :input_key)
    input_val = Keyword.get(args, input_key)
    op = Keyword.get(context__, :op)

    case op do
      :eq ->
        check_clause(
          clauses,
          condition,
          args,
          user_context,
          satisfied?(Map.get(current_user, remote_key) == input_val, state)
        )

      :neq ->
        check_clause(
          clauses,
          condition,
          args,
          user_context,
          satisfied?(Map.get(current_user, remote_key) != input_val, state)
        )

      _ ->
        check_clause(clauses, condition, args, user_context, satisfied?(false, state))
    end
  end

  defp check_clause(
         [{:required_permission, _cond_val} | clauses],
         condition,
         args,
         user_context,
         state
       ) do
    check_clause(clauses, condition, args, user_context, state)
  end

  defp check_clause(
         [{clause_key, {clause_val, op}} | clauses],
         condition,
         args,
         user_context,
         state
       ) do
    check_clause(
      clauses,
      condition,
      args,
      user_context,
      Keyword.get(args, clause_key) |> op_func(op).(clause_val) |> satisfied?(state)
    )
  end

  defp check_clause([{clause_key, clause_val} | clauses], condition, args, user_context, state) do
    check_clause(
      [{clause_key, {clause_val, :eq}} | clauses],
      condition,
      args,
      user_context,
      state
    )
  end

  defp checker(result, checks, args, user_context) do
    checks
    |> Enum.map(fn
      {k, {v, op}} -> {k, v, op_func(op)}
      {k, v} -> {k, v, op_func(:eq)}
    end)
    |> Enum.map(fn {k, v, op} ->
      ks = k |> Atom.to_string() |> String.split("__") |> Enum.map(&String.to_atom/1)
      {ks, v, op}
    end)
    |> Enum.map(fn
      {ks, :current_user_id, op} -> {ks, user_context.current_user.id, op}
      {ks, v, op} when is_atom(v) -> {ks, Keyword.get(args, v) || v, op}
      {ks, v, op} -> {ks, v, op}
    end)
    |> Enum.all?(fn {ks, v, op} -> fetch(result, ks) |> op.(v) end)
  end

  defp satisfied?(true, {_, counter}), do: {true, counter + 1}
  defp satisfied?(false, {_, counter}), do: {false, counter}

  defp op_func(:eq), do: &==/2
  defp op_func(:neq), do: &!=/2

  defp fetch(nil, _), do: nil
  defp fetch(container, [h]), do: Map.get(container, h)

  defp fetch(container, [h | t]) do
    Map.get(container, h) |> fetch(t)
  end
end
