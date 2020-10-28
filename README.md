# AbsinthePermission

**Fine-grained Permission/Policy Checker Middleware for Absinthe Queries/Mutations/Subscriptions**

## Installation


```elixir
def deps do
  [
    {:absinthe_permission, "~> 0.1.0"}
  ]
end
```

## Usage

### Register the Middleware

Add `AbsinthePermission.Middleware.HasPermission` to your Absinthe Schema:

```elixir
def middleware(middleware, _field, _object) do
      [AbsinthePermission.Middleware.HasPermission] ++ middleware ++ [AbsinthePermission.Middleware.HasPermission]
    end
```

