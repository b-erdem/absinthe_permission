# AbsinthePermission

[![Hex.pm](https://img.shields.io/hexpm/v/absinthe_permission.svg)](https://hex.pm/packages/absinthe_permission)
[![License](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

**Declarative, schema-first authorization for Absinthe GraphQL.**

Auth rules live next to the field they protect. They compile to
introspectable data, evaluate via middleware, and emit telemetry on
every decision.

```elixir
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
```

That's it. No separate policy module to wire up; no string-encoded
field paths; no closures hidden in module attributes; no surprise
fail-open behaviour. Conditions are real Elixir, validated at
`mix compile`, inspectable at runtime via
`AbsinthePermission.rules_for/3` or `mix absinthe_permission.audit`.

## When to use this

- You write Absinthe schemas and want per-field authorization rules
  that read like English.
- You want to enforce policies *visible on the schema* — humans and
  AI agents can read `field :update_todo do ... end` and immediately
  see what's protected.
- You're tired of fighting Absinthe's `meta/1` keyword-list-of-
  keyword-list DSLs.

If you instead prefer policy modules per resource (Bodyguard / Permit
style), look at [`permit_absinthe`](https://hex.pm/packages/permit_absinthe).
This library deliberately occupies the *declarative-on-schema* niche.

## Installation

```elixir
def deps do
  [
    {:absinthe_permission, "~> 1.0"}
  ]
end
```

Requires Elixir `~> 1.14` and Absinthe `~> 1.7`.

## Five-minute walkthrough

### 1. Wire up the schema

```elixir
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

      resolve &MyApp.Resolvers.update_todo/2
    end
  end
end
```

### 2. Populate the context

In your Plug pipeline (typically `MyAppWeb.Context`):

```elixir
conn
|> Absinthe.Plug.put_options(
  context: %{
    current_user: user,
    permissions: MyApp.Auth.permissions_for(user)
  }
)
```

`permissions` is a list of binary permission strings. That's it.

### 3. (Optional) attach telemetry

```elixir
:telemetry.attach(
  "ap-deny-logger",
  [:absinthe_permission, :decision, :deny],
  &MyApp.AuthLogger.handle/4,
  []
)
```

## DSL reference

### `authorize/2`

```elixir
authorize "edit_todos"                              # always required
authorize ["admin", "support"]                       # any-of
authorize all: ["admin", "verified_2fa"]             # all-of

authorize "close_todos",  when: arg(:state) == "CLOSED"
authorize "high_prio",    when: arg(:priority) > 5
authorize "edit_own",     when: loaded(:todo).owner_id == current_user.id
authorize "edit_others",  unless: loaded(:todo).owner_id == current_user.id
authorize "view_emails",  on_deny: :null            # redact, return null
authorize "edit_todos",   error_message: "Only admins may edit todos."

# Escape hatch
authorize "complex", when: &MyApp.Auth.complex_check/1
```

#### Condition helpers (used inside `when:` / `unless:`)

| | |
| --- | --- |
| `arg(:name)` | a GraphQL argument |
| `loaded(:name).field.path` | a field on a loaded record |
| `current_user.id` (or `current_user(:id)`) | shorthand for `context.current_user.id` |
| `context.path` | arbitrary context lookup |

All native Elixir comparison operators work: `==`, `!=`, `>`, `>=`,
`<`, `<=`, `in`. Combine with `and` / `or` / `not`.

### `load/2`

Resolves a record once before any rule on the field runs.

```elixir
load :todo, by: arg(:id)
load :user, by: arg(:user_id), using: :user_loader
```

Loaders are registered with `loader/2`:

```elixir
loaders do
  loader :todo, fn id, _ctx -> MyApp.Todos.get(id) end
  loader :user, &MyApp.Users.fetch/2
end
```

### `authorize_owner/2`

Sugar for the most common pattern:

```elixir
authorize_owner :todo,
  by:          arg(:id),
  owner_field: :owner_id,           # default
  user_field:  :id,                  # default
  if_owner:    "edit_own_todo",
  if_other:    "edit_others_todo"
```

Expands to one `load` plus two `authorize` rules.

## Introspection

```elixir
AbsinthePermission.rules_for(MyApp.Schema, :mutation, :update_todo)
AbsinthePermission.loads_for(MyApp.Schema, :mutation, :update_todo)
AbsinthePermission.loader(MyApp.Schema, :todo)
AbsinthePermission.all_rules(MyApp.Schema)
```

Or from the command line:

```bash
mix absinthe_permission.audit MyApp.Schema
mix absinthe_permission.audit MyApp.Schema --filter todo
mix absinthe_permission.audit MyApp.Schema --format json
```

## Telemetry events

| Event | Metadata |
| --- | --- |
| `[:absinthe_permission, :decision, :allow]` | `%{schema, type, field, decision}` |
| `[:absinthe_permission, :decision, :deny]`  | `%{schema, type, field, decision}` |
| `[:absinthe_permission, :decision, :nullify]` | `%{schema, type, field, decision}` |
| `[:absinthe_permission, :load, :stop]`      | `%{loader, name, found}` |
| `[:absinthe_permission, :load, :exception]` | `%{loader, name, error}` |

The `decision` field is a `t:AbsinthePermission.Decision.t/0` —
useful for audit logs.

## Configuration

```elixir
use AbsinthePermission, on_missing_context: :raise   # default
use AbsinthePermission, on_missing_context: :deny    # return GraphQL error
use AbsinthePermission, on_missing_context: :allow   # treat as anonymous
```

## For AI coding agents

This repo ships an [`AGENTS.md`](AGENTS.md) cookbook with verified
patterns and a one-screen mental model. If you're an LLM working on
an Absinthe project, start there.

## License

MIT — see [LICENSE](LICENSE).
