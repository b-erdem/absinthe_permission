defmodule AbsinthePermission.Evaluator do
  @moduledoc """
  Pure (no side effects beyond the user-supplied loader functions)
  evaluation of compiled rules against a request.

  ## Inputs

    * `rules` — list of `t:AbsinthePermission.Rule.t/0`
    * `loads` — list of `t:AbsinthePermission.Load.t/0` to resolve before
      rules run
    * `schema` — schema module; used to look up loader functions
    * `args` — map of GraphQL arguments
    * `context` — Absinthe context map; expected to contain
      `:current_user` and `:permissions`

  ## Output

  A `t:AbsinthePermission.Decision.t/0` describing the verdict and why.

  ## Semantics

    * Rules whose condition does not fire are skipped silently.
    * Rules whose condition fires AND whose permission is held by the
      caller are recorded as matched.
    * Rules whose condition fires AND whose permission is NOT held
      cause an immediate `:deny` decision, with `error_message` /
      `permission` / `matched_rules` populated.
    * Multiple rules combine with AND semantics — ALL fired rules
      must pass.
  """

  alias AbsinthePermission.{Condition, Decision, Load, Rule}

  @type ctx :: %{optional(atom()) => any()}
  @type args :: %{optional(atom()) => any()} | keyword()

  # =========================================================================
  # Pre-op evaluation
  # =========================================================================

  @doc """
  Evaluate pre-op rules. Resolves `loads` first, then runs each rule
  in order. Returns `{:ok, decision}` on the happy path or
  `{:error, decision}` when a load fails.
  """
  @spec evaluate_pre(
          [Rule.t()],
          [Load.t()],
          module(),
          args(),
          ctx(),
          atom() | nil
        ) :: Decision.t()
  def evaluate_pre(rules, loads, schema, args, context, field_id \\ nil) do
    args_map = to_map(args)

    case resolve_loads(loads, schema, args_map, context) do
      {:ok, loaded} ->
        run_rules(rules, args_map, context, loaded, field_id)

      {:error, reason} ->
        %Decision{
          verdict: :deny,
          reason: :load_failed,
          field: field_id,
          error_message: "Failed to load data for authorization: #{reason}"
        }
    end
  end

  defp run_rules(rules, args, ctx, loaded, field_id) do
    user_perms = Map.get(ctx, :permissions, [])
    initial = %Decision{verdict: :allow, field: field_id, loaded: loaded}

    Enum.reduce_while(rules, initial, &eval_rule(&1, &2, args, ctx, loaded, user_perms, field_id))
  end

  defp eval_rule(rule, decision, args, ctx, loaded, user_perms, field_id) do
    cond do
      not condition_fires?(rule.condition, args, ctx, loaded) ->
        {:cont, decision}

      has_permission?(rule.permission, user_perms) ->
        {:cont, %{decision | matched_rules: [rule | decision.matched_rules]}}

      true ->
        {:halt, deny_decision(rule, decision, loaded, field_id)}
    end
  end

  defp deny_decision(rule, decision, loaded, field_id) do
    %Decision{
      verdict: deny_verdict(rule),
      reason: :missing_permission,
      permission: first_required(rule.permission),
      field: field_id,
      matched_rules: [rule | decision.matched_rules],
      loaded: loaded,
      error_message: rule.error_message || default_error_message(rule)
    }
  end

  defp deny_verdict(%Rule{on_deny: :error}), do: :deny
  defp deny_verdict(%Rule{on_deny: :null}), do: :nullify
  defp deny_verdict(%Rule{on_deny: :filter}), do: :filter

  defp default_error_message(%Rule{permission: {_, [perm | _]}}),
    do: "Unauthorized: missing permission `#{perm}`"

  defp default_error_message(%Rule{permission: nil}), do: "Unauthorized"

  defp first_required(nil), do: nil
  defp first_required({_, [perm | _]}), do: perm
  defp first_required({_, []}), do: nil

  # =========================================================================
  # Post-op evaluation (single-field redaction)
  # =========================================================================

  @doc """
  Evaluate post-op rules against an already-resolved value.

  For redaction (`on_deny: :null`), returns `{:nullify, decision}` if
  the rule denies. For `:error`, returns `{:deny, decision}`.
  Otherwise returns `{:allow, decision}` and the value passes through
  unchanged.
  """
  @spec evaluate_post([Rule.t()], any(), args(), ctx(), atom() | nil) ::
          {:allow | :nullify | :deny, Decision.t()}
  def evaluate_post(rules, _value, args, context, field_id \\ nil) do
    args_map = to_map(args)
    decision = run_rules(rules, args_map, context, %{}, field_id)

    case decision.verdict do
      :allow -> {:allow, decision}
      :nullify -> {:nullify, decision}
      :deny -> {:deny, decision}
      :filter -> {:deny, decision}
    end
  end

  # =========================================================================
  # Loads
  # =========================================================================

  @doc """
  Resolve all `loads` by calling their registered loader. Returns
  `{:ok, %{name => record_or_nil}}` or `{:error, reason}`.
  """
  @spec resolve_loads([Load.t()], module(), map(), ctx()) ::
          {:ok, %{atom() => any()}} | {:error, String.t()}
  def resolve_loads([], _schema, _args, _ctx), do: {:ok, %{}}

  def resolve_loads(loads, schema, args, ctx) do
    Enum.reduce_while(loads, {:ok, %{}}, fn load, {:ok, acc} ->
      case fetch_loader(schema, load.loader) do
        nil ->
          {:halt, {:error, "no loader registered for `#{load.loader}` in #{inspect(schema)}"}}

        loader ->
          key = eval_expr(load.by, args, ctx, acc)

          start = System.monotonic_time()

          try do
            record = loader.(key, ctx)

            :telemetry.execute(
              [:absinthe_permission, :load, :stop],
              %{duration: System.monotonic_time() - start},
              %{loader: load.loader, name: load.name, found: not is_nil(record)}
            )

            {:cont, {:ok, Map.put(acc, load.name, record)}}
          rescue
            err ->
              :telemetry.execute(
                [:absinthe_permission, :load, :exception],
                %{duration: System.monotonic_time() - start},
                %{loader: load.loader, name: load.name, error: err}
              )

              {:halt, {:error, "loader `#{load.loader}` raised: #{Exception.message(err)}"}}
          end
      end
    end)
  end

  defp fetch_loader(schema, name) do
    if function_exported?(schema, :__absinthe_permission_loader__, 1) do
      schema.__absinthe_permission_loader__(name)
    end
  end

  # =========================================================================
  # Condition evaluation
  # =========================================================================

  @doc "Evaluate a condition against the request state."
  @spec condition_fires?(Condition.t(), map(), ctx(), map()) :: boolean()
  def condition_fires?(:always, _args, _ctx, _loaded), do: true

  def condition_fires?({:cmp, [op, lhs, rhs]}, args, ctx, loaded) do
    apply_op(op, eval_expr(lhs, args, ctx, loaded), eval_expr(rhs, args, ctx, loaded))
  end

  def condition_fires?({:and, conds}, args, ctx, loaded) do
    Enum.all?(conds, &condition_fires?(&1, args, ctx, loaded))
  end

  def condition_fires?({:or, conds}, args, ctx, loaded) do
    Enum.any?(conds, &condition_fires?(&1, args, ctx, loaded))
  end

  def condition_fires?({:not, c}, args, ctx, loaded) do
    not condition_fires?(c, args, ctx, loaded)
  end

  def condition_fires?({:fun, fun}, args, ctx, loaded) when is_function(fun, 1) do
    !!fun.(%{args: args, context: ctx, loaded: loaded})
  end

  def condition_fires?({:fun, {m, f}}, args, ctx, loaded) do
    !!apply(m, f, [%{args: args, context: ctx, loaded: loaded}])
  end

  # Bare expression as condition (truthy check) — supports `when: arg(:enabled)`.
  def condition_fires?(expr, args, ctx, loaded) when is_tuple(expr) do
    !!eval_expr(expr, args, ctx, loaded)
  end

  # =========================================================================
  # Expression evaluation
  # =========================================================================

  @doc "Evaluate an expression to a runtime value."
  @spec eval_expr(any(), map(), ctx(), map()) :: any()
  def eval_expr({:literal, v}, _args, _ctx, _loaded), do: v

  def eval_expr({:arg, name}, args, _ctx, _loaded), do: Map.get(args, name)

  def eval_expr({:loaded, [name | path]}, _args, _ctx, loaded) do
    loaded
    |> Map.get(name)
    |> path_get(path)
  end

  def eval_expr({:current_user, path}, _args, ctx, _loaded) do
    ctx
    |> Map.get(:current_user)
    |> path_get(path)
  end

  def eval_expr({:context, path}, _args, ctx, _loaded), do: path_get(ctx, path)

  def eval_expr(other, _args, _ctx, _loaded), do: other

  defp path_get(value, []), do: value
  defp path_get(nil, _), do: nil

  defp path_get(map, [key | rest]) when is_map(map) do
    map |> Map.get(key) |> path_get(rest)
  end

  defp path_get(_other, _), do: nil

  # =========================================================================
  # Operators
  # =========================================================================

  defp apply_op(:eq, a, b), do: a == b
  defp apply_op(:neq, a, b), do: a != b
  defp apply_op(:gt, a, b) when not is_nil(a) and not is_nil(b), do: a > b
  defp apply_op(:gte, a, b) when not is_nil(a) and not is_nil(b), do: a >= b
  defp apply_op(:lt, a, b) when not is_nil(a) and not is_nil(b), do: a < b
  defp apply_op(:lte, a, b) when not is_nil(a) and not is_nil(b), do: a <= b
  defp apply_op(:in, a, b) when is_list(b), do: a in b
  defp apply_op(:not_in, a, b) when is_list(b), do: a not in b
  defp apply_op(_, _, _), do: false

  # =========================================================================
  # Permission checking
  # =========================================================================

  @doc "Check whether `user_perms` satisfies the rule's permission spec."
  @spec has_permission?(Rule.permission(), [String.t()]) :: boolean()
  def has_permission?(nil, _user_perms), do: true

  def has_permission?({:any, required}, user_perms) do
    Enum.any?(required, &(&1 in user_perms))
  end

  def has_permission?({:all, required}, user_perms) do
    Enum.all?(required, &(&1 in user_perms))
  end

  # =========================================================================
  # Helpers
  # =========================================================================

  defp to_map(args) when is_map(args), do: args
  defp to_map(args) when is_list(args), do: Enum.into(args, %{})
end
