defmodule AbsinthePermission.Load do
  @moduledoc """
  Declares a piece of data to fetch before a rule is evaluated.

  Loads are resolved once per request before any pre-op rule runs.
  Each rule references the loaded record by name via `loaded(:name)`
  in its condition.

  ## Fields

    * `:name` — atom; how the loaded record is referenced in conditions
    * `:loader` — atom; key in the schema's `loaders` block
    * `:by` — condition expression that evaluates to the lookup key (e.g.
      `{:arg, :id}`)
    * `:remote_key` — atom; field on the loaded record to match against, or
      `nil` if the loader takes the key directly
  """

  @type t :: %__MODULE__{
          name: atom(),
          loader: atom(),
          by: AbsinthePermission.Condition.expr(),
          remote_key: atom() | nil
        }

  @enforce_keys [:name, :loader, :by]
  defstruct [:name, :loader, :by, remote_key: nil]
end
