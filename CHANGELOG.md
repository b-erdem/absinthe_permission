# Changelog

All notable changes to this project will be documented in this file.
Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-05-09

Complete rewrite. Not API-compatible with `0.1.x`.

### Added
- New macro DSL: `authorize/2`, `load/2`, `authorize_owner/2`,
  `loaders/1`, `loader/2`. Auth rules live on the field they
  protect.
- Conditions written in plain Elixir (`arg(:state) == "CLOSED"`,
  `loaded(:todo).owner_id == current_user.id`) and compiled to
  introspectable data at schema-compile time.
- `%Rule{}`, `%Load{}`, `%Decision{}` data structures.
- Public introspection: `AbsinthePermission.rules_for/3`,
  `loads_for/3`, `loader/2`, `all_rules/1`.
- `mix absinthe_permission.audit` Mix task with text and JSON output.
- Telemetry events for every decision and loader call.
- Custom exceptions: `MissingContextError`, `UnauthorizedError`,
  `CompileError` for clear failure modes.
- `on_missing_context: :raise | :deny | :allow` option for
  `use AbsinthePermission`.
- `AGENTS.md` cookbook for AI coding agents.
- Comprehensive test suite (60+ tests, including doctests).
- CI-ready tooling: Credo, Dialyxir, Sobelow, ExCoveralls.

### Changed
- Bumped Absinthe to `~> 1.7`, telemetry to `~> 1.0`, Elixir to
  `~> 1.14`. Old `mix.lock` versions are 5+ years out of date and
  conflict with modern Phoenix apps.
- The DSL no longer relies on Absinthe's `meta/1` for rule storage,
  sidestepping its long-standing AST/map-literal limitation. Rules
  live in module attributes and are exposed via generated
  `__absinthe_permission_rules__/2` functions.
- Permissions are kept as binaries end-to-end. No `String.to_atom`
  on configuration data. Sobelow-clean.

### Removed
- The old `meta(pre_op_policies: ...)` / `meta(post_op_policies: ...)`
  DSL.
- `remote_context` / `user_context` blocks — replaced by `load/2`
  + `loaded(:name).field` in conditions.
- Value-first operator tuples (`{value, op}`) — operators are now
  expressed as native Elixir (`==`, `!=`, `>`, `<`, `in`, …).
- `:current_user_id` magic atom — use `current_user.id` or
  `current_user(:id)`.
- Implicit fail-open on missing context — now configurable, raises
  by default.

### Fixed
- Silent permission bypass when context lacked `current_user` or
  `permissions` — now raises by default.
- Duplicate-permission accumulation in the rule tracker.
- Crash on fetcher errors instead of returning a clean denial.

## [0.1.0] — 2020-09-12

Initial release.
