# Changelog

All notable changes to this project are documented in this file.

## [0.4.0] - 2026-04-02

### Added

- Flow cache store read/write APIs: `read_flow_cache_store` and `write_flow_cache_store`.
- Flow cache JSON rendering and writeback APIs, including `render_task_cache_plan_json`, `render_task_cache_writeback_json`, and `writeback_task_cache*`.
- `bitflow cache-plan` / `bitflow cache-writeback` CLI entrypoints.

### Changed

- Fold example CLI tests into `src/examples/main.mbt` and remove the extra `main_test.mbt`.
- Replace deprecated `not(...)` usage in the repo with `!expr`.

## [0.3.0] - 2026-02-12

### Added

- Starlark slice step syntax support (e.g. `xs[a:b:c]`).
- Dependency analysis example workflow and sample monorepo under `examples/dependency-analysis`.
- Fixture coverage for workflow execution and invalid execution cases.
- `src/examples` package with runnable example entry and tests.

### Changed

- Refactored Starlark parser/semantics/loader/builtins into dedicated `src/starlark` package.
- Workflow package now uses the extracted Starlark package wiring.

## [0.2.0] - 2026-02-12

### Added

- Starlark var/config semantics with external input injection and type conversion.
- Changed-path targeting via `entry_targets_for_changed_paths` and `execute_ir_for_changed_paths`.
- Task cache planning API: `flow_task_fingerprint` and `plan_task_cache`.
- fs-based `load()` parsing with cycle detection and workspace-root boundary checks.
- Adapter execution propagation for `task.cwd` and `task.env`.

### Changed

- `task.srcs` and `task.outs` are both considered for changed-path entry target selection.
- `ir_issues` now reports invalid non-positive `max_parallel`.

### Breaking Changes

- `CommandAdapter::new` callback signature changed:
  from `(cmd : String, cwd : String?) -> CommandResult`
  to `(cmd : String, cwd : String?, env : Map[String, String]) -> CommandResult`.
- `FlowTask` public fields expanded (`srcs`, `outs`, `env`, `cwd`, `trigger_mode`).
- Starlark `var(required=True)` now requires value provision via `config()` or external inputs.

## [0.1.0] - 2026-02-11

### Added

- Initial extraction of workflow core from `mizchi/bit`.
- DAG validation, topological ordering, affected-node expansion.
- Base IR execution API and minimal Starlark subset parser.
