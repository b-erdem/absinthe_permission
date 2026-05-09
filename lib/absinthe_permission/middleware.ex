defmodule AbsinthePermission.Middleware do
  @moduledoc """
  Absinthe middleware that enforces `AbsinthePermission` rules.

  You don't usually call this directly. `use AbsinthePermission`
  installs a `middleware/3` callback on your schema that wires this in
  for every field with rules.

  ## How it attaches

  For each field, the schema's `middleware/3` callback runs at compile
  time. `attach/4` looks up the rules for that field on the schema:

    * If there are pre-op rules (those with `on_deny: :error`), this
      module is prepended to the field's middleware list.
    * If there are post-op rules (those with `on_deny: :null` or
      `:filter`), this module is appended.
    * Fields with no rules are untouched.

  ## Telemetry

  Every decision emits one of:

    * `[:absinthe_permission, :decision, :allow]`
    * `[:absinthe_permission, :decision, :deny]`
    * `[:absinthe_permission, :decision, :nullify]`

  with measurements `%{duration: native_time}` and metadata
  `%{schema: ..., type: ..., field: ..., decision: %Decision{}}`.

  Loader events are emitted by `AbsinthePermission.Evaluator` —
  see its docs.
  """

  @behaviour Absinthe.Middleware

  alias AbsinthePermission.{Decision, Evaluator, MissingContextError}

  @doc """
  Wraps a field's middleware list with pre-/post-op checks based on
  the rules registered on the schema. Designed to be called from a
  schema's `middleware/3` callback.
  """
  @spec attach([Absinthe.Middleware.spec()], any(), any(), module()) ::
          [Absinthe.Middleware.spec()]
  def attach(middleware, %{identifier: field_id} = _field, %{identifier: type_id} = _object, schema) do
    rules = schema_rules(schema, type_id, field_id)
    loads = schema_loads(schema, type_id, field_id)

    {pre_rules, post_rules} = Enum.split_with(rules, &(&1.phase == :pre))

    middleware
    |> maybe_prepend(pre_rules, loads, schema, type_id, field_id)
    |> maybe_append(post_rules, schema, type_id, field_id)
  end

  def attach(middleware, _field, _object, _schema), do: middleware

  defp maybe_prepend(middleware, [], _loads, _schema, _type_id, _field_id), do: middleware

  defp maybe_prepend(middleware, rules, loads, schema, type_id, field_id) do
    config =
      {:pre,
       %{
         schema: schema,
         type_id: type_id,
         field_id: field_id,
         rules: rules,
         loads: loads
       }}

    [{__MODULE__, config} | middleware]
  end

  defp maybe_append(middleware, [], _schema, _type_id, _field_id), do: middleware

  defp maybe_append(middleware, rules, schema, type_id, field_id) do
    config =
      {:post,
       %{
         schema: schema,
         type_id: type_id,
         field_id: field_id,
         rules: rules
       }}

    middleware ++ [{__MODULE__, config}]
  end

  defp schema_rules(schema, type_id, field_id) do
    if function_exported?(schema, :__absinthe_permission_rules__, 2) do
      schema.__absinthe_permission_rules__(type_id, field_id)
    else
      []
    end
  end

  defp schema_loads(schema, type_id, field_id) do
    if function_exported?(schema, :__absinthe_permission_loads__, 2) do
      schema.__absinthe_permission_loads__(type_id, field_id)
    else
      []
    end
  end

  # ===========================================================================
  # Pre-op
  # ===========================================================================

  @impl true
  def call(%{state: :unresolved} = res, {:pre, config}) do
    case ensure_context(res, config.schema) do
      {:ok, context} ->
        run_pre(res, context, config)

      {:deny, message} ->
        Absinthe.Resolution.put_result(res, {:error, message})

      {:allow, _} ->
        res

      {:raise, exception} ->
        raise exception
    end
  end

  def call(%{state: :resolved} = res, {:post, config}) do
    case Map.get(res.context, :current_user, :__missing__) do
      :__missing__ ->
        # Same missing-context handling as pre-op.
        case res.context |> ensure_context_for_schema(config.schema) do
          {:deny, message} -> Absinthe.Resolution.put_result(res, {:error, message})
          {:allow, _} -> res
          {:raise, exc} -> raise exc
          {:ok, context} -> run_post(res, context, config)
        end

      _ ->
        run_post(res, res.context, config)
    end
  end

  def call(res, _), do: res

  # ===========================================================================
  # Pre-op runner
  # ===========================================================================

  defp run_pre(res, context, %{rules: rules, loads: loads, schema: schema} = config) do
    args = res.arguments || %{}
    start = System.monotonic_time()

    decision = Evaluator.evaluate_pre(rules, loads, schema, args, context, config.field_id)

    emit_telemetry(decision, config, System.monotonic_time() - start)

    case decision.verdict do
      :allow ->
        res

      :deny ->
        Absinthe.Resolution.put_result(res, {:error, build_error(decision)})

      _other ->
        # :nullify / :filter shouldn't appear in pre-op (we filter them out at attach
        # time), but be defensive.
        res
    end
  end

  # ===========================================================================
  # Post-op runner
  # ===========================================================================

  defp run_post(res, context, %{rules: rules, schema: _schema} = config) do
    args = res.arguments || %{}
    start = System.monotonic_time()

    {action, decision} =
      Evaluator.evaluate_post(rules, res.value, args, context, config.field_id)

    emit_telemetry(decision, config, System.monotonic_time() - start)

    case action do
      :allow ->
        res

      :nullify ->
        %{res | value: nil}

      :deny ->
        Absinthe.Resolution.put_result(res, {:error, build_error(decision)})
    end
  end

  # ===========================================================================
  # Context handling
  # ===========================================================================

  defp ensure_context(%{context: context}, schema), do: ensure_context_for_schema(context, schema)

  defp ensure_context_for_schema(context, schema) do
    missing =
      [:current_user, :permissions]
      |> Enum.reject(&Map.has_key?(context, &1))

    case missing do
      [] ->
        {:ok, context}

      _ ->
        case schema_on_missing(schema) do
          :allow -> {:allow, context}
          :deny -> {:deny, "Unauthorized: missing context"}
          :raise -> {:raise, MissingContextError.exception(missing)}
        end
    end
  end

  defp schema_on_missing(schema) do
    if function_exported?(schema, :__absinthe_permission_on_missing_context__, 0) do
      schema.__absinthe_permission_on_missing_context__()
    else
      :raise
    end
  end

  # ===========================================================================
  # Telemetry & error formatting
  # ===========================================================================

  defp emit_telemetry(%Decision{verdict: verdict} = decision, config, duration) do
    :telemetry.execute(
      [:absinthe_permission, :decision, verdict],
      %{duration: duration},
      %{
        schema: config.schema,
        type: config.type_id,
        field: config.field_id,
        decision: decision
      }
    )
  end

  defp build_error(%Decision{} = decision) do
    %{
      message: decision.error_message || "Unauthorized",
      extensions: build_extensions(decision)
    }
  end

  defp build_extensions(%Decision{permission: nil, field: field}),
    do: %{code: "UNAUTHORIZED", field: field}

  defp build_extensions(%Decision{permission: perm, field: field}),
    do: %{code: "UNAUTHORIZED", field: field, missing_permission: perm}
end
