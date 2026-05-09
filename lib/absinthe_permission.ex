defmodule AbsinthePermission do
  @moduledoc """
  Declarative, schema-first authorization for Absinthe GraphQL.

  Auth rules live next to the field they protect. They are compiled to
  introspectable data at schema-compile time, evaluated by middleware
  at request time, and emit telemetry on every decision.

  ## At a glance

      defmodule MyApp.Schema do
        use Absinthe.Schema
        use AbsinthePermission

        loaders do
          loader :todo, fn id, _ctx -> MyApp.Todos.get(id) end
        end

        query do
          field :todos, list_of(:todo) do
            authorize "view_todos"
            resolve &MyApp.Resolvers.list_todos/2
          end
        end

        mutation do
          field :update_todo, :todo do
            arg :id, :integer
            arg :state, :string

            authorize "edit_todos"
            authorize "close_todos", when: arg(:state) == "CLOSED"

            authorize_owner :todo,
              by: arg(:id),
              if_owner: "edit_own_todo",
              if_other: "edit_others_todo"

            resolve &MyApp.Resolvers.update_todo/2
          end
        end
      end

  ## Required Absinthe context

  At request time the middleware expects two keys in the Absinthe
  context:

    * `:current_user` — any term; available as `current_user` /
      `current_user(:field)` in conditions
    * `:permissions` — a list of permission strings the caller holds

  Set them in your Plug pipeline before Absinthe runs:

      conn
      |> Absinthe.Plug.put_options(
        context: %{
          current_user: user,
          permissions: MyApp.Auth.permissions_for(user)
        }
      )

  If the context is missing these keys, the middleware raises
  `AbsinthePermission.MissingContextError` by default. Override with
  the `:on_missing_context` option to `use AbsinthePermission`:

      use AbsinthePermission, on_missing_context: :deny  # or :allow

  ## Options for `use AbsinthePermission`

    * `:on_missing_context` — `:raise` (default), `:deny`, or `:allow`.
      Behaviour when `current_user`/`permissions` are absent from context.

  ## See also

    * `AbsinthePermission.DSL` — the macros (`authorize`, `load`,
      `authorize_owner`, `loader`, …)
    * `AbsinthePermission.Rule` — the rule data structure
    * `AbsinthePermission.Decision` — the result emitted on each check
    * `mix help absinthe_permission.audit` — list every rule in a schema
  """

  @doc """
  Sets up a schema module to use AbsinthePermission.

  Imports the DSL, registers the necessary module attributes, hooks
  into Absinthe's middleware pipeline, and installs a
  `@before_compile` callback that generates the rule lookup
  functions.

  ## Options

    * `:on_missing_context` — `:raise` | `:deny` | `:allow` (default `:raise`)
  """
  defmacro __using__(opts \\ []) do
    on_missing = Keyword.get(opts, :on_missing_context, :raise)
    validate_on_missing!(on_missing)

    quote do
      Module.register_attribute(__MODULE__, :__ap_rules_pending__, accumulate: true)
      Module.register_attribute(__MODULE__, :__ap_loads_pending__, accumulate: true)
      Module.register_attribute(__MODULE__, :__ap_loaders__, accumulate: true)
      Module.put_attribute(__MODULE__, :__ap_on_missing_context__, unquote(on_missing))

      import AbsinthePermission.DSL

      @before_compile AbsinthePermission.Compiler

      def __absinthe_permission_on_missing_context__, do: unquote(on_missing)

      # Override Absinthe's default `middleware/3` callback. Absinthe's
      # `use Absinthe.Schema` already defined a default + `defoverridable`,
      # so this `def` replaces it. Marked overridable again so end users can
      # add their own middleware on top of ours.
      def middleware(middleware, field, object) do
        AbsinthePermission.Middleware.attach(middleware, field, object, __MODULE__)
      end

      defoverridable middleware: 3
    end
  end

  defp validate_on_missing!(v) when v in [:raise, :deny, :allow], do: :ok

  defp validate_on_missing!(other) do
    raise ArgumentError,
          "invalid :on_missing_context value #{inspect(other)}. " <>
            "Valid: :raise, :deny, :allow"
  end

  # ---------------------------------------------------------------------------
  # Public introspection API
  # ---------------------------------------------------------------------------

  @doc """
  Return the list of rules attached to a field on a schema.

      AbsinthePermission.rules_for(MyApp.Schema, :mutation, :update_todo)

  Returns `[]` when the field has no rules. Useful in tests, audits,
  and for AI agents inspecting the schema.
  """
  @spec rules_for(module(), atom(), atom()) :: [AbsinthePermission.Rule.t()]
  def rules_for(schema, type_id, field_id)
      when is_atom(schema) and is_atom(type_id) and is_atom(field_id) do
    schema.__absinthe_permission_rules__(type_id, field_id)
  end

  @doc """
  Return all loads declared for a field on a schema.

      AbsinthePermission.loads_for(MyApp.Schema, :mutation, :update_todo)
  """
  @spec loads_for(module(), atom(), atom()) :: [AbsinthePermission.Load.t()]
  def loads_for(schema, type_id, field_id)
      when is_atom(schema) and is_atom(type_id) and is_atom(field_id) do
    schema.__absinthe_permission_loads__(type_id, field_id)
  end

  @doc """
  Look up a registered loader function.

      AbsinthePermission.loader(MyApp.Schema, :todo)
      #=> #Function<...>
  """
  @spec loader(module(), atom()) :: (any(), map() -> any()) | nil
  def loader(schema, name) when is_atom(schema) and is_atom(name) do
    schema.__absinthe_permission_loader__(name)
  end

  @doc """
  Return all rules in a schema, grouped by `{type_id, field_id}`.

  This is what `mix absinthe_permission.audit` consumes.
  """
  @spec all_rules(module()) :: %{
          {atom(), atom()} => [AbsinthePermission.Rule.t()]
        }
  def all_rules(schema) when is_atom(schema) do
    schema.__absinthe_permission_all_rules__()
  end
end
