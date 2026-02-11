# workflow API

## topological_nodes

Returns nodes in dependency-first order.

```mbt check
///|
test {
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let ordered = topological_nodes(nodes)
  inspect(ordered.length(), content="2")
  inspect(ordered[0].id, content="root")
}
```

## graph_issues

Reports graph issues such as unknown dependencies and cycles.

```mbt check
///|
test {
  let nodes = [new_node("a", ["missing"])]
  let issues = graph_issues(nodes)
  inspect(issues.length() > 0, content="true")
}
```

## flow_fingerprint

Builds a deterministic fingerprint string from task, command, node, and signatures.

```mbt check
///|
test {
  let node = new_node("pkg", ["root"])
  let signatures : Map[String, String] = { "pkg": "pkg-1", "root": "root-1" }
  let fp = flow_fingerprint("test", "just test", node, signatures)
  inspect(fp.contains("task=test"), content="true")
}
```

## execute_ir

Construct IR directly from MoonBit API and execute with a callback runner.

```mbt check
///|
test {
  let nodes = [new_node("root", [])]
  let tasks = [new_task("root:build", "root", "build", [])]
  let ir = new_ir("ci", nodes, tasks)
  let run_task = fn(_task : FlowTask) { (true, "") }
  let result = execute_ir(ir, run_task)
  inspect(result.ok, content="true")
  inspect(result.steps[0].status, content="success")
}
```

## parse_starlark_subset

Parse a simple Starlark subset for workflow config.

```mbt check
///|
test {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let parsed = parse_starlark_subset(src)
  inspect(parsed.errors.length(), content="0")
  inspect(parsed.ir.tasks.length(), content="1")
}
```

## adapter APIs

Use `WorkflowAdapter` to wire command and filesystem behavior from outside.

```mbt check
///|
test {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let adapter = WorkflowAdapter::new(
    FsAdapter::memory_with({ "workflow.star": src }),
    CommandAdapter::new(fn(_cmd : String, _cwd : String?) {
      command_success(stdout="ok")
    }),
  )
  let result = execute_starlark_subset_from_fs("workflow.star", adapter)
  inspect(result.ok, content="true")
  inspect(write_execution_report("report.txt", result, adapter), content="true")
}
```
