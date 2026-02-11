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
fn trim_string(s : String) -> String {
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
fn strip_comment(raw : String) -> String {
  let mut in_string = false
  let mut escaped = false
  for i in 0..<raw.length() {
    let ch = raw.unsafe_get(i)
    if escaped {
      escaped = false
      continue
    }
    if ch == '\\' {
      escaped = true
      continue
    }
    if ch == '"' {
      in_string = not(in_string)
      continue
    }
    if ch == '#' && not(in_string) {
      return String::unsafe_substring(raw, start=0, end=i)
    }
  }
  raw
}

///|
fn parse_string_literal(raw : String) -> String? {
  let text = trim_string(raw)
  if text.length() < 2 {
    return None
  }
  if not(text.has_prefix("\"")) || not(text.has_suffix("\"")) {
    return None
  }
  let inner = String::unsafe_substring(text, start=1, end=text.length() - 1)
  let unescaped = inner
    .replace_all(old="\\\"", new="\"")
    .replace_all(old="\\\\", new="\\")
  Some(unescaped)
}

///|
fn parse_bool_literal(raw : String, default : Bool) -> Bool {
  let text = trim_string(raw).to_lower()
  if text == "true" {
    true
  } else if text == "false" {
    false
  } else {
    default
  }
}

///|
fn parse_int_literal(raw : String, default : Int) -> Int {
  let text = trim_string(raw)
  if text.length() == 0 {
    return default
  }
  let mut result = 0
  for i in 0..<text.length() {
    let c = text.unsafe_get(i)
    if c < '0' || c > '9' {
      return default
    }
    result = result * 10 + (c.to_int() - '0'.to_int())
  }
  result
}

///|
fn split_top_level_csv(raw : String) -> Array[String] {
  let parts : Array[String] = []
  let mut start = 0
  let mut bracket_depth = 0
  let mut in_string = false
  let mut escaped = false
  for i in 0..<raw.length() {
    let ch = raw.unsafe_get(i)
    if escaped {
      escaped = false
      continue
    }
    if ch == '\\' {
      escaped = true
      continue
    }
    if ch == '"' {
      in_string = not(in_string)
      continue
    }
    if in_string {
      continue
    }
    if ch == '[' {
      bracket_depth += 1
      continue
    }
    if ch == ']' && bracket_depth > 0 {
      bracket_depth -= 1
      continue
    }
    if ch == ',' && bracket_depth == 0 {
      let part = trim_string(String::unsafe_substring(raw, start~, end=i))
      if part.length() > 0 {
        parts.push(part)
      }
      start = i + 1
    }
  }
  if start <= raw.length() {
    let part = trim_string(
      String::unsafe_substring(raw, start~, end=raw.length()),
    )
    if part.length() > 0 {
      parts.push(part)
    }
  }
  parts
}

///|
fn parse_string_array_literal(raw : String) -> Array[String] {
  let text = trim_string(raw)
  if text.length() < 2 || not(text.has_prefix("[")) || not(text.has_suffix("]")) {
    return []
  }
  let inner = String::unsafe_substring(text, start=1, end=text.length() - 1)
  let result : Array[String] = []
  for part in split_top_level_csv(inner) {
    match parse_string_literal(part) {
      Some(value) => result.push(value)
      None => ()
    }
  }
  result
}

///|
fn parse_args(raw : String) -> (Map[String, String], Array[String]) {
  let args : Map[String, String] = {}
  let errors : Array[String] = []
  let text = trim_string(raw)
  if text.length() == 0 {
    return (args, errors)
  }
  for part in split_top_level_csv(text) {
    match part.find("=") {
      Some(idx) => {
        let key = trim_string(String::unsafe_substring(part, start=0, end=idx))
        let value = trim_string(
          String::unsafe_substring(part, start=idx + 1, end=part.length()),
        )
        if key.length() == 0 {
          errors.push("empty argument key in '\{part}'")
        } else {
          args[key] = value
        }
      }
      None => errors.push("invalid argument: \{part}")
    }
  }
  (args, errors)
}

///|
fn collect_starlark_statements(text : String) -> Array[String] {
  let statements : Array[String] = []
  let mut buf = ""
  let mut depth = 0
  let mut in_string = false
  let mut escaped = false
  for raw_line_view in text.split("\n") {
    let raw_line = raw_line_view.to_string()
    let line = trim_string(strip_comment(raw_line))
    if line.length() == 0 {
      continue
    }
    if buf.length() == 0 {
      buf = line
    } else {
      buf = buf + " " + line
    }
    for i in 0..<line.length() {
      let ch = line.unsafe_get(i)
      if escaped {
        escaped = false
        continue
      }
      if ch == '\\' {
        escaped = true
        continue
      }
      if ch == '"' {
        in_string = not(in_string)
        continue
      }
      if in_string {
        continue
      }
      if ch == '(' {
        depth += 1
      } else if ch == ')' {
        depth -= 1
      }
    }
    if depth == 0 {
      statements.push(buf)
      buf = ""
    }
  }
  if buf.length() > 0 {
    statements.push(buf)
  }
  statements
}

///|
fn parse_statement(
  stmt : String,
) -> (String, Map[String, String], Array[String]) {
  let errors : Array[String] = []
  let open_idx = stmt.find("(")
  let close_idx = stmt.rev_find(")")
  guard open_idx is Some(open) && close_idx is Some(close) else {
    errors.push("invalid statement: \{stmt}")
    return ("", {}, errors)
  }
  if close <= open {
    errors.push("invalid statement: \{stmt}")
    return ("", {}, errors)
  }
  let name = trim_string(String::unsafe_substring(stmt, start=0, end=open))
  let raw_args = String::unsafe_substring(stmt, start=open + 1, end=close)
  let (args, arg_errors) = parse_args(raw_args)
  for err in arg_errors {
    errors.push(err)
  }
  (name, args, errors)
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
  let errors : Array[String] = []
  let nodes : Array[FlowNode] = []
  let tasks : Array[FlowTask] = []
  let entry_targets : Array[String] = []
  let mut workflow_name = "default"
  let mut max_parallel = 1

  for stmt in collect_starlark_statements(text) {
    let (name, args, stmt_errors) = parse_statement(stmt)
    if stmt_errors.length() > 0 {
      for err in stmt_errors {
        errors.push(err)
      }
      continue
    }
    match name {
      "workflow" => {
        match args.get("name") {
          Some(raw_name) =>
            if parse_string_literal(raw_name) is Some(parsed_name) {
              workflow_name = parsed_name
            } else {
              errors.push("workflow.name must be string")
            }
          None => ()
        }
        match args.get("max_parallel") {
          Some(raw_max) =>
            max_parallel = parse_int_literal(raw_max, max_parallel)
          None => ()
        }
      }
      "node" => {
        guard args.get("id") is Some(raw_id) else {
          errors.push("node.id is required")
          continue
        }
        guard parse_string_literal(raw_id) is Some(id) else {
          errors.push("node.id must be string")
          continue
        }
        let depends_on = match args.get("depends_on") {
          Some(raw_depends) => parse_string_array_literal(raw_depends)
          None => []
        }
        let required = match args.get("required") {
          Some(raw_required) => parse_bool_literal(raw_required, true)
          None => true
        }
        nodes.push(new_node(id, depends_on, required~))
      }
      "task" => {
        guard args.get("id") is Some(raw_id) else {
          errors.push("task.id is required")
          continue
        }
        guard parse_string_literal(raw_id) is Some(id) else {
          errors.push("task.id must be string")
          continue
        }
        guard args.get("node") is Some(raw_node) else {
          errors.push("task.node is required")
          continue
        }
        guard parse_string_literal(raw_node) is Some(node_id) else {
          errors.push("task.node must be string")
          continue
        }
        guard args.get("cmd") is Some(raw_cmd) else {
          errors.push("task.cmd is required")
          continue
        }
        let cmd = match parse_string_literal(raw_cmd) {
          Some(single) => single
          None => {
            let parts = parse_string_array_literal(raw_cmd)
            if parts.length() == 0 {
              errors.push("task.cmd must be string or [string]")
              continue
            }
            parts.join(" ")
          }
        }
        let needs = match args.get("needs") {
          Some(raw_needs) => parse_string_array_literal(raw_needs)
          None => []
        }
        let required = match args.get("required") {
          Some(raw_required) => parse_bool_literal(raw_required, true)
          None => true
        }
        tasks.push(new_task(id, node_id, cmd, needs, required~))
      }
      "entrypoint" => {
        guard args.get("targets") is Some(raw_targets) else {
          errors.push("entrypoint.targets is required")
          continue
        }
        for target in parse_string_array_literal(raw_targets) {
          entry_targets.push(target)
        }
      }
      _ => errors.push("unknown statement: \{name}")
    }
  }

  {
    ir: new_ir(workflow_name, nodes, tasks, entry_targets~, max_parallel~),
    errors,
  }
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
  match (adapter.fs.read_text)(path) {
    Some(text) => parse_starlark_subset(text)
    None =>
      {
        ir: new_ir("default", [], []),
        errors: ["failed to read workflow file: " + path],
      }
  }
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
