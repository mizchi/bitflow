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
fn run_optional_fail(task : FlowTask) -> (Bool, String) {
  if task.id == "root:lint" {
    (false, "lint failed")
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
test "workflow engine: entry target executes only transitive dependencies" {
  let nodes = [
    new_node("root", []),
    new_node("dep", ["root"]),
    new_node("extra", []),
  ]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("dep:test", "dep", "test", ["root:build"]),
    new_task("extra:lint", "extra", "lint", []),
  ]
  let ir = new_ir("ci", nodes, tasks, entry_targets=["dep:test"])
  let result = execute_ir(ir, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.order.length(), 2)
  assert_true(result.order.contains("root:build"))
  assert_true(result.order.contains("dep:test"))
  assert_eq(result.order.contains("extra:lint"), false)
}

///|
test "workflow engine: optional task failure keeps workflow completed" {
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let tasks = [
    new_task("root:lint", "root", "lint", [], required=false),
    new_task("dep:test", "dep", "test", [], required=true),
  ]
  let ir = new_ir("ci", nodes, tasks)
  let result = execute_ir(ir, run_optional_fail)
  assert_eq(result.ok, true)
  assert_eq(result.state, "completed")
  let text = result.steps.map(step => step.id + ":" + step.status).join("\n")
  assert_true(text.contains("root:lint:failed"))
  assert_true(text.contains("dep:test:success"))
}

///|
test "workflow engine: execute_ir returns invalid when ir has issues" {
  let nodes = [new_node("root", ["missing"])]
  let tasks = [new_task("root:test", "unknown", "test", ["missing:task"])]
  let ir = new_ir("ci", nodes, tasks, entry_targets=["missing:target"])
  let result = execute_ir(ir, run_ok)
  assert_eq(result.ok, false)
  assert_eq(result.state, "invalid")
  assert_eq(result.steps.length(), 0)
  assert_true(result.issues.length() >= 3)
  let text = result.issues.join("\n")
  assert_true(
    text.contains("node: node 'root' depends on unknown node 'missing'"),
  )
  assert_true(text.contains("targets unknown node"))
  assert_true(text.contains("depends on unknown task"))
  assert_true(text.contains("entry target 'missing:target' does not exist"))
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
test "workflow engine: starlark parser supports cmd array and inline comments" {
  let src =
    #|workflow(name="ci") # inline comment
    #|node(id="root", depends_on=[])
    #|task(id="root:test", node="root", cmd=["just", "test"], needs=[]) # tail comment
    #|entrypoint(targets=["root:test"])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.tasks.length(), 1)
  assert_eq(parsed.ir.tasks[0].cmd, "just test")
  let result = execute_ir(parsed.ir, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.steps.length(), 1)
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
