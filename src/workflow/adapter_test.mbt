///|
test "workflow adapter: command result helpers keep failure semantics" {
  let ok = @workflow.command_success(stdout="done")
  assert_eq(ok.ok(), true)
  assert_eq(ok.stdout, "done")
  let failed = @workflow.command_failure(code=0, stderr="boom")
  assert_eq(failed.code, 1)
  assert_eq(failed.ok(), false)
  assert_eq(failed.stderr, "boom")
}

///|
test "workflow adapter: memory fs read write exists and list paths" {
  let fs = @workflow.FsAdapter::memory_with({ "a.txt": "alpha" })
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
  let nodes = [@workflow.new_node("root", [])]
  let tasks = [
    @workflow.new_task("root:build", "root", "build", []),
    @workflow.new_task("root:test", "root", "test", ["root:build"]),
  ]
  let ir = @workflow.new_ir("ci", nodes, tasks, entry_targets=["root:test"])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::none(),
    @workflow.CommandAdapter::new(fn(
      cmd : String,
      _cwd : String?,
      _env : Map[String, String],
    ) {
      if cmd == "test" {
        @workflow.command_failure(stderr="tests failed")
      } else {
        @workflow.command_success(stdout="ok:" + cmd)
      }
    }),
  )
  let result = @workflow.execute_ir_with_adapter(ir, adapter)
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
  let ir = @workflow.new_ir("ci", [@workflow.new_node("root", [])], [
    @workflow.new_task("root:build", "root", "build", []),
  ])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::none(),
    @workflow.CommandAdapter::new(fn(
      _cmd : String,
      _cwd : String?,
      _env : Map[String, String],
    ) {
      @workflow.command_failure(stdout="stdout failure", stderr="")
    }),
  )
  let result = @workflow.execute_ir_with_adapter(ir, adapter)
  assert_eq(result.ok, false)
  assert_eq(result.state, "partial_failed")
  assert_eq(result.steps.length(), 1)
  assert_eq(result.steps[0].status, "failed")
  assert_eq(result.steps[0].message, "stdout failure")
}

///|
test "workflow adapter: execute_ir_with_adapter passes cwd and env to command adapter" {
  let ir = @workflow.new_ir("ci", [@workflow.new_node("root", [])], [
    @workflow.new_task("root:build", "root", "build", [], cwd="packages/root", env={
      "NODE_ENV": "test",
    }),
  ])
  let seen_cmd : Array[String] = []
  let seen_cwd : Array[String] = []
  let seen_node_env : Array[String] = []
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::none(),
    @workflow.CommandAdapter::new(fn(
      cmd : String,
      cwd : String?,
      env : Map[String, String],
    ) {
      seen_cmd.push(cmd)
      let cwd_text = match cwd {
        Some(path) => path
        None => ""
      }
      seen_cwd.push(cwd_text)
      seen_node_env.push(env.get("NODE_ENV").unwrap_or(""))
      @workflow.command_success(stdout="ok")
    }),
  )
  let result = @workflow.execute_ir_with_adapter(ir, adapter)
  assert_eq(result.ok, true)
  assert_eq(seen_cmd.join(","), "build")
  assert_eq(seen_cwd.join(","), "packages/root")
  assert_eq(seen_node_env.join(","), "test")
}

///|
test "workflow adapter: fs-backed starlark run and report write" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::memory_with({ "workflow.star": src }),
    @workflow.CommandAdapter::new(fn(
      cmd : String,
      _cwd : String?,
      _env : Map[String, String],
    ) {
      @workflow.command_success(stdout="ran:" + cmd)
    }),
  )
  let parsed = @workflow.parse_from_fs("workflow.star", adapter)
  assert_eq(parsed.errors.length(), 0)
  let result = @workflow.execute_from_fs("workflow.star", adapter)
  assert_eq(result.ok, true)
  assert_eq(result.state, "completed")
  assert_eq(
    @workflow.write_execution_report("report.txt", result, adapter),
    true,
  )
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
test "workflow adapter: fs-backed starlark parse accepts external inputs" {
  let src =
    #|var(name="profile", type="string", required=True, default="dev")
    #|workflow(name=profile)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=["echo", profile], needs=[])
    #|entrypoint(targets=["root:build"])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::memory_with({ "workflow.star": src }),
    @workflow.CommandAdapter::none(),
  )
  let parsed = @workflow.parse_from_fs_with_inputs("workflow.star", adapter, {
    "profile": "prod",
  })
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "prod")
  assert_eq(parsed.ir.tasks.length(), 1)
  assert_eq(parsed.ir.tasks[0].cmd, "echo prod")
}

///|
test "workflow adapter: fs-backed starlark execute accepts external inputs" {
  let src =
    #|var(name="profile", type="string", required=True, default="dev")
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=["echo", profile], needs=[])
    #|entrypoint(targets=["root:build"])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::memory_with({ "workflow.star": src }),
    @workflow.CommandAdapter::new(fn(
      cmd : String,
      _cwd : String?,
      _env : Map[String, String],
    ) {
      @workflow.command_success(stdout="ran:" + cmd)
    }),
  )
  let result = @workflow.execute_from_fs_with_inputs("workflow.star", adapter, {
    "profile": "prod",
  })
  assert_eq(result.ok, true)
  assert_eq(result.state, "completed")
  assert_eq(result.steps.length(), 1)
  assert_eq(result.steps[0].message, "ran:echo prod")
}

///|
test "workflow adapter: fs-backed starlark parse accepts cli and env inputs" {
  let src =
    #|var(name="profile", type="string", required=True, default="dev")
    #|workflow(name=profile)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=["echo", profile], needs=[])
    #|entrypoint(targets=["root:build"])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::memory_with({ "workflow.star": src }),
    @workflow.CommandAdapter::none(),
  )
  let parsed = @workflow.parse_from_fs_with_cli_env(
    "workflow.star",
    adapter,
    ["--var=profile=prod"],
    { "BITFLOW_VAR_profile": "dev" },
  )
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "prod")
  assert_eq(parsed.ir.tasks[0].cmd, "echo prod")
}

///|
test "workflow adapter: missing starlark file becomes invalid result" {
  let adapter = @workflow.WorkflowAdapter::none()
  let parsed = @workflow.parse_from_fs("missing.star", adapter)
  assert_eq(parsed.errors.length(), 1)
  assert_true(
    parsed.errors[0].contains("failed to read workflow file: missing.star"),
  )
  let result = @workflow.execute_from_fs("missing.star", adapter)
  assert_eq(result.ok, false)
  assert_eq(result.state, "invalid")
  assert_eq(result.steps.length(), 0)
  assert_eq(result.issues.length(), 1)
  assert_true(result.issues[0].contains("failed to read workflow file"))
}

///|
test "workflow adapter: none fs cannot write report" {
  let ir = @workflow.new_ir("ci", [@workflow.new_node("root", [])], [
    @workflow.new_task("root:build", "root", "build", []),
  ])
  let result = @workflow.execute_ir(ir, fn(_task : @workflow.FlowTask) {
    (true, "")
  })
  assert_eq(
    @workflow.write_execution_report(
      "report.txt",
      result,
      @workflow.WorkflowAdapter::none(),
    ),
    false,
  )
}

///|
test "workflow adapter: starlark load() merges external files from fs" {
  let root_src =
    #|load("defs/common.star", "shared_nodes", task_alias="shared_task")
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:test"])
  let common_src =
    #|node(id="dep", depends_on=["root"])
    #|task(id="root:test", node="dep", cmd="test", needs=["root:build"])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::memory_with({
      "workflow.star": root_src,
      "defs/common.star": common_src,
    }),
    @workflow.CommandAdapter::new(fn(
      cmd : String,
      _cwd : String?,
      _env : Map[String, String],
    ) {
      @workflow.command_success(stdout="ran:" + cmd)
    }),
  )
  let parsed = @workflow.parse_from_fs("workflow.star", adapter)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.nodes.length(), 2)
  assert_eq(parsed.ir.tasks.length(), 2)
  let result = @workflow.execute_from_fs("workflow.star", adapter)
  assert_eq(result.ok, true)
  assert_eq(result.order.length(), 2)
}

///|
test "workflow adapter: starlark load() reports cycle" {
  let root_src =
    #|load("defs/a.star")
  let a_src =
    #|load("../workflow.star")
    #|node(id="a", depends_on=[])
    #|task(id="a:run", node="a", cmd="run", needs=[])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::memory_with({
      "workflow.star": root_src,
      "defs/a.star": a_src,
    }),
    @workflow.CommandAdapter::none(),
  )
  let parsed = @workflow.parse_from_fs("workflow.star", adapter)
  assert_true(parsed.errors.length() > 0)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("load cycle"))
}

///|
test "workflow adapter: starlark load() reports missing file" {
  let root_src =
    #|load("defs/missing.star")
    #|workflow(name="ci")
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::memory_with({ "workflow.star": root_src }),
    @workflow.CommandAdapter::none(),
  )
  let parsed = @workflow.parse_from_fs("workflow.star", adapter)
  assert_true(parsed.errors.length() > 0)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("failed to read loaded file"))
  assert_true(text.contains("defs/missing.star"))
}

///|
test "workflow adapter: starlark load() rejects path outside workspace root" {
  let root_src =
    #|load("../outside.star")
    #|workflow(name="ci")
  let outside_src =
    #|node(id="root", depends_on=[])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::memory_with({
      "workflow.star": root_src,
      "../outside.star": outside_src,
    }),
    @workflow.CommandAdapter::none(),
  )
  let parsed = @workflow.parse_from_fs("workflow.star", adapter)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("load path escapes workspace root"))
}

///|
test "workflow adapter: starlark load() requires path as first argument" {
  let root_src =
    #|load(src="defs/common.star")
    #|workflow(name="ci")
  let common_src =
    #|node(id="dep", depends_on=[])
  let adapter = @workflow.WorkflowAdapter::new(
    @workflow.FsAdapter::memory_with({
      "workflow.star": root_src,
      "defs/common.star": common_src,
    }),
    @workflow.CommandAdapter::none(),
  )
  let parsed = @workflow.parse_from_fs("workflow.star", adapter)
  let text = parsed.errors.join("\n")
  assert_true(
    text.contains("load() first argument must be string path or path=\"...\""),
  )
}
