# mizchi/bitflow

Workflow engine primitives for MoonBit.

## Package

- `mizchi/bitflow/workflow`

## Features

- DAG validation and topological planning
- Starlark subset parser (`workflow/node/task/entrypoint/var/config/load`)
- Direct execution APIs for IR and Starlark sources
- Adapter boundary for command and filesystem integration
- Cache helpers (`flow_cache_key`, `flow_fingerprint`, `flow_task_fingerprint`, `plan_task_cache`, `writeback_task_cache`)

## Layering

- Language core: Python/Starlark subset expression parsing and evaluation
- Host API: workflow declarative calls (`workflow/node/task/entrypoint/var/config/load`)
- Execution layer: IR lowering, DAG planning, execution and cache integration

## Example

```mbt
import {
  "mizchi/bitflow/workflow" @wf,
}

let nodes = [@wf.new_node("root", []), @wf.new_node("dep", ["root"])]
let tasks = [
  @wf.new_task("root:build", "root", "build", []),
  @wf.new_task("dep:test", "dep", "test", ["root:build"]),
]
let ir = @wf.new_ir("ci", nodes, tasks, entry_targets=["dep:test"])
let result = @wf.execute_ir(ir, fn(_task : @wf.FlowTask) { (true, "") })
inspect(result.ok, content="true")
```

## Cache Roundtrip

```mbt
import {
  "mizchi/bitflow/workflow" @wf,
}

let adapter = @wf.WorkflowAdapter::new(
  @wf.FsAdapter::memory_with({
    "workflow.star":
      #|workflow(name="ci")
      #|node(id="root", depends_on=[])
      #|task(id="root:build", node="root", cmd="build", needs=[])
      #|entrypoint(targets=["root:build"]),
  }),
  @wf.CommandAdapter::none(),
)

let signatures : Map[String, String] = { "root": "sig-root" }
let writeback = @wf.writeback_task_cache_from_fs(
  "workflow.star",
  adapter,
  signatures,
  {},
  ["root:build"],
)
inspect(writeback.updated.length(), content="1")
let next_plan = @wf.plan_task_cache_from_fs(
  "workflow.star",
  adapter,
  signatures,
  writeback.entries,
)
inspect(next_plan.decisions[0].hit, content="true")
```
