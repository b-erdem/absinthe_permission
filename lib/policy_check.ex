defmodule Absinthe.Permission.PolicyChecker do
  @moduledoc """

  """

  alias Absinthe.Permission.DefaultFetcher

  @type args :: Keyword.t()
  @type permission :: atom | binary
  @type condition :: Keyword.t()
  @type clause :: Keyword.t()
  @type remote_context :: Keyword.t()

  @spec has_permission?(atom | binary, list(atom) | list(binary)) :: boolean
  def has_permission?(required_perm, user_perms)

  def has_permission?(nil, _), do: true
  def has_permission?("", _), do: true

  def has_permission?(perm, user_perms) when is_atom(perm) do
    Atom.to_string(perm) in user_perms
  end

  def has_permission?(perm, user_perms) when is_binary(perm) do
    perm in user_perms
  end

  @spec should_we_allow?(args(), list(condition()), map()) :: boolean()
  def should_we_allow?(args, conds, context) do
    perms = allowed?(args, conds, context, [])

    case perms do
      [] ->
        true

      perms ->
        perms
        |> higher_permission
        |> has_permission?(context.permissions)
    end
  end

  @spec reject(list | map, list(atom | binary), args(), map()) :: map()
  def reject(val, filters, args, context) do
    reject(val, fn x -> checker(x, filters, args, context) end)
  end

  @spec reject(list(), function()) :: list()
  def reject(val, fun) when is_list(val) do
    Enum.reject(val, fun)
  end

  @spec reject(map(), function()) :: map()
  def reject(val, fun) do
    Enum.reject([val], fun) |> List.first()
  end

  @spec higher_permission(Keyword.t(permission(), integer())) :: permission()
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

  @spec all_same_priority?(Keyword.t(permission(), integer())) :: boolean()
  defp all_same_priority?(permissions) do
    permissions
    |> Enum.map(fn {_k, v} -> v end)
    |> Enum.group_by(fn v -> v end)
    |> Map.keys()
    |> length == 1
  end

  @spec allowed?(args(), list(), map(), list(permission())) :: list()
  defp allowed?(args, conds, context, perms)

  defp allowed?(args, conditions, context, perms) do
    check_conds(conditions, args, context, perms)
  end

  @spec check_conds(list(condition), Keyword.t(), map(), list()) :: list()
  defp check_conds(conditions, args, context, perms)

  defp check_conds([], _args, _context, perms) do
    perms
  end

  defp check_conds(
         [condition | conds],
         args,
         context,
         perms
       ) do
    case check_cond(condition, args, context) do
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

        check_conds(conds, args, context, [new_perm | perms])

      _ ->
        check_conds(conds, args, context, perms)
    end
  end

  defp check_cond(condition, args, context) do
    check_clause(condition, condition, args, context, {true, 0})
  end

  @spec check_clause(list(clause), condition(), args(), map(), {boolean(), integer()}) ::
          {boolean(), integer()}
  defp check_clause(clauses, condition, args, context, state)
  defp check_clause(_, _, _, _, {false, counter}), do: {false, counter}

  defp check_clause([], _condition, _args, _context, state), do: state

  defp check_clause(
         [{:remote_context, remote_context} | clauses],
         condition,
         args,
         context,
         state
       ) do
    # fetcher =
    #   Application.get_env(
    #     :absinthe_permission,
    #     :fetcher,
    #     &DefaultFetcher.fetch/4
    #   )

    {config, remote_context} = Keyword.pop(remote_context, :config)
    {fields, remote_context} = Keyword.pop(remote_context, :fields)
    {extras, _remote_context} = Keyword.pop(remote_context, :extras)

    {fetcher_key, config} = Keyword.pop(config, :fetcher_key)
    {remote_key, config} = Keyword.pop(config, :remote_key)
    {input_key, _config} = Keyword.pop(config, :input_key)
    input_val = Keyword.get(args, input_key)

    {_fetcher_key, fetcher} =
      Application.get_env(:absinthe_permission, :fetchers, [])
      |> Enum.find(fn {fetcher, _module_or_fun} -> fetcher == fetcher_key end)

    {:ok, result} =
      case fetcher do
        fun when is_function(fetcher) ->
          fun.([key: remote_key, value: input_val, extras: extras], condition, args, context)

        {module, fun} ->
          :erlang.apply(module, fun, [
            %{key: remote_key, value: input_val, extras: extras},
            condition,
            args,
            context
          ])
      end

    res = checker(result, fields, args, context)

    check_clause(clauses, condition, args, context, increment(res, state))
  end

  defp check_clause(
         [{:user_context, user_context} | clauses],
         condition,
         args,
         %{current_user: current_user} = context,
         state
       ) do
    {remote_key, user_context} = Keyword.pop(user_context, :remote_key)
    {input_key, user_context} = Keyword.pop(user_context, :input_key)
    input_val = Keyword.get(args, input_key)
    op = Keyword.get(user_context, :op)

    new_state =
      Map.get(current_user, remote_key)
      |> op_func(op).(input_val)
      |> increment(state)

    check_clause(clauses, condition, args, context, new_state)
  end

  defp check_clause(
         [{:required_permission, _cond_val} | clauses],
         condition,
         args,
         context,
         state
       ) do
    check_clause(clauses, condition, args, context, state)
  end

  defp check_clause(
         [{clause_key, {clause_val, op}} | clauses],
         condition,
         args,
         context,
         state
       ) do
    check_clause(
      clauses,
      condition,
      args,
      context,
      Keyword.get(args, clause_key) |> op_func(op).(clause_val) |> increment(state)
    )
  end

  defp check_clause([{clause_key, clause_val} | clauses], condition, args, context, state) do
    check_clause(
      [{clause_key, {clause_val, :eq}} | clauses],
      condition,
      args,
      context,
      state
    )
  end

  defp checker(result, checks, args, context) do
    checks
    |> transform_checks()
    |> fill_checks(args, context)
    |> Enum.all?(fn {ks, v, op} -> fetch(result, ks) |> op.(v) end)
  end

  defp transform_checks(checks) do
    checks
    |> Enum.map(fn
      {k, {v, op}} -> {k, v, op_func(op)}
      {k, v} -> {k, v, op_func(:eq)}
    end)
    |> Enum.map(fn {k, v, op} ->
      ks = k |> Atom.to_string() |> String.split("__") |> Enum.map(&String.to_atom/1)
      {ks, v, op}
    end)
  end

  defp fill_checks(checks, args, context) do
    checks
    |> Enum.map(fn
      {ks, :current_user_id, op} -> {ks, context.current_user.id, op}
      {ks, v, op} when is_atom(v) -> {ks, Keyword.get(args, v) || v, op}
      {ks, v, op} -> {ks, v, op}
    end)
  end

  defp increment(true, {_, counter}), do: {true, counter + 1}
  defp increment(false, {_, counter}), do: {false, counter}

  @spec op_func(atom()) :: function()
  defp op_func(op_key)
  defp op_func(:eq), do: &==/2
  defp op_func(:neq), do: &!=/2

  @spec fetch(map(), list(atom | binary)) :: any()
  defp fetch(container, keys)
  defp fetch(nil, _), do: nil
  defp fetch(container, [h]), do: Map.get(container, h)

  defp fetch(container, [h | t]) do
    Map.get(container, h) |> fetch(t)
  end
end
