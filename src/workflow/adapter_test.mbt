///|
test "workflow adapter: command result helpers keep failure semantics" {
  let ok = command_success(stdout="done")
  assert_eq(ok.ok(), true)
  assert_eq(ok.stdout, "done")
  let failed = command_failure(code=0, stderr="boom")
  assert_eq(failed.code, 1)
  assert_eq(failed.ok(), false)
  assert_eq(failed.stderr, "boom")
}

///|
test "workflow adapter: memory fs read write exists and list paths" {
  let fs = FsAdapter::memory_with({ "a.txt": "alpha" })
  assert_eq((fs.read_text)("a.txt"), Some("alpha"))
  assert_eq((fs.exists)("a.txt"), true)
  assert_eq((fs.write_text)("b.txt", "beta"), true)
  assert_eq((fs.read_text)("b.txt"), Some("beta"))
  let paths = (fs.list_paths)()
  assert_true(paths.contains("a.txt"))
  assert_true(paths.contains("b.txt"))
}

///|
test "workflow adapter: execute_ir_with_adapter propagates command results" {
  let nodes = [new_node("root", [])]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("root:test", "root", "test", ["root:build"]),
  ]
  let ir = new_ir("ci", nodes, tasks, entry_targets=["root:test"])
  let adapter = WorkflowAdapter::new(
    FsAdapter::none(),
    CommandAdapter::new(fn(cmd : String, _cwd : String?) {
      if cmd == "test" {
        command_failure(stderr="tests failed")
      } else {
        command_success(stdout="ok:" + cmd)
      }
    }),
  )
  let result = execute_ir_with_adapter(ir, adapter)
  assert_eq(result.ok, false)
  assert_eq(result.state, "partial_failed")
  assert_eq(result.steps.length(), 2)
  assert_eq(result.steps[0].status, "success")
  assert_eq(result.steps[0].message, "ok:build")
  assert_eq(result.steps[1].status, "failed")
  assert_eq(result.steps[1].message, "tests failed")
}

///|
test "workflow adapter: failure message falls back to stdout when stderr is empty" {
  let ir = new_ir("ci", [new_node("root", [])], [
    new_task("root:build", "root", "build", []),
  ])
  let adapter = WorkflowAdapter::new(
    FsAdapter::none(),
    CommandAdapter::new(fn(_cmd : String, _cwd : String?) {
      command_failure(stdout="stdout failure", stderr="")
    }),
  )
  let result = execute_ir_with_adapter(ir, adapter)
  assert_eq(result.ok, false)
  assert_eq(result.state, "partial_failed")
  assert_eq(result.steps.length(), 1)
  assert_eq(result.steps[0].status, "failed")
  assert_eq(result.steps[0].message, "stdout failure")
}

///|
test "workflow adapter: fs-backed starlark run and report write" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let adapter = WorkflowAdapter::new(
    FsAdapter::memory_with({ "workflow.star": src }),
    CommandAdapter::new(fn(cmd : String, _cwd : String?) {
      command_success(stdout="ran:" + cmd)
    }),
  )
  let parsed = parse_starlark_subset_from_fs("workflow.star", adapter)
  assert_eq(parsed.errors.length(), 0)
  let result = execute_starlark_subset_from_fs("workflow.star", adapter)
  assert_eq(result.ok, true)
  assert_eq(result.state, "completed")
  assert_eq(write_execution_report("report.txt", result, adapter), true)
  let report = (adapter.fs.read_text)("report.txt")
  assert_true(report is Some(_))
  match report {
    Some(text) => {
      assert_true(text.contains("state=completed"))
      assert_true(text.contains("root:build:success:ran:build"))
    }
    None => assert_true(false)
  }
}

///|
test "workflow adapter: missing starlark file becomes invalid result" {
  let adapter = WorkflowAdapter::none()
  let parsed = parse_starlark_subset_from_fs("missing.star", adapter)
  assert_eq(parsed.errors.length(), 1)
  assert_true(
    parsed.errors[0].contains("failed to read workflow file: missing.star"),
  )
  let result = execute_starlark_subset_from_fs("missing.star", adapter)
  assert_eq(result.ok, false)
  assert_eq(result.state, "invalid")
  assert_eq(result.steps.length(), 0)
  assert_eq(result.issues.length(), 1)
  assert_true(result.issues[0].contains("failed to read workflow file"))
}

///|
test "workflow adapter: none fs cannot write report" {
  let ir = new_ir("ci", [new_node("root", [])], [
    new_task("root:build", "root", "build", []),
  ])
  let result = execute_ir(ir, fn(_task : FlowTask) { (true, "") })
  assert_eq(
    write_execution_report("report.txt", result, WorkflowAdapter::none()),
    false,
  )
}
