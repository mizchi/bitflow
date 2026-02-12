///|
fn run_ok(_task : FlowTask) -> (Bool, String) {
  (true, "")
}

///|
struct TaskScenario {
  task_id : String
  ok : Bool
  message : String
}

///|
fn task_scenario_success(
  task_id : String,
  message? : String = "",
) -> TaskScenario {
  { task_id, ok: true, message }
}

///|
fn task_scenario_failure(
  task_id : String,
  message? : String = "task failed",
) -> TaskScenario {
  { task_id, ok: false, message }
}

///|
struct MockTaskRunner {
  run : (FlowTask) -> (Bool, String)
  called_ids : () -> Array[String]
}

///|
fn mock_task_runner(
  scenarios : Array[TaskScenario],
  default_ok? : Bool = true,
  default_message? : String = "",
) -> MockTaskRunner {
  let outcomes : Map[String, (Bool, String)] = {}
  for scenario in scenarios {
    outcomes[scenario.task_id] = (scenario.ok, scenario.message)
  }
  let called : Array[String] = []
  {
    run: fn(task : FlowTask) {
      called.push(task.id)
      match outcomes.get(task.id) {
        Some(result) => result
        None => (default_ok, default_message)
      }
    },
    called_ids: fn() {
      let snapshot : Array[String] = []
      for id in called {
        snapshot.push(id)
      }
      snapshot
    },
  }
}

///|
test "workflow engine: mock runner can describe task outcomes and execution order" {
  let runner = mock_task_runner([
    task_scenario_success("root:build"),
    task_scenario_failure("dep:test", message="dep failed"),
  ])
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("dep:test", "dep", "test", ["root:build"]),
  ]
  let ir = new_ir("ci", nodes, tasks, entry_targets=["dep:test"])
  let result = execute_ir(ir, runner.run)
  assert_eq(result.ok, false)
  assert_eq(result.steps.length(), 2)
  assert_eq(result.steps[0].status, "success")
  assert_eq(result.steps[1].status, "failed")
  assert_eq((runner.called_ids)().join(","), "root:build,dep:test")
}

///|
fn trim_ascii_space(s : String) -> String {
  let mut start = 0
  let mut end = s.length()
  while start < end {
    let ch = s.unsafe_get(start)
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let ch = s.unsafe_get(end - 1)
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == s.length() {
    s
  } else {
    String::unsafe_substring(s, start~, end~)
  }
}

///|
fn parse_chunk_expected_literal(raw : String) -> String? {
  let text = trim_ascii_space(raw)
  if text.length() < 2 {
    return None
  }
  if text.has_prefix("\"") && text.has_suffix("\"") {
    return Some(String::unsafe_substring(text, start=1, end=text.length() - 1))
  }
  let first = text.unsafe_get(0)
  let last = text.unsafe_get(text.length() - 1)
  if first.to_int() == 96 && last.to_int() == 96 {
    return Some(String::unsafe_substring(text, start=1, end=text.length() - 1))
  }
  None
}

///|
fn parse_chunk_source_line(line : String) -> (String, String?) {
  match line.find("###") {
    Some(idx) => {
      let code = trim_ascii_space(
        String::unsafe_substring(line, start=0, end=idx),
      )
      let expected_text = String::unsafe_substring(
        line,
        start=idx + 3,
        end=line.length(),
      )
      (code, parse_chunk_expected_literal(expected_text))
    }
    None => (trim_ascii_space(line), None)
  }
}

///|
fn parse_starlark_go_chunked_cases(text : String) -> Array[(String, String?)] {
  let lines : Array[String] = []
  for view in text.split("\n") {
    lines.push(view.to_string())
  }
  // Sentinel delimiter to flush last case.
  lines.push("---")

  let cases : Array[(String, String?)] = []
  let mut current_lines : Array[String] = []
  let mut current_expected : String? = None

  for raw_line in lines {
    let trimmed = trim_ascii_space(raw_line)
    if trimmed == "---" {
      if current_lines.length() > 0 {
        cases.push((current_lines.join("\n"), current_expected))
      }
      current_lines = []
      current_expected = None
      continue
    }
    if trimmed.length() == 0 {
      continue
    }
    if trimmed.has_prefix("#") && raw_line.find("###") is None {
      continue
    }
    let (code, expected) = parse_chunk_source_line(raw_line)
    if code.length() > 0 {
      current_lines.push(code)
    }
    match expected {
      Some(value) => current_expected = Some(value)
      None => ()
    }
  }
  cases
}

///|
fn starlark_go_errors_subset_chunked_embedded() -> String {
  let text =
    #|# source=embedded-fallback
    #|workflow(1+2 = 3) ### "keyword argument must have form name=expr"
    #|---
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", *, needs=[]) ### "splat arguments are not supported"
    #|---
    #|workflow(name="ci",
    #|### "expected ')' to close argument list"
    #|---
    #|workflow(name="ci",)
    #|node(id="root", depends_on=[],)
    #|task(id="root:build", node="root", cmd="build", needs=[],)
    #|entrypoint(targets=["root:build"],)
    #|---
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="\x-0", needs=[]) ### "invalid escape sequence"
  text
}

///|
#cfg(target="js")
extern "js" fn read_starlark_go_errors_subset_from_fs() -> String? =
  #| function() {
  #|   try {
  #|     const fs = require("node:fs");
  #|     const path = require("node:path");
  #|     const cwd = (typeof process !== "undefined" && typeof process.cwd === "function")
  #|       ? process.cwd()
  #|       : ".";
  #|     const candidates = [
  #|       path.join(cwd, "src/workflow/testdata/starlark_go_errors_subset.star"),
  #|       path.join(cwd, "../src/workflow/testdata/starlark_go_errors_subset.star"),
  #|       path.join(cwd, "../../src/workflow/testdata/starlark_go_errors_subset.star"),
  #|       "src/workflow/testdata/starlark_go_errors_subset.star",
  #|     ];
  #|     for (const p of candidates) {
  #|       if (fs.existsSync(p)) {
  #|         return fs.readFileSync(p, "utf8");
  #|       }
  #|     }
  #|     return null;
  #|   } catch (_err) {
  #|     return null;
  #|   }
  #| }

///|
#cfg(target="js")
fn starlark_go_errors_subset_chunked() -> String {
  let fallback = starlark_go_errors_subset_chunked_embedded()
  match read_starlark_go_errors_subset_from_fs() {
    Some(text) => text
    None => fallback
  }
}

///|
#cfg(not(target="js"))
fn starlark_go_errors_subset_chunked() -> String {
  starlark_go_errors_subset_chunked_embedded()
}

///|
#cfg(target="js")
fn expected_starlark_go_errors_source_marker() -> String {
  "# source=external-file"
}

///|
#cfg(not(target="js"))
fn expected_starlark_go_errors_source_marker() -> String {
  "# source=embedded-fallback"
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
  let runner = mock_task_runner([
    task_scenario_failure("dep:test", message="dep failed"),
  ])
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
  let result = execute_ir(ir, runner.run)
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
  let runner = mock_task_runner([
    task_scenario_failure("root:lint", message="lint failed"),
  ])
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let tasks = [
    new_task("root:lint", "root", "lint", [], required=false),
    new_task("dep:test", "dep", "test", [], required=true),
  ]
  let ir = new_ir("ci", nodes, tasks)
  let result = execute_ir(ir, runner.run)
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
test "workflow engine: ir issues reports non-positive max_parallel" {
  let ir = new_ir(
    "ci",
    [new_node("root", [])],
    [new_task("root:build", "root", "build", [])],
    max_parallel=0,
  )
  let issues = ir_issues(ir)
  let text = issues.join("\n")
  assert_true(text.contains("workflow.max_parallel must be positive"))
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
test "workflow engine: starlark task supports srcs outs cwd and trigger" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(
    #|  id="root:build",
    #|  node="root",
    #|  cmd=["pnpm", "build"],
    #|  needs=[],
    #|  srcs=["packages/root/**", "pnpm-lock.yaml"],
    #|  outs=["packages/root/dist/**"],
    #|  cwd="packages/root",
    #|  trigger="manual",
    #|)
    #|entrypoint(targets=["root:build"])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.tasks.length(), 1)
  let task = parsed.ir.tasks[0]
  assert_eq(task.srcs.length(), 2)
  assert_eq(task.srcs[0], "packages/root/**")
  assert_eq(task.outs.length(), 1)
  assert_eq(task.outs[0], "packages/root/dist/**")
  assert_eq(task.cwd, "packages/root")
  assert_eq(task.trigger_mode, "manual")
}

///|
test "workflow engine: starlark target alias maps to task semantics" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|target(
    #|  id="root:build",
    #|  node="root",
    #|  cmd=["pnpm", "build"],
    #|  needs=[],
    #|  srcs=["packages/root/**"],
    #|)
    #|entrypoint(targets=["root:build"])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.tasks.length(), 1)
  let task = parsed.ir.tasks[0]
  assert_eq(task.id, "root:build")
  assert_eq(task.cmd, "pnpm build")
  assert_eq(task.srcs.length(), 1)
  assert_eq(task.srcs[0], "packages/root/**")
}

///|
test "workflow engine: starlark task supports env dict" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(
    #|  id="root:build",
    #|  node="root",
    #|  cmd="build",
    #|  needs=[],
    #|  env={"NODE_ENV": "test", "CI": "1"},
    #|)
    #|entrypoint(targets=["root:build"])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.tasks.length(), 1)
  let env = parsed.ir.tasks[0].env
  assert_eq(env.get("NODE_ENV"), Some("test"))
  assert_eq(env.get("CI"), Some("1"))
}

///|
test "workflow engine: starlark task env rejects non-string value" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(
    #|  id="root:build",
    #|  node="root",
    #|  cmd="build",
    #|  needs=[],
    #|  env={"CI": 1},
    #|)
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("task.env must be {string:string}"))
}

///|
test "workflow engine: starlark assignment binds and references values" {
  let src =
    #|workflow_name = "ci"
    #|target_id = "root:build"
    #|target_node = "root"
    #|build_cmd = ["pnpm", "build"]
    #|task_srcs = ["packages/root/**"]
    #|task_env = {"NODE_ENV": "test", "CI": "1"}
    #|workflow(name=workflow_name)
    #|node(id=target_node, depends_on=[])
    #|task(id=target_id, node=target_node, cmd=build_cmd, needs=[], srcs=task_srcs, env=task_env)
    #|entry_targets = [target_id]
    #|entrypoint(targets=entry_targets)
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "ci")
  assert_eq(parsed.ir.entry_targets.length(), 1)
  assert_eq(parsed.ir.entry_targets[0], "root:build")
  assert_eq(parsed.ir.tasks.length(), 1)
  let task = parsed.ir.tasks[0]
  assert_eq(task.cmd, "pnpm build")
  assert_eq(task.srcs.length(), 1)
  assert_eq(task.srcs[0], "packages/root/**")
  assert_eq(task.env.get("NODE_ENV"), Some("test"))
}

///|
test "workflow engine: starlark assignment reports unknown variable reference" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=unknown_cmd, needs=[])
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("unknown variable 'unknown_cmd'"))
}

///|
test "workflow engine: starlark var binds default value by name" {
  let src =
    #|var(name="workflow_name", default="ci")
    #|var(name="node_id", default="root")
    #|var(name="task_id", default="root:build")
    #|var(name="task_cmd", default=["pnpm", "build"])
    #|var(name="task_env", default={"NODE_ENV": "test"})
    #|workflow(name=workflow_name)
    #|node(id=node_id, depends_on=[])
    #|task(id=task_id, node=node_id, cmd=task_cmd, needs=[], env=task_env)
    #|entrypoint(targets=[task_id])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "ci")
  assert_eq(parsed.ir.tasks.length(), 1)
  let task = parsed.ir.tasks[0]
  assert_eq(task.cmd, "pnpm build")
  assert_eq(task.env.get("NODE_ENV"), Some("test"))
}

///|
test "workflow engine: starlark config overrides var binding" {
  let src =
    #|var(name="profile", default="dev")
    #|config(name="profile", value="prod")
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=["echo", profile], needs=[], env={"PROFILE": profile})
    #|entrypoint(targets=["root:build"])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.tasks.length(), 1)
  let task = parsed.ir.tasks[0]
  assert_eq(task.cmd, "echo prod")
  assert_eq(task.env.get("PROFILE"), Some("prod"))
}

///|
test "workflow engine: starlark var type enforces default and config values" {
  let src =
    #|var(name="retries", type="int", default=1)
    #|config(name="retries", value=3)
    #|workflow(name="ci", max_parallel=retries)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.max_parallel, 3)
  assert_eq(parsed.ir.tasks.length(), 1)
  assert_eq(parsed.ir.tasks[0].cmd, "build")
}

///|
test "workflow engine: starlark var type rejects default mismatch" {
  let src =
    #|var(name="retries", type="int", default="1")
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("var.default must match type 'int'"))
}

///|
test "workflow engine: starlark var type rejects config mismatch" {
  let src =
    #|var(name="retries", type="int", default=1)
    #|config(name="retries", value="3")
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("config.value for 'retries' must match type 'int'"))
}

///|
test "workflow engine: starlark var type rejects unknown type name" {
  let src =
    #|var(name="mode", type="unknown", default="dev")
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("var.type must be one of"))
}

///|
test "workflow engine: starlark config requires declared var" {
  let src =
    #|config(name="mode", value="prod")
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("config.name 'mode' is not declared by var()"))
}

///|
test "workflow engine: starlark required var can be injected by external inputs" {
  let src =
    #|var(name="profile", type="string", required=True, default="dev")
    #|workflow(name=profile)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=["echo", profile], needs=[])
    #|entrypoint(targets=["root:build"])
  let parsed = parse_starlark_subset_with_inputs(src, { "profile": "prod" })
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "prod")
  assert_eq(parsed.ir.tasks.length(), 1)
  assert_eq(parsed.ir.tasks[0].cmd, "echo prod")
}

///|
test "workflow engine: starlark required var allows missing default with external input" {
  let src =
    #|var(name="profile", type="string", required=True)
    #|workflow(name=profile)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=["echo", profile], needs=[])
    #|entrypoint(targets=["root:build"])
  let parsed = parse_starlark_subset_with_inputs(src, { "profile": "prod" })
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "prod")
  assert_eq(parsed.ir.tasks[0].cmd, "echo prod")
}

///|
test "workflow engine: starlark required var reports error when unresolved" {
  let src =
    #|var(name="profile", type="string", required=True, default="dev")
    #|workflow(name=profile)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=["echo", profile], needs=[])
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("required var 'profile' must be provided"))
}

///|
test "workflow engine: starlark non-required var without default reports semantic error" {
  let src =
    #|var(name="profile")
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(
    text.contains("var.default is required when var.required is false"),
  )
}

///|
test "workflow engine: starlark unresolved var default does not emit required-var noise" {
  let src =
    #|var(name="profile", required=True, default=unknown_profile)
    #|workflow(name="ci")
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("unknown variable 'unknown_profile'"))
  assert_eq(
    text.contains(
      "required var 'profile' must be provided by config() or external inputs",
    ),
    false,
  )
}

///|
test "workflow engine: starlark required var is resolved by config override" {
  let src =
    #|var(name="profile", type="string", required=True, default="dev")
    #|config(name="profile", value="prod")
    #|workflow(name=profile)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=["echo", profile], needs=[])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "prod")
  assert_eq(parsed.ir.tasks[0].cmd, "echo prod")
}

///|
test "workflow engine: starlark config before var reports declaration-order error" {
  let src =
    #|config(name="profile", value="prod")
    #|var(name="profile", default="dev")
    #|workflow(name=profile)
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("config.name 'profile' is not declared by var()"))
}

///|
test "workflow engine: starlark external inputs follow var type conversion" {
  let src =
    #|var(name="retries", type="int", required=True, default=1)
    #|var(name="enable_cache", type="bool", required=True, default=False)
    #|var(name="labels", type="string_list", required=True, default=["dev"])
    #|var(name="env_map", type="string_dict", required=True, default={"NODE_ENV": "dev"})
    #|workflow(name="ci", max_parallel=retries)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd=labels, needs=[], env=env_map, required=enable_cache)
  let parsed = parse_starlark_subset_with_inputs(src, {
    "retries": "3",
    "enable_cache": "true",
    "labels": "prod,release",
    "env_map": "NODE_ENV=prod,CI=1",
  })
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.max_parallel, 3)
  assert_eq(parsed.ir.tasks[0].cmd, "prod release")
  assert_eq(parsed.ir.tasks[0].required, true)
  assert_eq(parsed.ir.tasks[0].env.get("NODE_ENV"), Some("prod"))
  assert_eq(parsed.ir.tasks[0].env.get("CI"), Some("1"))
}

///|
test "workflow engine: starlark external input conversion reports type errors" {
  let src =
    #|var(name="retries", type="int", required=True, default=1)
  let parsed = parse_starlark_subset_with_inputs(src, { "retries": "abc" })
  let text = parsed.errors.join("\n")
  assert_true(text.contains("external input for 'retries' must be int"))
}

///|
test "workflow engine: parse_external_inputs merges env and cli with cli precedence" {
  let result = parse_external_inputs(
    ["--var", "profile=prod", "--var=retries=3"],
    { "BITFLOW_VAR_profile": "dev", "BITFLOW_VAR_node_id": "root" },
  )
  assert_eq(result.errors.length(), 0)
  assert_eq(result.values.get("profile"), Some("prod"))
  assert_eq(result.values.get("retries"), Some("3"))
  assert_eq(result.values.get("node_id"), Some("root"))
}

///|
test "workflow engine: parse_external_inputs reports malformed cli and env entries" {
  let result = parse_external_inputs(
    ["--var", "broken", "--var=novalue", "--var"],
    { "BITFLOW_VAR_": "x" },
  )
  let text = result.errors.join("\n")
  assert_true(text.contains("expects key=value"))
  assert_true(text.contains("must be key=value"))
  assert_true(text.contains("env var key is empty"))
}

///|
test "workflow engine: parse_external_inputs trims cli key and value" {
  let result = parse_external_inputs(["--var", " profile = prod "], {})
  assert_eq(result.errors.length(), 0)
  assert_eq(result.values.get("profile"), Some("prod"))
}

///|
test "workflow engine: starlark reports unknown external input key" {
  let src =
    #|var(name="profile", default="dev")
    #|workflow(name=profile)
  let parsed = parse_starlark_subset_with_inputs(src, {
    "profile": "prod",
    "profiel": "typo",
  })
  let text = parsed.errors.join("\n")
  assert_true(
    text.contains("external input 'profiel' is not declared by var()"),
  )
}

///|
test "workflow engine: parse_starlark_subset_with_cli_env injects vars" {
  let src =
    #|var(name="profile", type="string", required=True, default="dev")
    #|workflow(name=profile)
  let parsed = parse_starlark_subset_with_cli_env(src, ["--var=profile=prod"], {})
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "prod")
}

///|
test "workflow engine: changed paths selects auto targets and executes dependencies" {
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let tasks = [
    new_task(
      "root:build",
      "root",
      "build",
      [],
      srcs=["packages/root/**"],
      trigger_mode="auto",
    ),
    new_task(
      "dep:test",
      "dep",
      "test",
      ["root:build"],
      srcs=["packages/dep/**"],
      trigger_mode="manual",
    ),
    new_task(
      "dep:lint",
      "dep",
      "lint",
      ["root:build"],
      srcs=["packages/dep/**"],
      trigger_mode="auto",
    ),
  ]
  let ir = new_ir("ci", nodes, tasks)
  let changed = ["packages/dep/src/main.ts"]
  let targets = entry_targets_for_changed_paths(ir, changed)
  assert_eq(targets.contains("dep:lint"), true)
  assert_eq(targets.contains("dep:test"), false)
  let result = execute_ir_for_changed_paths(ir, changed, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.order.length(), 2)
  assert_eq(result.order[0], "root:build")
  assert_eq(result.order[1], "dep:lint")
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

///|
test "workflow engine: starlark compatibility accepts semicolon separated calls" {
  let src =
    #|workflow(name='ci'); node(id='root', depends_on=[]); task(id='root:build', node='root', cmd='build', needs=[]); entrypoint(targets=['root:build'])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "ci")
  assert_eq(parsed.ir.nodes.length(), 1)
  assert_eq(parsed.ir.tasks.length(), 1)
  assert_eq(parsed.ir.entry_targets.length(), 1)
}

///|
test "workflow engine: starlark compatibility accepts trailing comma in call args" {
  let src =
    #|workflow(name="ci",)
    #|node(id="root", depends_on=[],)
    #|task(id="root:test", node="root", cmd=["just", "test",], needs=[],)
    #|entrypoint(targets=["root:test"],)
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.tasks.length(), 1)
  assert_eq(parsed.ir.tasks[0].cmd, "just test")
}

///|
test "workflow engine: starlark compatibility supports single quote and bool literal" {
  let src =
    #|workflow(name='ci')
    #|node(id='root', depends_on=[], required=False)
    #|task(id='root:lint', node='root', cmd='lint', needs=[], required=True)
    #|entrypoint(targets=['root:lint'])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.nodes.length(), 1)
  assert_eq(parsed.ir.nodes[0].required, false)
  assert_eq(parsed.ir.tasks[0].required, true)
}

///|
test "workflow engine: starlark semantics rejects unknown keyword argument" {
  let src =
    #|workflow(name="ci", unknown=1)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("unknown argument"))
}

///|
test "workflow engine: starlark semantics rejects duplicate keyword argument" {
  let src =
    #|workflow(name="ci", name="prod")
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("duplicate argument"))
}

///|
test "workflow engine: starlark semantics validates list element types" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|node(id="dep", depends_on=["root", 1])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|task(id="dep:test", node="dep", cmd="test", needs=["root:build"])
    #|entrypoint(targets=["dep:test"])
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("depends_on"))
}

///|
test "workflow engine: starlark compatibility rejects splat arguments" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", *, needs=[])
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("splat arguments"))
}

///|
test "workflow engine: starlark compatibility requires name=expr keyword syntax" {
  let src =
    #|workflow(1+2 = 3)
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("keyword argument must have form name=expr"))
}

///|
test "workflow engine: starlark-go errors.star failure subset" {
  // Derived from google/starlark-go/syntax/testdata/errors.star
  let case_keyword_arg =
    #|workflow(1+2 = 3)
  let case_splat =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", *, needs=[])
  let case_invalid_escape =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="\x-0", needs=[])
  let case_unclosed_paren =
    #|workflow(name="ci",
  let cases = [
    (case_keyword_arg, "keyword argument must have form name=expr"),
    (case_splat, "splat arguments are not supported"),
    (case_invalid_escape, "invalid escape sequence"),
    (case_unclosed_paren, "expected ')' to close argument list"),
  ]
  for entry in cases {
    let (source, expected) = entry
    let parsed = parse_starlark_subset(source)
    let text = parsed.errors.join("\n")
    assert_true(text.contains(expected))
  }
}

///|
test "workflow engine: starlark-go errors.star trailing comma subset" {
  // Equivalent to "f(a,)" style trailing comma acceptance in errors.star
  let case_trailing_comma_a =
    #|workflow(name="ci",)
    #|node(id="root", depends_on=[],)
    #|task(id="root:build", node="root", cmd="build", needs=[],)
    #|entrypoint(targets=["root:build"],)
  let case_trailing_comma_b =
    #|workflow(name='ci',)
    #|node(id='root', depends_on=['dep',],)
    #|task(id='root:build', node='root', cmd=['just', 'test',], needs=[],)
    #|entrypoint(targets=['root:build',],)
  let cases = [case_trailing_comma_a, case_trailing_comma_b]
  for source in cases {
    let parsed = parse_starlark_subset(source)
    assert_eq(parsed.errors.length(), 0)
  }
}

///|
test "workflow engine: starlark-go chunked errors subset is executable" {
  let chunked_text = starlark_go_errors_subset_chunked()
  let source_marker = expected_starlark_go_errors_source_marker()
  assert_true(chunked_text.contains(source_marker))
  let cases = parse_starlark_go_chunked_cases(chunked_text)
  assert_eq(cases.length(), 5)
  for entry in cases {
    let (source, expected) = entry
    let parsed = parse_starlark_subset(source)
    match expected {
      Some(msg) => assert_true(parsed.errors.join("\n").contains(msg))
      None => assert_eq(parsed.errors.length(), 0)
    }
  }
}
