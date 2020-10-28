# AbsinthePermission

**Fine-grained Permission/Policy Checker Middleware for Absinthe Queries/Mutations/Subscriptions**

This module allows to define fine-grained permissions for queries, mutations and subscriptions
by leveraging Absinthe's `meta` field.

This module defines 3 types policies:

1. Simple permission checks. It only checks if a user has specified permission or not.
2. Policy checks prior to run query, nutation or subscription.
3. Policy checks after operation.

## 1: Simple Permission Checks

For type 1 policies definition is simple. You just provide permission name on query and that's it.
It'll run before executing the operation.

Example:

```elixir
...
query do
  ...
  field(:get_todo_list, list_of(:todo)) do
    meta(required_permission: "can_view_todo_list")
  end
  ...
end
...
```

## 2: Pre-op Permission/Policy Check.

There are a few common ways to check if a user is allowed to do the operation before running the operation.
One of them is checking given input values to see if the user is allowed to do operation.
For instance you have an app like Jira. And a user wants to change the status of a ticket.
And let's say only project managers can change a ticket status as `CLOSED`.
In this case when a request comes in with `{..., state: "CLOSED"}`, then you'd want to check
`state` parameter if it's `CLOSED` or not. Then check if the user has this permission: `can_close_ticket`.

With this module you can define this policy without writing any code:

```elixir
mutation do
  ...
  field(:update_ticket, :ticket) do
    arg(:id, :integer)
    arg(:detail, :string)
    arg(:state, :string)
    
    meta(
      pre_op_policies: [
        [
          state: "CLOSED",
          required_permission: "can_close_ticket"
        ]
      ]
    )
  end
  ...
end
```


In some other cases, it's not enough to check input values to allow or deny a user.
For some operations you'd want to check the remote object before doing any operation on it.
Let's say, there's another permission for updating description of a "CLOSED" ticket.
In this case before allowing a user to change the description of a ticket, you first fetch it
from remote and check it if its `state` is "CLOSED" or not. And you allow or deny.

Here is how to add a new policy to `updateTicket` mutation:

```elixir
mutation do
  ...
  field(:update_ticket, :ticket) do
    arg(:id, :integer)
    arg(:detail, :string)
    arg(:state, :string)
          
    meta(   
      pre_op_policies: [
        [
          state: "CLOSED",
          required_permission: "can_close_ticket"
        ],
        [
          remote_context: [
            config: [fetcher_key: :my_db, remote_key: :id, input_key: :id],
            fields: [state: "CLOSED"],
            extras: [model: Ticket]
          ],
          required_permission: "can_update_closed_ticket_detail"
        ]
      ]
    )
  end
  ...
end
```

These are a few examples what can be done with pre operation policies.
And even more, you're not limited to use only one of them for a policy.
You can combine them in a policy. Local context and remote context together.

For `remote_context` there are a few additional fields. Explanation is below.

And there are some cases which you'd want to have policies after operation runs.
For instance nullifying some fields in the response.
Example: Everyone can get a ticket's details. And there's `assignee` field on it.
`assignee` field has `email` field. And you don't want to everyone see this field.
You can define this policy on `email` field:

```elixir
...
object :assignee do
  field(:id, :integer)
  field(:name, :string)
  ...
  field(:email, :string) do
    meta(
      post_op_policies: [
        [required_permission: "can_view_email"]
      ]
    )
  end
end
...
```

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

