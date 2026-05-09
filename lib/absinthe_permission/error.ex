defmodule AbsinthePermission.UnauthorizedError do
  @moduledoc """
  Raised (or returned as a tagged error) when a caller is not authorised to
  perform an operation.

  This exception is *also* used as the GraphQL error payload for denied
  operations. The `:message`, `:field`, and `:permission` fields are
  surfaced to the client.
  """

  defexception [:message, :field, :permission, :reason]

  @type t :: %__MODULE__{
          message: binary(),
          field: atom() | nil,
          permission: binary() | nil,
          reason: atom() | nil
        }
end

defmodule AbsinthePermission.MissingContextError do
  @moduledoc """
  Raised at request time when the Absinthe context lacks the keys
  `AbsinthePermission` requires (`:current_user`, `:permissions`).

  This is the **fail-loud** alternative to silently allowing operations
  for unauthenticated requests. Configure
  `:on_missing_context` in `use AbsinthePermission` to change behaviour.
  """

  defexception [:message, :missing_keys]

  @type t :: %__MODULE__{message: binary(), missing_keys: [atom()]}

  @impl true
  def exception(missing) when is_list(missing) do
    %__MODULE__{
      message:
        "Absinthe context is missing required keys: #{inspect(missing)}. " <>
          "AbsinthePermission expects `current_user` and `permissions` in context. " <>
          "Set them in your Plug pipeline (Absinthe.Plug.put_options/2) or pass " <>
          "`on_missing_context: :allow | :deny` to `use AbsinthePermission` " <>
          "to override this behaviour.",
      missing_keys: missing
    }
  end
end

defmodule AbsinthePermission.CompileError do
  @moduledoc """
  Raised at schema compile time when the DSL is misused — unknown
  permission, unknown loader, malformed condition expression, etc.

  These errors are *meant* to be loud. They make typos fail `mix compile`
  rather than fail in production at request time.
  """

  defexception [:message, :location]

  @type t :: %__MODULE__{message: binary(), location: keyword() | nil}

  @impl true
  def exception(opts) when is_list(opts) do
    msg = Keyword.fetch!(opts, :message)
    loc = Keyword.get(opts, :location)

    full =
      case loc do
        nil -> msg
        loc -> "#{msg}\n  at #{loc[:file]}:#{loc[:line]}"
      end

    %__MODULE__{message: full, location: loc}
  end

  def exception(msg) when is_binary(msg), do: %__MODULE__{message: msg}
end
