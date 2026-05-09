defmodule AbsinthePermission.Condition do
  @moduledoc """
  Compiled condition AST and helpers.

  A condition is a small data tree, not a closure. This makes rules
  introspectable, testable, and serialisable.

  All variants use only 2-tuples (and lists) so they survive Absinthe's
  schema metadata pipeline intact.

  ## Grammar

      condition ::=
        | :always                              # vacuously true
        | {:literal, term()}
        | {:arg, atom()}                       # GraphQL argument
        | {:loaded, [atom()]}                  # [load_name, field, ...]
        | {:current_user, [atom()]}            # path under context.current_user
        | {:context, [atom()]}                 # arbitrary context path
        | {:cmp, [op() | expr()]}              # [op, lhs, rhs]
        | {:and, [condition()]}
        | {:or, [condition()]}
        | {:not, condition()}
        | {:fun, mfa_or_capture()}             # escape hatch

  Comparison operators: `:eq`, `:neq`, `:gt`, `:gte`, `:lt`, `:lte`,
  `:in`, `:not_in`.

  ## Why 2-tuples only

  Absinthe stores schema metadata through an AST-aware pipeline that
  treats any 3-element tuple as a macro call. Sticking to 2-tuples
  means rules survive the round-trip and remain plain data — readable
  for tests, logs, the `mix absinthe_permission.audit` task, and AI
  agents inspecting the schema.
  """

  @type op :: :eq | :neq | :gt | :gte | :lt | :lte | :in | :not_in
  @type expr ::
          {:literal, term()}
          | {:arg, atom()}
          | {:loaded, [atom(), ...]}
          | {:current_user, [atom()]}
          | {:context, [atom()]}
  @type t ::
          :always
          | expr()
          | {:cmp, [op() | expr()]}
          | {:and, [t()]}
          | {:or, [t()]}
          | {:not, t()}
          | {:fun, {module(), atom()} | (map() -> boolean())}

  @valid_ops [:eq, :neq, :gt, :gte, :lt, :lte, :in, :not_in]

  @doc "Returns the list of supported comparison operators."
  @spec valid_ops() :: [op()]
  def valid_ops, do: @valid_ops

  @doc "Returns true if `op` is a supported comparison operator."
  @spec valid_op?(atom()) :: boolean()
  def valid_op?(op), do: op in @valid_ops

  @doc """
  Pretty-print a condition as a one-line string. Used by audit output
  and error messages.

      iex> AbsinthePermission.Condition.format(:always)
      "always"

      iex> AbsinthePermission.Condition.format({:cmp, [:eq, {:arg, :state}, {:literal, "CLOSED"}]})
      "arg(:state) == \\"CLOSED\\""
  """
  @spec format(t()) :: String.t()
  def format(:always), do: "always"
  def format({:literal, v}), do: inspect(v)
  def format({:arg, name}), do: "arg(#{inspect(name)})"
  def format({:loaded, [name | path]}), do: format_path("loaded(#{inspect(name)})", path)
  def format({:current_user, path}), do: format_path("current_user", path)
  def format({:context, path}), do: format_path("context", path)
  def format({:cmp, [op, lhs, rhs]}), do: "#{format(lhs)} #{op_str(op)} #{format(rhs)}"
  def format({:and, conds}), do: "(#{Enum.map_join(conds, " and ", &format/1)})"
  def format({:or, conds}), do: "(#{Enum.map_join(conds, " or ", &format/1)})"
  def format({:not, c}), do: "not #{format(c)}"
  def format({:fun, {m, f}}), do: "&#{inspect(m)}.#{f}/1"
  def format({:fun, _}), do: "<fn>"

  defp format_path(prefix, []), do: prefix
  defp format_path(prefix, path), do: prefix <> "." <> Enum.map_join(path, ".", &Atom.to_string/1)

  defp op_str(:eq), do: "=="
  defp op_str(:neq), do: "!="
  defp op_str(:gt), do: ">"
  defp op_str(:gte), do: ">="
  defp op_str(:lt), do: "<"
  defp op_str(:lte), do: "<="
  defp op_str(:in), do: "in"
  defp op_str(:not_in), do: "not in"
end
