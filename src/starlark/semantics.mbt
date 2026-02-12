///|
// Host-level workflow semantics and IR lowering.
// Language-core expression evaluation is in lang_core.mbt.

///|
pub struct StarlarkNodeDecl {
  id : String
  depends_on : Array[String]
  required : Bool
}

///|
pub struct StarlarkTaskDecl {
  id : String
  node : String
  cmd : String
  needs : Array[String]
  required : Bool
  srcs : Array[String]
  outs : Array[String]
  env : Map[String, String]
  cwd : String
  trigger_mode : String
}

///|
pub struct StarlarkWorkflowDecl {
  name : String
  max_parallel : Int
  nodes : Array[StarlarkNodeDecl]
  tasks : Array[StarlarkTaskDecl]
  entry_targets : Array[String]
}

///|
pub struct StarlarkParseResult {
  workflow : StarlarkWorkflowDecl
  errors : Array[String]
}

///|
fn semantic_error(
  errors : Array[String],
  line : Int,
  column : Int,
  msg : String,
) -> Unit {
  errors.push("line \{line}, col \{column}: " + msg)
}

///|
fn arg_map(
  call : StarlarkCall,
  errors : Array[String],
) -> Map[String, StarlarkArg] {
  let mapped : Map[String, StarlarkArg] = {}
  for arg in call.args {
    if mapped.get(arg.name) is Some(_) {
      semantic_error(
        errors,
        arg.line,
        arg.column,
        "duplicate argument '\{arg.name}'",
      )
    } else {
      mapped[arg.name] = arg
    }
  }
  mapped
}

///|

///|
fn arg_map_resolved(
  call : StarlarkCall,
  bindings : Map[String, StarlarkValue],
  errors : Array[String],
) -> Map[String, StarlarkArg] {
  let mapped : Map[String, StarlarkArg] = {}
  for arg in call.args {
    if mapped.get(arg.name) is Some(_) {
      semantic_error(
        errors,
        arg.line,
        arg.column,
        "duplicate argument '\{arg.name}'",
      )
      continue
    }
    match resolve_value(arg.value, bindings, arg.line, arg.column, errors) {
      Some(value) =>
        mapped[arg.name] = {
          name: arg.name,
          value,
          line: arg.line,
          column: arg.column,
        }
      None => ()
    }
  }
  mapped
}

///|
fn call_has_arg(call : StarlarkCall, key : String) -> Bool {
  for arg in call.args {
    if arg.name == key {
      return true
    }
  }
  false
}

///|
fn validate_unknown_args(
  call : StarlarkCall,
  allowed : Array[String],
  errors : Array[String],
) -> Unit {
  for arg in call.args {
    if not(allowed.contains(arg.name)) {
      semantic_error(
        errors,
        arg.line,
        arg.column,
        "unknown argument '\{arg.name}' for \{call.name}",
      )
    }
  }
}

///|
fn validate_call_shape(
  call : StarlarkCall,
  args : Map[String, StarlarkArg],
  errors : Array[String],
) -> Unit {
  let allowed = builtin_allowed_args(call.name)
  if allowed.length() > 0 {
    validate_unknown_args(call, allowed, errors)
  }
  for key in builtin_required_args(call.name) {
    if args.get(key) is None {
      if call_has_arg(call, key) {
        // The argument was provided syntactically but failed to resolve.
        // Keep the root resolution error and skip noisy "required" reports.
        continue
      }
      semantic_error(
        errors,
        call.line,
        call.column,
        "\{call.name}.\{key} is required",
      )
    }
  }
}

///|
fn required_arg(
  call : StarlarkCall,
  args : Map[String, StarlarkArg],
  key : String,
  errors : Array[String],
) -> StarlarkArg? {
  match args.get(key) {
    Some(arg) => Some(arg)
    None => {
      semantic_error(
        errors,
        call.line,
        call.column,
        "\{call.name}.\{key} is required",
      )
      None
    }
  }
}

///|
fn expect_string(
  owner : String,
  key : String,
  arg : StarlarkArg,
  errors : Array[String],
) -> String? {
  match arg.value {
    Str(value) => Some(value)
    _ => {
      semantic_error(
        errors,
        arg.line,
        arg.column,
        "\{owner}.\{key} must be string",
      )
      None
    }
  }
}

///|
fn expect_int(
  owner : String,
  key : String,
  arg : StarlarkArg,
  errors : Array[String],
) -> Int? {
  match arg.value {
    Num(value) => Some(value)
    _ => {
      semantic_error(
        errors,
        arg.line,
        arg.column,
        "\{owner}.\{key} must be int",
      )
      None
    }
  }
}

///|
fn expect_bool(
  owner : String,
  key : String,
  arg : StarlarkArg,
  errors : Array[String],
) -> Bool? {
  match arg.value {
    Bool(value) => Some(value)
    _ => {
      semantic_error(
        errors,
        arg.line,
        arg.column,
        "\{owner}.\{key} must be bool",
      )
      None
    }
  }
}

///|
fn expect_trigger_mode(arg : StarlarkArg, errors : Array[String]) -> String? {
  match expect_string("task", "trigger", arg, errors) {
    Some(mode) =>
      if mode == "auto" || mode == "manual" {
        Some(mode)
      } else {
        semantic_error(
          errors,
          arg.line,
          arg.column,
          "task.trigger must be 'auto' or 'manual'",
        )
        None
      }
    None => None
  }
}

///|
fn expect_string_list(
  owner : String,
  key : String,
  arg : StarlarkArg,
  errors : Array[String],
) -> Array[String]? {
  match arg.value {
    List(values) => {
      let result : Array[String] = []
      for value in values {
        match value {
          Str(text) => result.push(text)
          _ => {
            semantic_error(
              errors,
              arg.line,
              arg.column,
              "\{owner}.\{key} must be [string]",
            )
            return None
          }
        }
      }
      Some(result)
    }
    _ => {
      semantic_error(
        errors,
        arg.line,
        arg.column,
        "\{owner}.\{key} must be [string]",
      )
      None
    }
  }
}

///|
fn expect_string_dict(
  owner : String,
  key : String,
  arg : StarlarkArg,
  errors : Array[String],
) -> Map[String, String]? {
  match arg.value {
    Dict(values) => {
      let result : Map[String, String] = {}
      for dict_key, value in values {
        match value {
          Str(text) => result[dict_key] = text
          _ => {
            semantic_error(
              errors,
              arg.line,
              arg.column,
              "\{owner}.\{key} must be {string:string}",
            )
            return None
          }
        }
      }
      Some(result)
    }
    _ => {
      semantic_error(
        errors,
        arg.line,
        arg.column,
        "\{owner}.\{key} must be {string:string}",
      )
      None
    }
  }
}

///|
fn expect_task_cmd(arg : StarlarkArg, errors : Array[String]) -> String? {
  match arg.value {
    Str(cmd) => Some(cmd)
    List(values) => {
      let parts : Array[String] = []
      for value in values {
        match value {
          Str(text) => parts.push(text)
          _ => {
            semantic_error(
              errors,
              arg.line,
              arg.column,
              "task.cmd must be string or [string]",
            )
            return None
          }
        }
      }
      if parts.length() == 0 {
        semantic_error(
          errors,
          arg.line,
          arg.column,
          "task.cmd must be string or [string]",
        )
        None
      } else {
        Some(parts.join(" "))
      }
    }
    _ => {
      semantic_error(
        errors,
        arg.line,
        arg.column,
        "task.cmd must be string or [string]",
      )
      None
    }
  }
}

///|
fn apply_assignment(
  call : StarlarkCall,
  bindings : Map[String, StarlarkValue],
  errors : Array[String],
) -> Unit {
  let args = arg_map(call, errors)
  let name_arg = match required_arg(call, args, "name", errors) {
    Some(arg) => arg
    None => return
  }
  let value_arg = match required_arg(call, args, "value", errors) {
    Some(arg) => arg
    None => return
  }
  let name = match expect_string("assign", "name", name_arg, errors) {
    Some(value) => value
    None => return
  }
  match
    resolve_value(
      value_arg.value,
      bindings,
      value_arg.line,
      value_arg.column,
      errors,
    ) {
    Some(value) => bindings[name] = value
    None => ()
  }
}

///|
fn var_allowed_types() -> Array[String] {
  ["any", "string", "int", "bool", "string_list", "string_dict"]
}

///|
fn value_matches_type(value : StarlarkValue, typ : String) -> Bool {
  if typ == "any" {
    return true
  }
  match value {
    Str(_) => typ == "string"
    Num(_) => typ == "int"
    Bool(_) => typ == "bool"
    NoneValue => false
    List(items) => {
      if typ != "string_list" {
        return false
      }
      for item in items {
        match item {
          Str(_) => ()
          _ => return false
        }
      }
      true
    }
    Dict(entries) => {
      if typ != "string_dict" {
        return false
      }
      for _, item in entries {
        match item {
          Str(_) => ()
          _ => return false
        }
      }
      true
    }
    Ref(_) => false
    MethodCall(_, _, _) => false
    Call(_, _) => false
    Slice(_, _, _) => false
    Index(_, _) => false
    Neg(_) => false
    Add(_, _) => false
    Sub(_, _) => false
    Mul(_, _) => false
    FloorDiv(_, _) => false
    Mod(_, _) => false
    Eq(_, _) => false
    NotEq(_, _) => false
    Lt(_, _) => false
    Lte(_, _) => false
    Gt(_, _) => false
    Gte(_, _) => false
    In(_, _) => false
    NotIn(_, _) => false
    Not(_) => false
    And(_, _) => false
    Or(_, _) => false
    IfExpr(_, _, _) => false
  }
}

///|
fn infer_var_type(value : StarlarkValue) -> String {
  match value {
    Str(_) => "string"
    Num(_) => "int"
    Bool(_) => "bool"
    NoneValue => "any"
    List(items) => {
      for item in items {
        match item {
          Str(_) => ()
          _ => return "any"
        }
      }
      "string_list"
    }
    Dict(entries) => {
      for _, item in entries {
        match item {
          Str(_) => ()
          _ => return "any"
        }
      }
      "string_dict"
    }
    Ref(_) => "any"
    MethodCall(_, _, _) => "any"
    Call(_, _) => "any"
    Slice(_, _, _) => "any"
    Index(_, _) => "any"
    Neg(_) => "any"
    Add(_, _) => "any"
    Sub(_, _) => "any"
    Mul(_, _) => "any"
    FloorDiv(_, _) => "any"
    Mod(_, _) => "any"
    Eq(_, _) => "any"
    NotEq(_, _) => "any"
    Lt(_, _) => "any"
    Lte(_, _) => "any"
    Gt(_, _) => "any"
    Gte(_, _) => "any"
    In(_, _) => "any"
    NotIn(_, _) => "any"
    Not(_) => "any"
    And(_, _) => "any"
    Or(_, _) => "any"
    IfExpr(_, _, _) => "any"
  }
}

///|
fn trim_ascii_space(text : String) -> String {
  let mut start = 0
  let mut end = text.length()
  while start < end {
    let ch = text.unsafe_get(start)
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      start += 1
    } else {
      break
    }
  }
  while end > start {
    let ch = text.unsafe_get(end - 1)
    if ch == ' ' || ch == '\t' || ch == '\n' || ch == '\r' {
      end -= 1
    } else {
      break
    }
  }
  if start == 0 && end == text.length() {
    text
  } else {
    String::unsafe_substring(text, start~, end~)
  }
}

///|
fn parse_external_int(raw : String) -> Int? {
  let text = trim_ascii_space(raw)
  if text.length() == 0 {
    return None
  }
  let mut idx = 0
  let mut negative = false
  let first = text.unsafe_get(0)
  if first == '-' {
    negative = true
    idx = 1
  } else if first == '+' {
    idx = 1
  }
  if idx >= text.length() {
    return None
  }
  let mut value = 0
  while idx < text.length() {
    let ch = text.unsafe_get(idx)
    if ch < '0' || ch > '9' {
      return None
    }
    value = value * 10 + (ch.to_int() - '0'.to_int())
    idx += 1
  }
  if negative {
    value = -value
  }
  Some(value)
}

///|
fn parse_external_string_list(raw : String) -> StarlarkValue {
  let text = trim_ascii_space(raw)
  if text.length() == 0 {
    return List([])
  }
  let items : Array[StarlarkValue] = []
  for view in text.split(",") {
    let item = trim_ascii_space(view.to_string())
    items.push(Str(item))
  }
  List(items)
}

///|
fn parse_external_string_dict(raw : String) -> Map[String, StarlarkValue]? {
  let text = trim_ascii_space(raw)
  if text.length() == 0 {
    return Some({})
  }
  let values : Map[String, StarlarkValue] = {}
  for part_view in text.split(",") {
    let part = trim_ascii_space(part_view.to_string())
    if part.length() == 0 {
      return None
    }
    guard part.find("=") is Some(eq_idx) else { return None }
    let key = trim_ascii_space(
      String::unsafe_substring(part, start=0, end=eq_idx),
    )
    let value = trim_ascii_space(
      String::unsafe_substring(part, start=eq_idx + 1, end=part.length()),
    )
    if key.length() == 0 {
      return None
    }
    values[key] = Str(value)
  }
  Some(values)
}

///|
fn parse_external_input_value(
  name : String,
  typ : String,
  raw : String,
  line : Int,
  column : Int,
  errors : Array[String],
) -> StarlarkValue? {
  if typ == "any" || typ == "string" {
    return Some(Str(raw))
  }
  if typ == "int" {
    match parse_external_int(raw) {
      Some(value) => return Some(Num(value))
      None => {
        semantic_error(
          errors,
          line,
          column,
          "external input for '\{name}' must be int",
        )
        return None
      }
    }
  }
  if typ == "bool" {
    let text = trim_ascii_space(raw)
    if text == "true" || text == "True" || text == "1" {
      return Some(Bool(true))
    }
    if text == "false" || text == "False" || text == "0" {
      return Some(Bool(false))
    }
    semantic_error(
      errors,
      line,
      column,
      "external input for '\{name}' must be bool",
    )
    return None
  }
  if typ == "string_list" {
    return Some(parse_external_string_list(raw))
  }
  if typ == "string_dict" {
    match parse_external_string_dict(raw) {
      Some(values) => return Some(Dict(values))
      None => {
        semantic_error(
          errors,
          line,
          column,
          "external input for '\{name}' must be key=value,key=value",
        )
        return None
      }
    }
  }
  semantic_error(errors, line, column, "unsupported var type '\{typ}'")
  None
}

///|
fn apply_var_call(
  call : StarlarkCall,
  args : Map[String, StarlarkArg],
  bindings : Map[String, StarlarkValue],
  var_types : Map[String, String],
  required_pending : Map[String, Bool],
  required_locations : Map[String, (Int, Int)],
  external_inputs : Map[String, String],
  errors : Array[String],
) -> Unit {
  for key in ["name", "type", "required", "default"] {
    if call_has_arg(call, key) && args.get(key) is None {
      return
    }
  }
  let name_arg = match args.get("name") {
    Some(arg) => arg
    None => return
  }
  let name = match expect_string("var", "name", name_arg, errors) {
    Some(value) => value
    None => return
  }
  let mut required = false
  match args.get("required") {
    Some(required_arg) =>
      match expect_bool("var", "required", required_arg, errors) {
        Some(value) => required = value
        None => return
      }
    None => ()
  }

  let default_arg = args.get("default")
  let default_value = match default_arg {
    Some(arg) => Some(arg.value)
    None => None
  }
  let mut typ = match default_value {
    Some(value) => infer_var_type(value)
    None => "string"
  }
  match args.get("type") {
    Some(type_arg) =>
      match expect_string("var", "type", type_arg, errors) {
        Some(type_name) => {
          if not(var_allowed_types().contains(type_name)) {
            semantic_error(
              errors,
              type_arg.line,
              type_arg.column,
              "var.type must be one of " + var_allowed_types().join(", "),
            )
            return
          }
          typ = type_name
        }
        None => return
      }
    None => ()
  }
  match default_arg {
    Some(arg) =>
      if not(value_matches_type(arg.value, typ)) {
        semantic_error(
          errors,
          arg.line,
          arg.column,
          "var.default must match type '\{typ}'",
        )
        return
      }
    None => ()
  }
  if default_arg is None && not(required) {
    semantic_error(
      errors,
      call.line,
      call.column,
      "var.default is required when var.required is false",
    )
    return
  }

  let mut resolved_by_external = false
  match external_inputs.get(name) {
    Some(raw_value) =>
      match
        parse_external_input_value(
          name,
          typ,
          raw_value,
          name_arg.line,
          name_arg.column,
          errors,
        ) {
        Some(parsed) => {
          bindings[name] = parsed
          resolved_by_external = true
        }
        None => return
      }
    None =>
      match default_value {
        Some(value) => bindings[name] = value
        None => ()
      }
  }

  var_types[name] = typ
  if required {
    required_locations[name] = (name_arg.line, name_arg.column)
    required_pending[name] = true
    if resolved_by_external {
      required_pending[name] = false
    }
  }
}

///|
fn apply_config_call(
  call : StarlarkCall,
  args : Map[String, StarlarkArg],
  bindings : Map[String, StarlarkValue],
  var_types : Map[String, String],
  required_pending : Map[String, Bool],
  errors : Array[String],
) -> Unit {
  let name_arg = match args.get("name") {
    Some(arg) => arg
    None => return
  }
  let value_arg = match args.get("value") {
    Some(arg) => arg
    None => return
  }
  let name = match expect_string("config", "name", name_arg, errors) {
    Some(value) => value
    None => return
  }
  guard var_types.get(name) is Some(expected_type) else {
    semantic_error(
      errors,
      call.line,
      call.column,
      "config.name '\{name}' is not declared by var()",
    )
    return
  }
  if not(value_matches_type(value_arg.value, expected_type)) {
    semantic_error(
      errors,
      value_arg.line,
      value_arg.column,
      "config.value for '\{name}' must match type '\{expected_type}'",
    )
    return
  }
  bindings[name] = value_arg.value
  if required_pending.get(name) is Some(_) {
    required_pending[name] = false
  }
}

///|
pub fn parse(text : String) -> StarlarkParseResult {
  parse_with_inputs_impl(text, {})
}

///|
pub fn parse_with_inputs(
  text : String,
  external_inputs : Map[String, String],
) -> StarlarkParseResult {
  parse_with_inputs_impl(text, external_inputs)
}

///|
fn parse_with_inputs_impl(
  text : String,
  external_inputs : Map[String, String],
) -> StarlarkParseResult {
  let syntax = parse_syntax(text)
  parse_calls_impl(syntax.calls, syntax.errors, external_inputs)
}

///|
fn parse_calls_impl(
  calls : Array[StarlarkCall],
  syntax_errors : Array[String],
  external_inputs : Map[String, String],
) -> StarlarkParseResult {
  let errors : Array[String] = []
  for err in syntax_errors {
    errors.push(err)
  }

  let nodes : Array[StarlarkNodeDecl] = []
  let tasks : Array[StarlarkTaskDecl] = []
  let entry_targets : Array[String] = []
  let mut workflow_name = "default"
  let mut max_parallel = 1
  let mut seen_workflow = false
  let bindings : Map[String, StarlarkValue] = {}
  let var_types : Map[String, String] = {}
  let required_pending : Map[String, Bool] = {}
  let required_locations : Map[String, (Int, Int)] = {}

  for call in calls {
    let canonical_name = builtin_canonical_name(call.name)
    match canonical_name {
      "__assign__" => apply_assignment(call, bindings, errors)
      "var" => {
        let args = arg_map_resolved(call, bindings, errors)
        validate_call_shape(call, args, errors)
        apply_var_call(
          call, args, bindings, var_types, required_pending, required_locations,
          external_inputs, errors,
        )
      }
      "config" => {
        let args = arg_map_resolved(call, bindings, errors)
        validate_call_shape(call, args, errors)
        apply_config_call(
          call, args, bindings, var_types, required_pending, errors,
        )
      }
      "workflow" => {
        if seen_workflow {
          semantic_error(
            errors,
            call.line,
            call.column,
            "workflow() can only be declared once",
          )
          continue
        }
        seen_workflow = true
        let args = arg_map_resolved(call, bindings, errors)
        validate_call_shape(call, args, errors)

        match args.get("name") {
          Some(arg) =>
            match expect_string("workflow", "name", arg, errors) {
              Some(name) => workflow_name = name
              None => ()
            }
          None => ()
        }

        match args.get("max_parallel") {
          Some(arg) =>
            match expect_int("workflow", "max_parallel", arg, errors) {
              Some(value) =>
                if value > 0 {
                  max_parallel = value
                } else {
                  semantic_error(
                    errors,
                    arg.line,
                    arg.column,
                    "workflow.max_parallel must be positive",
                  )
                }
              None => ()
            }
          None => ()
        }
      }
      "node" => {
        let args = arg_map_resolved(call, bindings, errors)
        validate_call_shape(call, args, errors)
        let mut invalid = false
        let mut id = ""
        let mut depends_on : Array[String] = []
        let mut required = true

        match args.get("id") {
          Some(arg) =>
            if expect_string("node", "id", arg, errors) is Some(value) {
              id = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match args.get("depends_on") {
          Some(arg) =>
            if expect_string_list("node", "depends_on", arg, errors)
              is Some(value) {
              depends_on = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("required") {
          Some(arg) =>
            if expect_bool("node", "required", arg, errors) is Some(value) {
              required = value
            } else {
              invalid = true
            }
          None => ()
        }

        if not(invalid) {
          nodes.push({ id, depends_on, required })
        }
      }
      "task" => {
        let args = arg_map_resolved(call, bindings, errors)
        validate_call_shape(call, args, errors)
        let mut invalid = false
        let mut id = ""
        let mut node_id = ""
        let mut cmd = ""
        let mut needs : Array[String] = []
        let mut required = true
        let mut srcs : Array[String] = []
        let mut outs : Array[String] = []
        let mut env : Map[String, String] = {}
        let mut cwd = ""
        let mut trigger_mode = "auto"

        match args.get("id") {
          Some(arg) =>
            if expect_string("task", "id", arg, errors) is Some(value) {
              id = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match args.get("node") {
          Some(arg) =>
            if expect_string("task", "node", arg, errors) is Some(value) {
              node_id = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match args.get("cmd") {
          Some(arg) =>
            if expect_task_cmd(arg, errors) is Some(value) {
              cmd = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match args.get("needs") {
          Some(arg) =>
            if expect_string_list("task", "needs", arg, errors) is Some(value) {
              needs = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("required") {
          Some(arg) =>
            if expect_bool("task", "required", arg, errors) is Some(value) {
              required = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("srcs") {
          Some(arg) =>
            if expect_string_list("task", "srcs", arg, errors) is Some(value) {
              srcs = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("outs") {
          Some(arg) =>
            if expect_string_list("task", "outs", arg, errors) is Some(value) {
              outs = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("env") {
          Some(arg) =>
            if expect_string_dict("task", "env", arg, errors) is Some(value) {
              env = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("cwd") {
          Some(arg) =>
            if expect_string("task", "cwd", arg, errors) is Some(value) {
              cwd = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("trigger") {
          Some(arg) =>
            if expect_trigger_mode(arg, errors) is Some(value) {
              trigger_mode = value
            } else {
              invalid = true
            }
          None => ()
        }

        if not(invalid) {
          tasks.push({
            id,
            node: node_id,
            cmd,
            needs,
            required,
            srcs,
            outs,
            env,
            cwd,
            trigger_mode,
          })
        }
      }
      "entrypoint" => {
        let args = arg_map_resolved(call, bindings, errors)
        validate_call_shape(call, args, errors)
        match args.get("targets") {
          Some(arg) =>
            if expect_string_list("entrypoint", "targets", arg, errors)
              is Some(targets) {
              for target in targets {
                entry_targets.push(target)
              }
            }
          None => ()
        }
      }
      "load" =>
        semantic_error(
          errors,
          call.line,
          call.column,
          "load() is only supported when parsing from fs",
        )
      _ =>
        semantic_error(
          errors,
          call.line,
          call.column,
          "unknown statement: \{call.name}",
        )
    }
  }

  for name, is_pending in required_pending {
    if is_pending {
      let (line, column) = required_locations.get(name).unwrap_or((1, 1))
      semantic_error(
        errors,
        line,
        column,
        "required var '\{name}' must be provided by config() or external inputs",
      )
    }
  }
  for key, _ in external_inputs {
    if var_types.get(key) is None {
      errors.push("external input '\{key}' is not declared by var()")
    }
  }

  {
    workflow: { name: workflow_name, max_parallel, nodes, tasks, entry_targets },
    errors,
  }
}
