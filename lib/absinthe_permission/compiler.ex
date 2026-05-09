defmodule AbsinthePermission.Compiler do
  @moduledoc """
  Compile-time machinery for `AbsinthePermission`.

  Two responsibilities:

  1. **Condition compilation** — `compile_condition/2` turns a piece of
     Elixir AST like `arg(:state) == "CLOSED"` into the data form
     `{:cmp, [:eq, {:arg, :state}, {:literal, "CLOSED"}]}` defined by
     `AbsinthePermission.Condition`.

  2. **Schema scope detection** — `current_scope/1` reads Absinthe's
     in-progress blueprint to determine the field and type the DSL
     macro is being expanded inside.

  This module is intended to be used by `AbsinthePermission.DSL`
  macros and by the `@before_compile` hook installed by
  `use AbsinthePermission`. It is not part of the public API.
  """

  alias AbsinthePermission.{CompileError, Condition}

  alias Absinthe.Blueprint.Schema.{
    FieldDefinition,
    InputObjectTypeDefinition,
    InterfaceTypeDefinition,
    ObjectTypeDefinition,
    UnionTypeDefinition
  }

  @type scope :: {type_id :: atom(), field_id :: atom() | nil}

  # ---------------------------------------------------------------------------
  # Scope detection
  # ---------------------------------------------------------------------------

  @doc """
  Returns `{type_identifier, field_identifier}` for the field/type the
  current macro expansion is inside. Either may be `nil` if the macro is
  used outside an expected scope.

  Reads `Module.get_attribute(env.module, :absinthe_blueprint)` — that
  attribute is populated by Absinthe's notation macros as the schema
  compiles.
  """
  @spec current_scope(Macro.Env.t()) :: scope()
  def current_scope(%Macro.Env{module: module}) do
    module
    |> Module.get_attribute(:absinthe_blueprint)
    |> List.wrap()
    |> Enum.reduce_while({nil, nil}, fn
      {_, %FieldDefinition{identifier: id}}, {nil, nil} -> {:cont, {nil, id}}
      {_, %ObjectTypeDefinition{identifier: id}}, {nil, f} -> {:halt, {id, f}}
      {_, %InterfaceTypeDefinition{identifier: id}}, {nil, f} -> {:halt, {id, f}}
      {_, %UnionTypeDefinition{identifier: id}}, {nil, f} -> {:halt, {id, f}}
      {_, %InputObjectTypeDefinition{identifier: id}}, {nil, f} -> {:halt, {id, f}}
      _, acc -> {:cont, acc}
    end)
  end

  @doc """
  Like `current_scope/1` but raises a helpful compile error if the macro
  isn't being used inside a schema field or type body.
  """
  @spec current_scope!(Macro.Env.t(), atom()) :: scope()
  def current_scope!(env, macro_name) do
    case current_scope(env) do
      {nil, nil} ->
        raise CompileError,
          message:
            "`#{macro_name}` must be called inside an Absinthe `field`, `object`, or `interface` block",
          location: [file: env.file, line: env.line]

      scope ->
        scope
    end
  end

  # ---------------------------------------------------------------------------
  # Condition compilation
  # ---------------------------------------------------------------------------

  @doc """
  Compile a condition AST into the runtime data form.

  Returns AST that, when evaluated at the call site, produces a
  `t:AbsinthePermission.Condition.t/0`. Raises `CompileError` on
  malformed input, with file/line from the supplied env.

  ## Examples (the AST input shape, not what users write)

      iex> ast = quote do: arg(:state) == "CLOSED"
      iex> {:cmp, [:eq, {:arg, :state}, {:literal, "CLOSED"}]} =
      ...>   AbsinthePermission.Compiler.compile_condition(ast, __ENV__)
      ...>   |> Code.eval_quoted([], __ENV__)
      ...>   |> elem(0)
  """
  @spec compile_condition(Macro.t(), Macro.Env.t()) :: Macro.t()
  def compile_condition(ast, env)

  # `:always` shortcut
  def compile_condition(:always, _env), do: Macro.escape(:always)
  def compile_condition({:always, _, _}, _env), do: Macro.escape(:always)

  # Anonymous function escape hatch — pass through.
  def compile_condition({:fn, _, _} = fn_ast, _env) do
    quote do: {:fun, unquote(fn_ast)}
  end

  # Function capture &Mod.fun/1 escape hatch.
  def compile_condition({:&, _, _} = capture, _env) do
    quote do: {:fun, unquote(capture)}
  end

  # Helpers: arg/loaded/current_user/context
  def compile_condition({:arg, _, [name]}, _env) when is_atom(name) do
    quote do: {:arg, unquote(name)}
  end

  def compile_condition({:current_user, _, args}, _env) when args in [nil, []] do
    quote do: {:current_user, []}
  end

  def compile_condition({:current_user, _, [field]}, _env) when is_atom(field) do
    quote do: {:current_user, [unquote(field)]}
  end

  def compile_condition({:context, _, [field]}, _env) when is_atom(field) do
    quote do: {:context, [unquote(field)]}
  end

  def compile_condition({:loaded, _, [name]}, _env) when is_atom(name) do
    quote do: {:loaded, [unquote(name)]}
  end

  # Field access on helpers — `loaded(:todo).owner_id`,
  # `current_user.id`, etc.
  def compile_condition({{:., _, [inner, field]}, _, []}, env) when is_atom(field) do
    case classify_path(inner, env) do
      {:loaded, list} -> quote do: {:loaded, unquote(list ++ [field])}
      {:current_user, list} -> quote do: {:current_user, unquote(list ++ [field])}
      {:context, list} -> quote do: {:context, unquote(list ++ [field])}
      :unknown -> raise_unsupported(inner, env)
    end
  end

  # Comparisons: ==, !=, >, >=, <, <=, in
  def compile_condition({:==, _, [lhs, rhs]}, env), do: build_cmp(:eq, lhs, rhs, env)
  def compile_condition({:!=, _, [lhs, rhs]}, env), do: build_cmp(:neq, lhs, rhs, env)
  def compile_condition({:>, _, [lhs, rhs]}, env), do: build_cmp(:gt, lhs, rhs, env)
  def compile_condition({:>=, _, [lhs, rhs]}, env), do: build_cmp(:gte, lhs, rhs, env)
  def compile_condition({:<, _, [lhs, rhs]}, env), do: build_cmp(:lt, lhs, rhs, env)
  def compile_condition({:<=, _, [lhs, rhs]}, env), do: build_cmp(:lte, lhs, rhs, env)
  def compile_condition({:in, _, [lhs, rhs]}, env), do: build_cmp(:in, lhs, rhs, env)

  defp build_cmp(op, lhs, rhs, env) do
    lhs_q = compile_condition(lhs, env)
    rhs_q = compile_condition(rhs, env)
    quote do: {:cmp, [unquote(op), unquote(lhs_q), unquote(rhs_q)]}
  end

  # Logical operators
  def compile_condition({:and, _, [lhs, rhs]}, env) do
    quote do: {:and, [unquote(compile_condition(lhs, env)), unquote(compile_condition(rhs, env))]}
  end

  def compile_condition({:or, _, [lhs, rhs]}, env) do
    quote do: {:or, [unquote(compile_condition(lhs, env)), unquote(compile_condition(rhs, env))]}
  end

  def compile_condition({:not, _, [inner]}, env) do
    quote do: {:not, unquote(compile_condition(inner, env))}
  end

  # Literals: numbers, strings, atoms (incl. true/false/nil), lists.
  def compile_condition(lit, _env)
      when is_number(lit) or is_binary(lit) or is_boolean(lit) or is_nil(lit) do
    quote do: {:literal, unquote(lit)}
  end

  def compile_condition(lit, _env) when is_atom(lit) do
    quote do: {:literal, unquote(lit)}
  end

  def compile_condition(list, env) when is_list(list) do
    items = Enum.map(list, &compile_condition(&1, env))
    quote do: {:literal, [unquote_splicing(items)]}
  end

  # Unknown identifier in a condition — fail loud and helpful.
  def compile_condition({name, _, ctx} = ast, env) when is_atom(name) and is_atom(ctx) do
    raise CompileError,
      message:
        "unknown identifier `#{name}` in condition. " <>
          "Use `arg(:name)`, `loaded(:name)`, `current_user`, " <>
          "`current_user(:field)`, or `context(:field)`. " <>
          "Got: #{Macro.to_string(ast)}",
      location: [file: env.file, line: env.line]
  end

  def compile_condition(ast, env), do: raise_unsupported(ast, env)

  defp raise_unsupported(ast, env) do
    raise CompileError,
      message: "unsupported expression in condition: #{Macro.to_string(ast)}",
      location: [file: env.file, line: env.line]
  end

  # Walks a chained `.field.field` access at the AST level to figure out
  # what kind of helper it bottoms out in.
  defp classify_path({:loaded, _, [name]}, _env) when is_atom(name), do: {:loaded, [name]}
  defp classify_path({:current_user, _, args}, _env) when args in [nil, []], do: {:current_user, []}
  defp classify_path({:context, _, args}, _env) when args in [nil, []], do: {:context, []}

  defp classify_path({{:., _, [inner, field]}, _, []}, env) when is_atom(field) do
    case classify_path(inner, env) do
      {:loaded, list} -> {:loaded, list ++ [field]}
      {:current_user, list} -> {:current_user, list ++ [field]}
      {:context, list} -> {:context, list ++ [field]}
      :unknown -> :unknown
    end
  end

  defp classify_path(_, _), do: :unknown

  # ---------------------------------------------------------------------------
  # before_compile hook — generates lookup functions on the schema module
  # ---------------------------------------------------------------------------

  @doc false
  defmacro __before_compile__(env) do
    rules_by_scope =
      env.module
      |> Module.get_attribute(:__ap_rules_pending__)
      |> List.wrap()
      |> group_asts_by_scope()

    loads_by_scope =
      env.module
      |> Module.get_attribute(:__ap_loads_pending__)
      |> List.wrap()
      |> group_asts_by_scope()

    rule_clauses = clauses_for(:__absinthe_permission_rules__, rules_by_scope)
    load_clauses = clauses_for(:__absinthe_permission_loads__, loads_by_scope)
    known_scopes = rules_by_scope |> Map.keys() |> Enum.uniq()

    quote do
      unquote_splicing(rule_clauses)
      def __absinthe_permission_rules__(_, _), do: []

      unquote_splicing(load_clauses)
      def __absinthe_permission_loads__(_, _), do: []

      def __absinthe_permission_loader__(_), do: nil

      def __absinthe_permission_all_rules__ do
        Enum.into(unquote(Macro.escape(known_scopes)), %{}, fn {t, f} = scope ->
          {scope, __absinthe_permission_rules__(t, f)}
        end)
      end
    end
  end

  # Pending lists hold `{scope, ast}`. We splice the ASTs into the bodies of
  # generated clauses so the rule/load structs are built at request time,
  # not at macro-expansion time — which keeps `Macro.escape` from ever seeing
  # function values from escape hatches like `&Mod.fun/1`.
  defp clauses_for(fun_name, by_scope) do
    for {{type_id, field_id}, asts} <- by_scope do
      quote do
        def unquote(fun_name)(unquote(type_id), unquote(field_id)) do
          [unquote_splicing(asts)]
        end
      end
    end
  end

  defp group_asts_by_scope(pending) do
    pending
    |> Enum.reduce(%{}, fn {scope, ast}, acc ->
      Map.update(acc, scope, [ast], &[ast | &1])
    end)
    |> Enum.into(%{}, fn {k, v} -> {k, Enum.reverse(v)} end)
  end

  # ---------------------------------------------------------------------------
  # Compile-time validation helpers (called from DSL macros)
  # ---------------------------------------------------------------------------

  @doc false
  @spec validate_op!(atom(), Macro.Env.t()) :: :ok
  def validate_op!(op, env) do
    if Condition.valid_op?(op) do
      :ok
    else
      raise CompileError,
        message: "unknown operator #{inspect(op)}. Valid: #{inspect(Condition.valid_ops())}",
        location: [file: env.file, line: env.line]
    end
  end
end
