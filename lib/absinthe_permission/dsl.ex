defmodule AbsinthePermission.DSL do
  @moduledoc """
  Macros that compose the AbsinthePermission DSL.

  These are imported automatically by `use AbsinthePermission`.
  Don't import this module directly.

  ## Available macros

    * `authorize/1`, `authorize/2` — the primary rule-attaching macro
    * `authorize_owner/2` — sugar for the "owner-vs-others" pattern
    * `load/1`, `load/2` — declare data to fetch before rules evaluate
    * `loaders/1` — block delimiter for loader registration
    * `loader/2` — register a single loader

  ## Condition helpers (used inside `when:` / `unless:`)

  These are recognised by `AbsinthePermission.Compiler` at macro time
  and never need to be `import`ed at runtime:

    * `arg(:name)` — a GraphQL argument
    * `loaded(:name).field.path` — a field on a loaded record
    * `current_user.field.path` or `current_user(:field)` — context's
      `current_user`
    * `context.field` — arbitrary context path
  """

  alias AbsinthePermission.{CompileError, Compiler}

  # ===========================================================================
  # authorize/1, authorize/2
  # ===========================================================================

  @doc """
  Attach an authorization rule to the enclosing field.

  When the rule fires (its `when:` condition holds, or always if none),
  the caller must hold `permission` or the operation is denied.

  ## Permission shapes

      authorize "edit_todos"                   # single permission
      authorize ["admin", "support"]            # any-of
      authorize all: ["admin", "verified_2fa"]  # all-of

  ## Conditional firing

      authorize "close_tickets",  when: arg(:state) == "CLOSED"
      authorize "edit_others",    unless: loaded(:todo).owner_id == current_user.id
      authorize "high_priority",  when: arg(:priority) > 5

  ## Behaviour on deny

      authorize "view_emails", on_deny: :null   # redact the field, return null
      authorize "view_emails", on_deny: :error  # default — return GraphQL error

  ## Custom error message

      authorize "edit_todos", error_message: "Only admins may edit todos."
  """
  defmacro authorize(perm) do
    do_authorize(perm, [], __CALLER__)
  end

  @doc "See `authorize/1`."
  defmacro authorize(perm, opts) when is_list(opts) do
    do_authorize(perm, opts, __CALLER__)
  end

  defp do_authorize(perm_ast, opts, env) do
    scope = Compiler.current_scope!(env, :authorize)
    cond_ast = condition_from_opts(opts, env)
    on_deny = Keyword.get(opts, :on_deny, :error)
    error_msg = Keyword.get(opts, :error_message)

    validate_on_deny!(on_deny, env)
    phase = phase_for_on_deny(on_deny)

    rule_ast =
      quote do
        %AbsinthePermission.Rule{
          phase: unquote(phase),
          permission: AbsinthePermission.Rule.normalize_permission(unquote(perm_ast)),
          condition: unquote(cond_ast),
          on_deny: unquote(on_deny),
          error_message: unquote(error_msg),
          location: %{file: unquote(env.file), line: unquote(env.line)}
        }
      end

    payload = Macro.escape({scope, rule_ast})

    quote do
      Module.put_attribute(__MODULE__, :__ap_rules_pending__, unquote(payload))
    end
  end

  defp phase_for_on_deny(:error), do: :pre
  defp phase_for_on_deny(:null), do: :post
  defp phase_for_on_deny(:filter), do: :post

  defp condition_from_opts(opts, env) do
    case {Keyword.fetch(opts, :when), Keyword.fetch(opts, :unless)} do
      {:error, :error} ->
        Macro.escape(:always)

      {{:ok, ast}, :error} ->
        Compiler.compile_condition(ast, env)

      {:error, {:ok, ast}} ->
        compiled = Compiler.compile_condition(ast, env)
        quote do: {:not, unquote(compiled)}

      {{:ok, _}, {:ok, _}} ->
        raise CompileError,
          message: "cannot use both `when:` and `unless:` on the same rule",
          location: [file: env.file, line: env.line]
    end
  end

  defp validate_on_deny!(value, _env) when value in [:error, :null, :filter], do: :ok

  defp validate_on_deny!(value, env) do
    raise CompileError,
      message:
        "invalid `on_deny: #{inspect(value)}`. " <>
          "Valid values: :error (return GraphQL error), :null (redact field), " <>
          ":filter (drop list items)",
      location: [file: env.file, line: env.line]
  end

  # ===========================================================================
  # load/1, load/2
  # ===========================================================================

  @doc """
  Declare a piece of data to fetch before rules on this field are
  evaluated. Subsequent rules can reference it as `loaded(:name)`.

      load :todo, by: arg(:id)
      load :user, by: arg(:user_id), using: :user_loader
      load :todo                       # short for `by: arg(:id), using: :todo`

  The loader function is registered via `loader/2` inside a `loaders`
  block and called as `loader.(key, ctx)`, returning either the record
  or `nil`.
  """
  defmacro load(name, opts \\ []) when is_atom(name) and is_list(opts) do
    scope = Compiler.current_scope!(__CALLER__, :load)

    by_ast =
      case Keyword.fetch(opts, :by) do
        {:ok, ast} -> ast
        :error -> {:arg, [], [:id]}
      end

    by_compiled = Compiler.compile_condition(by_ast, __CALLER__)
    loader_name = Keyword.get(opts, :using, name)
    remote_key = Keyword.get(opts, :remote_key)

    load_ast =
      quote do
        %AbsinthePermission.Load{
          name: unquote(name),
          loader: unquote(loader_name),
          by: unquote(by_compiled),
          remote_key: unquote(remote_key)
        }
      end

    payload = Macro.escape({scope, load_ast})

    quote do
      Module.put_attribute(__MODULE__, :__ap_loads_pending__, unquote(payload))
    end
  end

  # ===========================================================================
  # authorize_owner/2 — sugar for owner-vs-others
  # ===========================================================================

  @doc """
  Sugar for the "owner-or-admin" pattern:

      authorize_owner :todo, by: arg(:id),
        owner_field: :owner_id,
        if_owner:    "edit_own_todo",
        if_other:    "edit_others_todo"

  Equivalent to:

      load :todo, by: arg(:id)
      authorize "edit_own_todo",
        when: loaded(:todo).owner_id == current_user.id
      authorize "edit_others_todo",
        when: loaded(:todo).owner_id != current_user.id

  ## Options

    * `:by` — what to look up (default: `arg(:id)`)
    * `:owner_field` — record field to compare against `current_user.id`
      (default: `:owner_id`)
    * `:if_owner` — permission required when caller IS the owner (required)
    * `:if_other` — permission required when caller is NOT the owner (required)
    * `:user_field` — `current_user` field to compare (default: `:id`)
  """
  defmacro authorize_owner(load_name, opts)
           when is_atom(load_name) and is_list(opts) do
    env = __CALLER__
    scope = Compiler.current_scope!(env, :authorize_owner)
    owner_field = Keyword.get(opts, :owner_field, :owner_id)
    user_field = Keyword.get(opts, :user_field, :id)

    if_owner =
      Keyword.get(opts, :if_owner) ||
        raise CompileError,
          message: "authorize_owner requires `:if_owner` option",
          location: [file: env.file, line: env.line]

    if_other =
      Keyword.get(opts, :if_other) ||
        raise CompileError,
          message: "authorize_owner requires `:if_other` option",
          location: [file: env.file, line: env.line]

    by_ast =
      case Keyword.fetch(opts, :by) do
        {:ok, ast} -> ast
        :error -> {:arg, [], [:id]}
      end

    by_compiled = Compiler.compile_condition(by_ast, env)

    own_cond =
      {:cmp, [:eq, {:loaded, [load_name, owner_field]}, {:current_user, [user_field]}]}

    other_cond = {:not, own_cond}

    load_ast =
      quote do
        %AbsinthePermission.Load{
          name: unquote(load_name),
          loader: unquote(load_name),
          by: unquote(by_compiled),
          remote_key: nil
        }
      end

    rule_owner =
      build_rule_ast(:pre, if_owner, Macro.escape(own_cond), :error, nil, env)

    rule_other =
      build_rule_ast(:pre, if_other, Macro.escape(other_cond), :error, nil, env)

    load_payload = Macro.escape({scope, load_ast})
    owner_payload = Macro.escape({scope, rule_owner})
    other_payload = Macro.escape({scope, rule_other})

    quote do
      Module.put_attribute(__MODULE__, :__ap_loads_pending__, unquote(load_payload))
      Module.put_attribute(__MODULE__, :__ap_rules_pending__, unquote(owner_payload))
      Module.put_attribute(__MODULE__, :__ap_rules_pending__, unquote(other_payload))
    end
  end

  defp build_rule_ast(phase, perm, cond_ast, on_deny, error_msg, env) do
    quote do
      %AbsinthePermission.Rule{
        phase: unquote(phase),
        permission: AbsinthePermission.Rule.normalize_permission(unquote(perm)),
        condition: unquote(cond_ast),
        on_deny: unquote(on_deny),
        error_message: unquote(error_msg),
        location: %{file: unquote(env.file), line: unquote(env.line)}
      }
    end
  end

  # ===========================================================================
  # loaders block / loader registration
  # ===========================================================================

  @doc """
  Block delimiter for loader registrations. Use at the top level of
  your schema module:

      loaders do
        loader :todo, fn id, _ctx -> MyApp.Todos.get(id) end
        loader :user, &MyApp.Users.fetch/2
      end

  The block is otherwise opaque — `loader/2` does the real work.
  """
  defmacro loaders(do: block), do: block

  @doc """
  Register a single loader function. Must be called inside a `loaders`
  block (or directly at module top level).

  The function receives `(key, context)` and should return either the
  loaded record (any term) or `nil` if not found.

      loader :todo, fn id, _ctx -> MyApp.Todos.get(id) end
      loader :user, &MyApp.Users.fetch/2
  """
  defmacro loader(name, fun) when is_atom(name) do
    quote do
      def __absinthe_permission_loader__(unquote(name)) do
        unquote(fun)
      end
    end
  end
end
