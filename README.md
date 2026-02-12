# bitflow

Workflow engine core for `bit workspace`.

This repository hosts reusable, pure workflow logic that is being migrated out
from `mizchi/bit`:

- DAG validation
- topological ordering
- affected-node expansion
- flow cache key / fingerprint generation
- direct IR execution API
- Starlark subset parser (`workflow/node/task/entrypoint/load`)
- environment-agnostic adapters (`WorkflowAdapter`, `FsAdapter`, `CommandAdapter`)

## Package

- `mizchi/bitflow/workflow`

## Quick Commands

```bash
just           # check + test
just fmt       # format code
just check     # type check
just test      # run tests
just info      # generate type definition files
```

## CLI (Parser Check)

`src/main` now provides a small CLI that validates a workflow file with
Starlark `var/config` semantics, including external overrides.

```bash
moon run src/main -- path/to/workflow.star --var profile=prod
# or
BITFLOW_VAR_profile=prod moon run src/main -- path/to/workflow.star
```

Supported forms:

- `bitflow [check] <workflow.star> [--var KEY=VALUE]...`
- env override prefix: `BITFLOW_VAR_`

## Example

```mbt
import {
  "mizchi/bitflow/workflow" @wf,
}

let nodes = [
  @wf.new_node("root", []),
  @wf.new_node("dep", ["root"]),
]

let ordered = @wf.topological_nodes(nodes)
let issues = @wf.graph_issues(nodes)
```

## License

Apache-2.0
