///|
fn run_ok(_task : FlowTask) -> (Bool, String) {
  (true, "")
}

///|
fn run_fail(task : FlowTask) -> (Bool, String) {
  if task.id == "dep:test" {
    (false, "dep failed")
  } else {
    (true, "")
  }
}

///|
test "workflow engine: direct API executes topological tasks" {
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("dep:test", "dep", "test", ["root:build"]),
  ]
  let ir = new_ir(
    "ci",
    nodes,
    tasks,
    entry_targets=["dep:test"],
    max_parallel=2,
  )
  let result = execute_ir(ir, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.state, "completed")
  assert_eq(result.order.length(), 2)
  assert_eq(result.steps[0].status, "success")
  assert_eq(result.steps[1].status, "success")
}

///|
test "workflow engine: required failure blocks dependent task" {
  let nodes = [
    new_node("root", []),
    new_node("dep", ["root"]),
    new_node("leaf", ["dep"]),
  ]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("dep:test", "dep", "test", ["root:build"]),
    new_task("leaf:deploy", "leaf", "deploy", ["dep:test"]),
  ]
  let ir = new_ir("ci", nodes, tasks)
  let result = execute_ir(ir, run_fail)
  assert_eq(result.ok, false)
  assert_eq(result.state, "partial_failed")
  let text = result.steps.map(step => step.id + ":" + step.status).join("\n")
  assert_true(text.contains("dep:test:failed"))
  assert_true(text.contains("leaf:deploy:blocked"))
}

///|
test "workflow engine: starlark subset parses and runs" {
  let src =
    #|workflow(name="ci", max_parallel=4)
    #|node(id="root", depends_on=[])
    #|node(id="dep", depends_on=["root"])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|task(id="dep:test", node="dep", cmd="test", needs=["root:build"])
    #|entrypoint(targets=["dep:test"])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.nodes.length(), 2)
  assert_eq(parsed.ir.tasks.length(), 2)
  let result = execute_ir(parsed.ir, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.steps.length(), 2)
}

///|
test "workflow engine: starlark subset parser reports unknown function" {
  let src =
    #|workflow(name="ci")
    #|unknown_call(x="y")
  let parsed = parse_starlark_subset(src)
  assert_true(parsed.errors.length() > 0)
  assert_true(parsed.errors.join("\n").contains("unknown statement"))
}

///|
test "workflow engine: execute_starlark_subset runs parsed workflow directly" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let result = execute_starlark_subset(src, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.state, "completed")
  assert_eq(result.order.length(), 1)
  assert_eq(result.steps[0].status, "success")
}
