defmodule AbsinthePermission.Rule do
  @moduledoc """
  A single authorization or filtering rule attached to a schema field.

  Rules are produced by the DSL macros (`authorize/2`, `filter/2`, etc.) at
  compile time and stored on the schema for the middleware to evaluate at
  request time.

  ## Fields

    * `:phase` — `:pre` (before resolve) or `:post` (after resolve)
    * `:permission` — required permission(s); see `t:permission/0`
    * `:condition` — when this rule applies (`t:AbsinthePermission.Condition.t/0`)
    * `:on_deny` — what to do when the rule denies: `:error | :null | :filter`
    * `:error_message` — optional custom error message
    * `:location` — `%{file: binary, line: pos_integer}` — for error reporting

  A rule "fires" when its condition evaluates to true. When it fires, the
  caller must hold the required permission(s) or the rule denies.
  """

  @type permission ::
          nil
          | binary()
          | [binary()]
          | {:all, [binary()]}
          | {:any, [binary()]}

  @type t :: %__MODULE__{
          phase: :pre | :post,
          permission: permission(),
          condition: AbsinthePermission.Condition.t(),
          on_deny: :error | :null | :filter,
          error_message: binary() | nil,
          location: %{file: binary(), line: pos_integer()}
        }

  @enforce_keys [:phase, :permission, :condition, :on_deny, :location]
  defstruct [
    :phase,
    :permission,
    :condition,
    :on_deny,
    :location,
    error_message: nil
  ]

  @doc """
  Normalises a permission specifier into a canonical form.

      iex> AbsinthePermission.Rule.normalize_permission("admin")
      {:any, ["admin"]}

      iex> AbsinthePermission.Rule.normalize_permission(["admin", "support"])
      {:any, ["admin", "support"]}

      iex> AbsinthePermission.Rule.normalize_permission({:all, ["admin", "verified"]})
      {:all, ["admin", "verified"]}

      iex> AbsinthePermission.Rule.normalize_permission(nil)
      nil
  """
  @spec normalize_permission(permission() | [{:all | :any, [binary()]}]) ::
          nil | {:all | :any, [binary()]}
  def normalize_permission(nil), do: nil
  def normalize_permission(p) when is_binary(p), do: {:any, [p]}

  def normalize_permission({op, ps}) when op in [:all, :any] and is_list(ps),
    do: {op, validate_perms!(ps)}

  # Keyword-list sugar: `all: [...]` or `any: [...]` — produced when
  # users write `authorize all: ["admin", "verified_2fa"]`.
  def normalize_permission([{:all, ps}]) when is_list(ps), do: {:all, validate_perms!(ps)}
  def normalize_permission([{:any, ps}]) when is_list(ps), do: {:any, validate_perms!(ps)}

  # Plain list of strings = any-of.
  def normalize_permission(ps) when is_list(ps), do: {:any, validate_perms!(ps)}

  defp validate_perms!(ps) do
    Enum.each(ps, fn
      p when is_binary(p) -> :ok
      other -> raise ArgumentError, "permission must be a string, got: #{inspect(other)}"
    end)

    ps
  end
end
