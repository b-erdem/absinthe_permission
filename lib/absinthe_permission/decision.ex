defmodule AbsinthePermission.Decision do
  @moduledoc """
  The result of evaluating all rules attached to a field.

  Returned from `AbsinthePermission.Evaluator.evaluate_pre/6` and emitted as
  the metadata payload of `[:absinthe_permission, :decision]` telemetry
  events. Useful for logging, audit trails, and tests.

  ## Fields

    * `:verdict` — `:allow | :deny | :nullify | :filter`
    * `:reason` — atom describing why; `nil` when allowed
    * `:permission` — the permission that was checked, when relevant
    * `:field` — the field identifier this decision is about
    * `:matched_rules` — rules whose condition fired
    * `:loaded` — map of `name => record` for any loaded data
    * `:error_message` — message to surface to the client when `:verdict` is `:deny`
  """

  @type verdict :: :allow | :deny | :nullify | :filter

  @type reason ::
          nil
          | :missing_permission
          | :condition_unmet
          | :no_rules
          | :load_failed
          | :evaluation_error

  @type t :: %__MODULE__{
          verdict: verdict(),
          reason: reason(),
          permission: binary() | nil,
          field: atom() | nil,
          matched_rules: [AbsinthePermission.Rule.t()],
          loaded: %{atom() => any()},
          error_message: binary() | nil
        }

  defstruct verdict: :allow,
            reason: nil,
            permission: nil,
            field: nil,
            matched_rules: [],
            loaded: %{},
            error_message: nil

  @doc "Builds an `:allow` decision."
  @spec allow(keyword()) :: t()
  def allow(opts \\ []), do: struct!(__MODULE__, [{:verdict, :allow} | opts])

  @doc "Builds a `:deny` decision."
  @spec deny(keyword()) :: t()
  def deny(opts \\ []), do: struct!(__MODULE__, [{:verdict, :deny} | opts])
end
