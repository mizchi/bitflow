///|
pub struct FlowTask {
  id : String
  node : String
  cmd : String
  needs : Array[String]
  required : Bool
}

///|
pub struct FlowIr {
  name : String
  max_parallel : Int
  nodes : Array[FlowNode]
  tasks : Array[FlowTask]
  entry_targets : Array[String]
}

///|
pub struct FlowStep {
  id : String
  status : String
  required : Bool
  message : String
}

///|
pub struct FlowExecutionResult {
  ok : Bool
  state : String
  order : Array[String]
  steps : Array[FlowStep]
  issues : Array[String]
}

///|
pub struct StarlarkParseResult {
  ir : FlowIr
  errors : Array[String]
}

///|
pub fn new_task(
  id : String,
  node : String,
  cmd : String,
  needs : Array[String],
  required? : Bool = true,
) -> FlowTask {
  { id, node, cmd, needs, required }
}

///|
pub fn new_ir(
  name : String,
  nodes : Array[FlowNode],
  tasks : Array[FlowTask],
  entry_targets? : Array[String] = [],
  max_parallel? : Int = 1,
) -> FlowIr {
  { name, max_parallel, nodes, tasks, entry_targets }
}

///|
fn task_node_map(tasks : Array[FlowTask]) -> Map[String, FlowTask] {
  let result : Map[String, FlowTask] = {}
  for task in tasks {
    result[task.id] = task
  }
  result
}

///|
fn task_as_graph_nodes(tasks : Array[FlowTask]) -> Array[FlowNode] {
  let nodes : Array[FlowNode] = []
  for task in tasks {
    nodes.push(new_node(task.id, task.needs, required=task.required))
  }
  nodes
}

///|
fn selected_task_set(ir : FlowIr) -> Map[String, Bool] {
  let selected : Map[String, Bool] = {}
  if ir.entry_targets.length() == 0 {
    for task in ir.tasks {
      selected[task.id] = true
    }
    return selected
  }
  let task_map = task_node_map(ir.tasks)
  let stack : Array[String] = []
  for target in ir.entry_targets {
    stack.push(target)
  }
  while stack.length() > 0 {
    let id = stack.pop().unwrap_or("")
    if id.length() == 0 || selected.get(id) is Some(_) {
      continue
    }
    selected[id] = true
    match task_map.get(id) {
      Some(task) =>
        for dep in task.needs {
          stack.push(dep)
        }
      None => ()
    }
  }
  selected
}

///|
pub fn ir_issues(ir : FlowIr) -> Array[String] {
  let issues : Array[String] = []
  for issue in graph_issues(ir.nodes) {
    issues.push("node: " + issue)
  }
  let seen_task_ids : Map[String, Bool] = {}
  let known_node_ids = node_id_set(ir.nodes)
  for task in ir.tasks {
    if task.id.length() == 0 {
      issues.push("task id is empty")
    } else if seen_task_ids.get(task.id) is Some(_) {
      issues.push("duplicate task id '\{task.id}'")
    } else {
      seen_task_ids[task.id] = true
    }
    if known_node_ids.get(task.node) is None {
      issues.push("task '\{task.id}' targets unknown node '\{task.node}'")
    }
  }
  let known_task_ids = task_node_map(ir.tasks)
  for task in ir.tasks {
    for dep in task.needs {
      if known_task_ids.get(dep) is None {
        issues.push("task '\{task.id}' depends on unknown task '\{dep}'")
      }
    }
  }
  let task_graph = task_as_graph_nodes(ir.tasks)
  if has_dependency_cycle(task_graph) {
    issues.push("task graph has a cycle")
  }
  for target in ir.entry_targets {
    if known_task_ids.get(target) is None {
      issues.push("entry target '\{target}' does not exist")
    }
  }
  issues
}

///|
pub fn execute_ir(
  ir : FlowIr,
  run_task : (FlowTask) -> (Bool, String),
) -> FlowExecutionResult {
  let issues = ir_issues(ir)
  if issues.length() > 0 {
    return { ok: false, state: "invalid", order: [], steps: [], issues }
  }
  let selected = selected_task_set(ir)
  let task_map = task_node_map(ir.tasks)
  let ordered = topological_nodes(task_as_graph_nodes(ir.tasks))
  let steps : Array[FlowStep] = []
  let order : Array[String] = []
  let success : Map[String, Bool] = {}
  let mut required_failed = false
  for task_node in ordered {
    let id = task_node.id
    if selected.get(id) is None {
      continue
    }
    order.push(id)
    guard task_map.get(id) is Some(task) else { continue }
    let blocked_deps : Array[String] = []
    for dep in task.needs {
      if selected.get(dep) is None {
        continue
      }
      if not(success.get(dep).unwrap_or(false)) {
        blocked_deps.push(dep)
      }
    }
    if blocked_deps.length() > 0 {
      steps.push({
        id: task.id,
        status: "blocked",
        required: task.required,
        message: "blocked by dependency: " + blocked_deps.join(", "),
      })
      success[task.id] = false
      if task.required {
        required_failed = true
      }
      continue
    }
    let (ok, message) = run_task(task)
    if ok {
      steps.push({
        id: task.id,
        status: "success",
        required: task.required,
        message,
      })
      success[task.id] = true
    } else {
      steps.push({
        id: task.id,
        status: "failed",
        required: task.required,
        message: if message.length() == 0 {
          "task failed"
        } else {
          message
        },
      })
      success[task.id] = false
      if task.required {
        required_failed = true
      }
    }
  }
  {
    ok: not(required_failed),
    state: if required_failed {
      "partial_failed"
    } else {
      "completed"
    },
    order,
    steps,
    issues: [],
  }
}

///|
pub fn parse_starlark_subset(text : String) -> StarlarkParseResult {
  parse_starlark_subset_impl(text)
}

///|
pub fn execute_starlark_subset(
  text : String,
  run_task : (FlowTask) -> (Bool, String),
) -> FlowExecutionResult {
  let parsed = parse_starlark_subset(text)
  if parsed.errors.length() > 0 {
    return {
      ok: false,
      state: "invalid",
      order: [],
      steps: [],
      issues: parsed.errors,
    }
  }
  execute_ir(parsed.ir, run_task)
}

///|
fn command_result_message(result : CommandResult) -> String {
  if result.ok() {
    result.stdout
  } else if result.stderr.length() > 0 {
    result.stderr
  } else {
    result.stdout
  }
}

///|
pub fn execute_ir_with_adapter(
  ir : FlowIr,
  adapter : WorkflowAdapter,
) -> FlowExecutionResult {
  execute_ir(ir, fn(task : FlowTask) {
    let result = (adapter.cmd.run)(task.cmd, None)
    (result.ok(), command_result_message(result))
  })
}

///|
pub fn parse_starlark_subset_from_fs(
  path : String,
  adapter : WorkflowAdapter,
) -> StarlarkParseResult {
  parse_starlark_subset_from_fs_impl(path, adapter)
}

///|
pub fn execute_starlark_subset_from_fs(
  path : String,
  adapter : WorkflowAdapter,
) -> FlowExecutionResult {
  let parsed = parse_starlark_subset_from_fs(path, adapter)
  if parsed.errors.length() > 0 {
    return {
      ok: false,
      state: "invalid",
      order: [],
      steps: [],
      issues: parsed.errors,
    }
  }
  execute_ir_with_adapter(parsed.ir, adapter)
}

///|
fn render_execution_report(result : FlowExecutionResult) -> String {
  let buf = StringBuilder::new()
  buf.write_string("state=")
  buf.write_string(result.state)
  buf.write_string("\n")
  buf.write_string("ok=")
  buf.write_string(if result.ok { "true" } else { "false" })
  buf.write_string("\n")
  for step in result.steps {
    buf.write_string(step.id)
    buf.write_string(":")
    buf.write_string(step.status)
    if step.message.length() > 0 {
      buf.write_string(":")
      buf.write_string(step.message)
    }
    buf.write_string("\n")
  }
  if result.issues.length() > 0 {
    for issue in result.issues {
      buf.write_string("issue:")
      buf.write_string(issue)
      buf.write_string("\n")
    }
  }
  buf.to_string()
}

///|
pub fn write_execution_report(
  path : String,
  result : FlowExecutionResult,
  adapter : WorkflowAdapter,
) -> Bool {
  (adapter.fs.write_text)(path, render_execution_report(result))
}
