# AGENTS.md — `absinthe_permission` cookbook for AI coding agents

This file is the canonical "what does this library do, and what's the
shortest path to do X" reference. It exists for AI coding agents (and
fast-skim humans). Everything below is verified against the test
suite and produces a working schema if pasted in.

## Mental model in five lines

1. Auth rules live next to the field they protect, via macros.
2. `use AbsinthePermission` in the schema turns those macros on and
   wires up middleware.
3. Each `authorize "perm"` becomes a `%Rule{}` stored on the schema at
   compile time.
4. The middleware evaluates the rules at request time and emits
   telemetry on every decision.
5. Conditions like `arg(:state) == "CLOSED"` are compiled to data
   (`{:cmp, [:eq, {:arg, :state}, {:literal, "CLOSED"}]}`), not
   closures — they are introspectable via
   `AbsinthePermission.rules_for/3`.

## Setup pattern

```elixir
defmodule MyApp.Schema do
  use Absinthe.Schema
  use AbsinthePermission                   # default: raise on missing context

  loaders do
    loader :todo, fn id, _ctx -> MyApp.Todos.get(id) end
    loader :user, &MyApp.Users.fetch/2
  end

  query do
    field :todos, list_of(:todo) do
      authorize "view_todos"
      resolve &MyApp.Resolvers.list_todos/2
    end
  end
end
```

The Plug pipeline must populate `current_user` and `permissions`:

```elixir
conn
|> Absinthe.Plug.put_options(context: %{
  current_user: current_user,
  permissions: MyApp.Auth.permissions_for(current_user)
})
```

## Rule shapes

| Want | Write |
| --- | --- |
| Always required | `authorize "perm"` |
| Any of N | `authorize ["a", "b"]` |
| All of N | `authorize all: ["a", "b"]` |
| Conditional on arg | `authorize "p", when: arg(:state) == "CLOSED"` |
| Numeric comparison | `authorize "p", when: arg(:n) > 5` |
| Inverse condition | `authorize "p", unless: arg(:flag)` |
| List membership | `authorize "p", when: arg(:role) in ["admin", "support"]` |
| Custom error | `authorize "p", error_message: "Admins only."` |
| Field redaction | `authorize "p", on_deny: :null` |

## Conditions cookbook

Inside `when:` / `unless:`:

```elixir
arg(:state) == "CLOSED"                     # GraphQL argument
arg(:priority) > 5                           # any comparison
arg(:role) in ["admin", "support"]           # list membership
loaded(:todo).owner_id == current_user.id    # remote record + user context
current_user.role == "admin"                 # context shorthand
context.tenant_id == arg(:tenant_id)         # arbitrary context path
arg(:state) == "CLOSED" and arg(:flag)       # boolean composition
```

Escape hatch when macros can't express it:

```elixir
authorize "perm", when: &MyAuth.complex_check/1
# or:
authorize "perm", when: fn %{args: a, context: c, loaded: l} -> ... end
```

The function receives `%{args: map, context: map, loaded: map}` and
must return a truthy/falsy value.

## Loading data before rules

```elixir
field :update_todo, :todo do
  arg :id, :integer

  load :todo, by: arg(:id)             # uses loader :todo
  load :user, by: arg(:user_id), using: :user_loader

  authorize "edit_own", when: loaded(:todo).owner_id == current_user.id
end
```

`load`s resolve once, before any rule evaluates, so multiple rules
share the loaded data.

## Owner-or-others sugar

The 80 % case as a one-liner:

```elixir
field :update_todo, :todo do
  arg :id, :integer

  authorize_owner :todo,
    by:           arg(:id),
    owner_field:  :owner_id,        # default
    user_field:   :id,              # default
    if_owner:     "edit_own_todo",
    if_other:     "edit_others_todo"
end
```

Expands to a `load` plus two `authorize` rules.

## Field-level redaction

Returns `null` instead of denying the operation. Use for sensitive
leaf fields like `:email`:

```elixir
object :user do
  field :id, :integer
  field :name, :string
  field :email, :string do
    authorize "view_emails", on_deny: :null
  end
end
```

## Introspection (use this when you change anything)

```elixir
AbsinthePermission.rules_for(MyApp.Schema, :mutation, :update_todo)
#=> [%AbsinthePermission.Rule{permission: {:any, ["edit_todos"]}, ...}, ...]

AbsinthePermission.loads_for(MyApp.Schema, :mutation, :update_todo)
AbsinthePermission.loader(MyApp.Schema, :todo)
AbsinthePermission.all_rules(MyApp.Schema)
```

CLI for surveying every rule in a schema:

```bash
mix absinthe_permission.audit MyApp.Schema
mix absinthe_permission.audit MyApp.Schema --filter todo
mix absinthe_permission.audit MyApp.Schema --format json
```

## Telemetry events

| Event | Measurements | Metadata |
| --- | --- | --- |
| `[:absinthe_permission, :decision, :allow]` | `%{duration: native_time}` | `%{schema, type, field, decision}` |
| `[:absinthe_permission, :decision, :deny]` | `%{duration: native_time}` | `%{schema, type, field, decision}` |
| `[:absinthe_permission, :decision, :nullify]` | `%{duration: native_time}` | `%{schema, type, field, decision}` |
| `[:absinthe_permission, :load, :stop]` | `%{duration: native_time}` | `%{loader, name, found}` |
| `[:absinthe_permission, :load, :exception]` | `%{duration: native_time}` | `%{loader, name, error}` |

Attach in your application supervision tree:

```elixir
:telemetry.attach(
  "ap-deny-logger",
  [:absinthe_permission, :decision, :deny],
  &MyApp.AuthLogger.handle/4,
  []
)
```

## Compile-time guarantees

The DSL fails at `mix compile` (not at request time) for:

- Unknown identifier in a condition
  (`when: foo(:bar)` where `foo` is not `arg`/`loaded`/`current_user`/`context`)
- `on_deny:` value other than `:error | :null | :filter`
- `authorize_owner` missing `:if_owner` or `:if_other`
- `:when` and `:unless` set on the same rule
- `authorize` / `load` called outside a schema field/object body
- Permission spec containing non-string values

## Configuring missing-context behaviour

```elixir
use AbsinthePermission, on_missing_context: :raise   # default
use AbsinthePermission, on_missing_context: :deny    # return GraphQL error
use AbsinthePermission, on_missing_context: :allow   # bypass auth (anon mode)
```

`:raise` raises `AbsinthePermission.MissingContextError`. `:deny`
returns an `Unauthorized: missing context` GraphQL error. `:allow`
treats requests with no `current_user`/`permissions` as fully
permitted — choose only when you understand the implications.

## Safety properties (verified by the test suite)

- **Fail-loud on missing context** — by default, requests without
  `current_user` / `permissions` raise. No silent fall-through.
- **No `String.to_atom` on user input** — permissions are kept as
  binaries throughout the evaluation pipeline.
- **AND-semantics across rules** — every fired rule must pass.
  Multiple `authorize` lines compose conjunctively; use `any: [...]`
  on a single rule for OR.
- **Pure data conditions** — every condition (other than the
  `:fun` escape hatch) is plain tuples, serialisable, hashable, and
  printable.

## File map (for navigation)

| Path | What lives there |
| --- | --- |
| `lib/absinthe_permission.ex` | Public API, `__using__` macro |
| `lib/absinthe_permission/dsl.ex` | DSL macros (`authorize`, `load`, `loader`, …) |
| `lib/absinthe_permission/compiler.ex` | Condition AST → data, scope detection, before-compile |
| `lib/absinthe_permission/evaluator.ex` | Pure evaluation of rules and conditions |
| `lib/absinthe_permission/middleware.ex` | Absinthe middleware integration |
| `lib/absinthe_permission/rule.ex` | `%Rule{}` struct + permission normalization |
| `lib/absinthe_permission/load.ex` | `%Load{}` struct |
| `lib/absinthe_permission/decision.ex` | `%Decision{}` struct (telemetry payload) |
| `lib/absinthe_permission/condition.ex` | Condition grammar + formatter |
| `lib/absinthe_permission/error.ex` | Custom exception structs |
| `lib/mix/tasks/absinthe_permission.audit.ex` | The audit task |
| `test/absinthe_permission/integration_test.exs` | End-to-end with a real schema |
| `test/absinthe_permission/evaluator_test.exs` | Pure-function unit tests |
| `test/support/test_schema.ex` | Worked schema demonstrating every feature |

## Don't do this

- `authorize :symbol` — permissions must be binaries. The compile
  error is helpful but you can save the round trip.
- `Module.put_attribute(:foo, :bar, ...)` directly inside a field — use
  `authorize` / `load`. The library's introspection won't see your
  raw attribute.
- `current_user_id` (the old DSL atom shorthand from v0.1) — use
  `current_user.id` or `current_user(:id)` instead.
- `String.to_atom/1` on permission names — use binaries everywhere.

## Migration from v0.1.x

`v1.0.0` is a complete rewrite. The old DSL (`pre_op_policies`,
`post_op_policies`, `remote_context`, `user_context`, value-first
`{value, op}` tuples) is removed. Mechanical translation:

| v0.1 | v1.0 |
| --- | --- |
| `meta(required_permission: "p")` | `authorize "p"` |
| `meta(pre_op_policies: [[state: "X", required_permission: "p"]])` | `authorize "p", when: arg(:state) == "X"` |
| `remote_context: [config: [fetcher_key: :db, …], fields: […], required_permission: "p"]` | `load :name, by: arg(:id)` + `authorize "p", when: loaded(:name).x == y` |
| `meta(post_op_policies: [[required_permission: "p"]])` (on a field) | `authorize "p", on_deny: :null` |
| Value-first `{:current_user_id, :neq}` | `current_user.id != ...` |
