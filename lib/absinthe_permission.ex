defmodule AbsinthePermission do
  @moduledoc """
  This middleware allows to restrict operations on
  queries, mutations and subscriptions in declarative manner
  by leveraging `meta` field.

  This middleware especially useful if you have role based
  access management.

  There are 3 types policies:
  1. You can define required permission for an operation.
     Either deny or allow.
     For these simple use cases you can define something like this:
     ```
     query do
      ...
      field(:get_todo_list, list_of(:todo)) do
        meta(required_permission: "can_view_todo_list")
      end
      ...
     end
     ```
  2. If you need some permission/policies based on
     query/mutation inputs, or related objects,
     you need specify fine-grained policies based on
     your needs.
     For example, you've a todo app and don't want
     some users to update or delete other users todos.
     For being able to enforce this policy you need to know
     the creator of that todo object. So first you need to access it
     and check it if `current_user` is the creator of that todo.

     In this scenario, you can define your policy like this:

     ```
     mutation do
      ...
      field(:update_todo, :todo) do
        meta(
          pre_op_policies: [
            [
              remote_context: [creator__id: :current_user_id],
              required_permission: "can_change_his_own_todo"
            ]
          ]
        )
      end
      ...
     end
     ```

     You can define this policy in other way around as well.
     Imstead of having a permission like "can_change_his_own_todo",
     you can have permission like "can_change_other_users_todos".
     In this case the policy would be like this:

     ```
      meta(
        pre_op_policies: [
          [
            remote_context: [creator__id: {:current_user_id, :neq}],
            required_permission: "can_change_other_users_todo"
          ]
        ]
      )
     ```

     And additionally if you want to restrict based on input arguments,
     you can add it to policies.
     For instance let's add another policy to `updateTodo`.
     If some users try to change other users todo name to "Danger Zone",
     then they'll need to have a permission.
     And define a permission for it: "can_change_other_users_todo_name_to_danger_zone".

     ```
     meta(
       pre_op_policies: [
         [
           remote_context: [creator__id: {:current_user_id, :neq}],
           required_permission: "can_change_other_users_todo"
         ], # policy 1
         [
           remote_context: [creator__id: {:current_user_id, :neq}],
           name: "Danger Zone",
           required_permission: "can_change_other_users_todo_name_to_danger_zone"
         ] # policy 2
       ]
     )
     ```

  3. In some situation there's a need for policies after operation has been done.
     For instance a user can view todo list.
     And todo object has `creator` field on it. And `creator` field has `email` field.
     Let's say you don't want users who don't have "can_view_emails" permission
     to not view emails even if they have permission to view todo list.
     In this case you define a policy on `email` field:

     ```
     ...
     object :todo do
      field(:id, :integer)
      field(:name, :string)
      field(:detail, :string)
      field(:creator, :user)
     end

     object :user do
      ...
      field(:email, :string) do
        meta(
          post_op_policies: [required_permission: "can_view_emails"]
        )
      end
      ...
     end
     ...
     ```
  """
end
