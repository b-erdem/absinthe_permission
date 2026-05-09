defmodule Mix.Tasks.AbsinthePermission.Audit do
  @shortdoc "Print every authorization rule attached to a schema"

  @moduledoc """
  Print every `AbsinthePermission` rule attached to a schema, grouped
  by `(type, field)`.

  ## Usage

      mix absinthe_permission.audit MyApp.Schema

  ## Options

    * `--format` — `text` (default) or `json`
    * `--filter` — substring filter on field name (case-insensitive)

  ## Examples

      mix absinthe_permission.audit MyApp.Schema
      mix absinthe_permission.audit MyApp.Schema --format json
      mix absinthe_permission.audit MyApp.Schema --filter todo

  Designed for two audiences:

    * **Humans** — quick survey of what's protected and how.
    * **AI coding agents** — machine-readable JSON output via
      `--format json`, for programmatically reasoning about the schema.
  """

  use Mix.Task

  alias AbsinthePermission.{Condition, Rule}

  @impl true
  def run(argv) do
    {opts, args} =
      OptionParser.parse!(argv,
        strict: [format: :string, filter: :string],
        aliases: [f: :format]
      )

    case args do
      [schema_str] ->
        Mix.Task.run("compile")
        schema = Module.concat([schema_str])
        rules = collect(schema, opts[:filter])

        case opts[:format] do
          "json" -> print_json(rules)
          _ -> print_text(schema, rules)
        end

      _ ->
        Mix.shell().error("usage: mix absinthe_permission.audit MODULE [--format text|json]")
        exit({:shutdown, 1})
    end
  end

  defp collect(schema, filter) do
    schema.__absinthe_permission_all_rules__()
    |> Enum.sort()
    |> Enum.filter(fn {{_, field}, _} ->
      filter == nil or String.contains?(Atom.to_string(field), String.downcase(filter))
    end)
  end

  defp print_text(schema, []) do
    Mix.shell().info("No AbsinthePermission rules in #{inspect(schema)}.")
  end

  defp print_text(schema, rules) do
    Mix.shell().info(IO.ANSI.format([:bright, "\n#{inspect(schema)}"]))
    Mix.shell().info(String.duplicate("─", 60))

    for {{type, field}, rules} <- rules do
      Mix.shell().info(IO.ANSI.format([:cyan, "  #{type}.#{field}"]))

      for rule <- rules do
        line = format_rule_line(rule)
        Mix.shell().info("    #{line}")
      end
    end

    total = Enum.reduce(rules, 0, fn {_, rs}, acc -> acc + length(rs) end)

    Mix.shell().info(
      IO.ANSI.format([:faint, "\n  #{total} rule(s) across #{length(rules)} field(s)"])
    )
  end

  defp format_rule_line(%Rule{} = rule) do
    perm = format_perm(rule.permission)
    cond_str = Condition.format(rule.condition)

    base =
      case rule.condition do
        :always -> "#{perm}"
        _ -> "#{perm} when #{cond_str}"
      end

    case rule.on_deny do
      :error -> base
      :null -> "#{base} → null"
      :filter -> "#{base} → filter"
    end
  end

  defp format_perm(nil), do: "(no perm)"
  defp format_perm({:any, [p]}), do: ~s|"#{p}"|
  defp format_perm({:any, ps}), do: "any-of #{inspect(ps)}"
  defp format_perm({:all, ps}), do: "all-of #{inspect(ps)}"

  defp print_json(rules) do
    payload =
      for {{type, field}, rs} <- rules do
        %{
          type: type,
          field: field,
          rules:
            for r <- rs do
              %{
                phase: r.phase,
                permission: rule_perm_json(r.permission),
                condition: Condition.format(r.condition),
                on_deny: r.on_deny,
                error_message: r.error_message,
                location: r.location
              }
            end
        }
      end

    case Code.ensure_loaded(Jason) do
      {:module, Jason} ->
        IO.puts(Jason.encode!(payload, pretty: true))

      _ ->
        IO.puts(inspect(payload, pretty: true, limit: :infinity))
    end
  end

  defp rule_perm_json(nil), do: %{kind: "none"}
  defp rule_perm_json({:any, ps}), do: %{kind: "any_of", permissions: ps}
  defp rule_perm_json({:all, ps}), do: %{kind: "all_of", permissions: ps}
end
