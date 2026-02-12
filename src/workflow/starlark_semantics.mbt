///|
fn starlark_semantic_error(
  errors : Array[String],
  line : Int,
  column : Int,
  msg : String,
) -> Unit {
  errors.push("line \{line}, col \{column}: " + msg)
}

///|
fn starlark_arg_map(
  call : StarlarkCall,
  errors : Array[String],
) -> Map[String, StarlarkArg] {
  let mapped : Map[String, StarlarkArg] = {}
  for arg in call.args {
    if mapped.get(arg.name) is Some(_) {
      starlark_semantic_error(
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
fn starlark_resolve_value(
  value : StarlarkValue,
  bindings : Map[String, StarlarkValue],
  line : Int,
  column : Int,
  errors : Array[String],
) -> StarlarkValue? {
  match value {
    Ref(name) =>
      match bindings.get(name) {
        Some(bound) =>
          starlark_resolve_value(bound, bindings, line, column, errors)
        None => {
          starlark_semantic_error(
            errors,
            line,
            column,
            "unknown variable '\{name}'",
          )
          None
        }
      }
    List(values) => {
      let resolved : Array[StarlarkValue] = []
      for item in values {
        match starlark_resolve_value(item, bindings, line, column, errors) {
          Some(value) => resolved.push(value)
          None => return None
        }
      }
      Some(List(resolved))
    }
    Dict(values) => {
      let resolved : Map[String, StarlarkValue] = {}
      for key, item in values {
        match starlark_resolve_value(item, bindings, line, column, errors) {
          Some(value) => resolved[key] = value
          None => return None
        }
      }
      Some(Dict(resolved))
    }
    _ => Some(value)
  }
}

///|
fn starlark_arg_map_resolved(
  call : StarlarkCall,
  bindings : Map[String, StarlarkValue],
  errors : Array[String],
) -> Map[String, StarlarkArg] {
  let mapped : Map[String, StarlarkArg] = {}
  for arg in call.args {
    if mapped.get(arg.name) is Some(_) {
      starlark_semantic_error(
        errors,
        arg.line,
        arg.column,
        "duplicate argument '\{arg.name}'",
      )
      continue
    }
    match
      starlark_resolve_value(arg.value, bindings, arg.line, arg.column, errors) {
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
fn starlark_call_has_arg(call : StarlarkCall, key : String) -> Bool {
  for arg in call.args {
    if arg.name == key {
      return true
    }
  }
  false
}

///|
fn starlark_validate_unknown_args(
  call : StarlarkCall,
  allowed : Array[String],
  errors : Array[String],
) -> Unit {
  for arg in call.args {
    if not(allowed.contains(arg.name)) {
      starlark_semantic_error(
        errors,
        arg.line,
        arg.column,
        "unknown argument '\{arg.name}' for \{call.name}",
      )
    }
  }
}

///|
fn starlark_validate_call_shape(
  call : StarlarkCall,
  args : Map[String, StarlarkArg],
  errors : Array[String],
) -> Unit {
  let allowed = starlark_builtin_allowed_args(call.name)
  if allowed.length() > 0 {
    starlark_validate_unknown_args(call, allowed, errors)
  }
  for key in starlark_builtin_required_args(call.name) {
    if args.get(key) is None {
      if starlark_call_has_arg(call, key) {
        // The argument was provided syntactically but failed to resolve.
        // Keep the root resolution error and skip noisy "required" reports.
        continue
      }
      starlark_semantic_error(
        errors,
        call.line,
        call.column,
        "\{call.name}.\{key} is required",
      )
    }
  }
}

///|
fn starlark_required_arg(
  call : StarlarkCall,
  args : Map[String, StarlarkArg],
  key : String,
  errors : Array[String],
) -> StarlarkArg? {
  match args.get(key) {
    Some(arg) => Some(arg)
    None => {
      starlark_semantic_error(
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
fn starlark_expect_string(
  owner : String,
  key : String,
  arg : StarlarkArg,
  errors : Array[String],
) -> String? {
  match arg.value {
    Str(value) => Some(value)
    _ => {
      starlark_semantic_error(
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
fn starlark_expect_int(
  owner : String,
  key : String,
  arg : StarlarkArg,
  errors : Array[String],
) -> Int? {
  match arg.value {
    Num(value) => Some(value)
    _ => {
      starlark_semantic_error(
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
fn starlark_expect_bool(
  owner : String,
  key : String,
  arg : StarlarkArg,
  errors : Array[String],
) -> Bool? {
  match arg.value {
    Bool(value) => Some(value)
    _ => {
      starlark_semantic_error(
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
fn starlark_expect_trigger_mode(
  arg : StarlarkArg,
  errors : Array[String],
) -> String? {
  match starlark_expect_string("task", "trigger", arg, errors) {
    Some(mode) =>
      if mode == "auto" || mode == "manual" {
        Some(mode)
      } else {
        starlark_semantic_error(
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
fn starlark_expect_string_list(
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
            starlark_semantic_error(
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
      starlark_semantic_error(
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
fn starlark_expect_string_dict(
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
            starlark_semantic_error(
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
      starlark_semantic_error(
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
fn starlark_expect_task_cmd(
  arg : StarlarkArg,
  errors : Array[String],
) -> String? {
  match arg.value {
    Str(cmd) => Some(cmd)
    List(values) => {
      let parts : Array[String] = []
      for value in values {
        match value {
          Str(text) => parts.push(text)
          _ => {
            starlark_semantic_error(
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
        starlark_semantic_error(
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
      starlark_semantic_error(
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
fn starlark_apply_assignment(
  call : StarlarkCall,
  bindings : Map[String, StarlarkValue],
  errors : Array[String],
) -> Unit {
  let args = starlark_arg_map(call, errors)
  let name_arg = match starlark_required_arg(call, args, "name", errors) {
    Some(arg) => arg
    None => return
  }
  let value_arg = match starlark_required_arg(call, args, "value", errors) {
    Some(arg) => arg
    None => return
  }
  let name = match starlark_expect_string("assign", "name", name_arg, errors) {
    Some(value) => value
    None => return
  }
  match
    starlark_resolve_value(
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
fn starlark_var_allowed_types() -> Array[String] {
  ["any", "string", "int", "bool", "string_list", "string_dict"]
}

///|
fn starlark_value_matches_type(value : StarlarkValue, typ : String) -> Bool {
  if typ == "any" {
    return true
  }
  match value {
    Str(_) => typ == "string"
    Num(_) => typ == "int"
    Bool(_) => typ == "bool"
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
  }
}

///|
fn starlark_infer_var_type(value : StarlarkValue) -> String {
  match value {
    Str(_) => "string"
    Num(_) => "int"
    Bool(_) => "bool"
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
  }
}

///|
fn starlark_trim_ascii_space(text : String) -> String {
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
fn starlark_parse_external_int(raw : String) -> Int? {
  let text = starlark_trim_ascii_space(raw)
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
fn starlark_parse_external_string_list(raw : String) -> StarlarkValue {
  let text = starlark_trim_ascii_space(raw)
  if text.length() == 0 {
    return List([])
  }
  let items : Array[StarlarkValue] = []
  for view in text.split(",") {
    let item = starlark_trim_ascii_space(view.to_string())
    items.push(Str(item))
  }
  List(items)
}

///|
fn starlark_parse_external_string_dict(
  raw : String,
) -> Map[String, StarlarkValue]? {
  let text = starlark_trim_ascii_space(raw)
  if text.length() == 0 {
    return Some({})
  }
  let values : Map[String, StarlarkValue] = {}
  for part_view in text.split(",") {
    let part = starlark_trim_ascii_space(part_view.to_string())
    if part.length() == 0 {
      return None
    }
    guard part.find("=") is Some(eq_idx) else { return None }
    let key = starlark_trim_ascii_space(
      String::unsafe_substring(part, start=0, end=eq_idx),
    )
    let value = starlark_trim_ascii_space(
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
fn starlark_parse_external_input_value(
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
    match starlark_parse_external_int(raw) {
      Some(value) => return Some(Num(value))
      None => {
        starlark_semantic_error(
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
    let text = starlark_trim_ascii_space(raw)
    if text == "true" || text == "True" || text == "1" {
      return Some(Bool(true))
    }
    if text == "false" || text == "False" || text == "0" {
      return Some(Bool(false))
    }
    starlark_semantic_error(
      errors,
      line,
      column,
      "external input for '\{name}' must be bool",
    )
    return None
  }
  if typ == "string_list" {
    return Some(starlark_parse_external_string_list(raw))
  }
  if typ == "string_dict" {
    match starlark_parse_external_string_dict(raw) {
      Some(values) => return Some(Dict(values))
      None => {
        starlark_semantic_error(
          errors,
          line,
          column,
          "external input for '\{name}' must be key=value,key=value",
        )
        return None
      }
    }
  }
  starlark_semantic_error(errors, line, column, "unsupported var type '\{typ}'")
  None
}

///|
fn starlark_apply_var_call(
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
    if starlark_call_has_arg(call, key) && args.get(key) is None {
      return
    }
  }
  let name_arg = match args.get("name") {
    Some(arg) => arg
    None => return
  }
  let name = match starlark_expect_string("var", "name", name_arg, errors) {
    Some(value) => value
    None => return
  }
  let mut required = false
  match args.get("required") {
    Some(required_arg) =>
      match starlark_expect_bool("var", "required", required_arg, errors) {
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
    Some(value) => starlark_infer_var_type(value)
    None => "string"
  }
  match args.get("type") {
    Some(type_arg) =>
      match starlark_expect_string("var", "type", type_arg, errors) {
        Some(type_name) => {
          if not(starlark_var_allowed_types().contains(type_name)) {
            starlark_semantic_error(
              errors,
              type_arg.line,
              type_arg.column,
              "var.type must be one of " +
              starlark_var_allowed_types().join(", "),
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
      if not(starlark_value_matches_type(arg.value, typ)) {
        starlark_semantic_error(
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
    starlark_semantic_error(
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
        starlark_parse_external_input_value(
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
fn starlark_apply_config_call(
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
  let name = match starlark_expect_string("config", "name", name_arg, errors) {
    Some(value) => value
    None => return
  }
  guard var_types.get(name) is Some(expected_type) else {
    starlark_semantic_error(
      errors,
      call.line,
      call.column,
      "config.name '\{name}' is not declared by var()",
    )
    return
  }
  if not(starlark_value_matches_type(value_arg.value, expected_type)) {
    starlark_semantic_error(
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
fn parse_starlark_subset_impl(text : String) -> StarlarkParseResult {
  parse_starlark_subset_with_inputs_impl(text, {})
}

///|
fn parse_starlark_subset_with_inputs_impl(
  text : String,
  external_inputs : Map[String, String],
) -> StarlarkParseResult {
  let syntax = parse_starlark_syntax(text)
  parse_starlark_calls_impl(syntax.calls, syntax.errors, external_inputs)
}

///|
fn parse_starlark_calls_impl(
  calls : Array[StarlarkCall],
  syntax_errors : Array[String],
  external_inputs : Map[String, String],
) -> StarlarkParseResult {
  let errors : Array[String] = []
  for err in syntax_errors {
    errors.push(err)
  }

  let nodes : Array[FlowNode] = []
  let tasks : Array[FlowTask] = []
  let entry_targets : Array[String] = []
  let mut workflow_name = "default"
  let mut max_parallel = 1
  let mut seen_workflow = false
  let bindings : Map[String, StarlarkValue] = {}
  let var_types : Map[String, String] = {}
  let required_pending : Map[String, Bool] = {}
  let required_locations : Map[String, (Int, Int)] = {}

  for call in calls {
    let canonical_name = starlark_builtin_canonical_name(call.name)
    match canonical_name {
      "__assign__" => starlark_apply_assignment(call, bindings, errors)
      "var" => {
        let args = starlark_arg_map_resolved(call, bindings, errors)
        starlark_validate_call_shape(call, args, errors)
        starlark_apply_var_call(
          call, args, bindings, var_types, required_pending, required_locations,
          external_inputs, errors,
        )
      }
      "config" => {
        let args = starlark_arg_map_resolved(call, bindings, errors)
        starlark_validate_call_shape(call, args, errors)
        starlark_apply_config_call(
          call, args, bindings, var_types, required_pending, errors,
        )
      }
      "workflow" => {
        if seen_workflow {
          starlark_semantic_error(
            errors,
            call.line,
            call.column,
            "workflow() can only be declared once",
          )
          continue
        }
        seen_workflow = true
        let args = starlark_arg_map_resolved(call, bindings, errors)
        starlark_validate_call_shape(call, args, errors)

        match args.get("name") {
          Some(arg) =>
            match starlark_expect_string("workflow", "name", arg, errors) {
              Some(name) => workflow_name = name
              None => ()
            }
          None => ()
        }

        match args.get("max_parallel") {
          Some(arg) =>
            match starlark_expect_int("workflow", "max_parallel", arg, errors) {
              Some(value) =>
                if value > 0 {
                  max_parallel = value
                } else {
                  starlark_semantic_error(
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
        let args = starlark_arg_map_resolved(call, bindings, errors)
        starlark_validate_call_shape(call, args, errors)
        let mut invalid = false
        let mut id = ""
        let mut depends_on : Array[String] = []
        let mut required = true

        match args.get("id") {
          Some(arg) =>
            if starlark_expect_string("node", "id", arg, errors) is Some(value) {
              id = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match args.get("depends_on") {
          Some(arg) =>
            if starlark_expect_string_list("node", "depends_on", arg, errors)
              is Some(value) {
              depends_on = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("required") {
          Some(arg) =>
            if starlark_expect_bool("node", "required", arg, errors)
              is Some(value) {
              required = value
            } else {
              invalid = true
            }
          None => ()
        }

        if not(invalid) {
          nodes.push(new_node(id, depends_on, required~))
        }
      }
      "task" => {
        let args = starlark_arg_map_resolved(call, bindings, errors)
        starlark_validate_call_shape(call, args, errors)
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
            if starlark_expect_string("task", "id", arg, errors) is Some(value) {
              id = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match args.get("node") {
          Some(arg) =>
            if starlark_expect_string("task", "node", arg, errors)
              is Some(value) {
              node_id = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match args.get("cmd") {
          Some(arg) =>
            if starlark_expect_task_cmd(arg, errors) is Some(value) {
              cmd = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match args.get("needs") {
          Some(arg) =>
            if starlark_expect_string_list("task", "needs", arg, errors)
              is Some(value) {
              needs = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("required") {
          Some(arg) =>
            if starlark_expect_bool("task", "required", arg, errors)
              is Some(value) {
              required = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("srcs") {
          Some(arg) =>
            if starlark_expect_string_list("task", "srcs", arg, errors)
              is Some(value) {
              srcs = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("outs") {
          Some(arg) =>
            if starlark_expect_string_list("task", "outs", arg, errors)
              is Some(value) {
              outs = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("env") {
          Some(arg) =>
            if starlark_expect_string_dict("task", "env", arg, errors)
              is Some(value) {
              env = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("cwd") {
          Some(arg) =>
            if starlark_expect_string("task", "cwd", arg, errors) is Some(value) {
              cwd = value
            } else {
              invalid = true
            }
          None => ()
        }

        match args.get("trigger") {
          Some(arg) =>
            if starlark_expect_trigger_mode(arg, errors) is Some(value) {
              trigger_mode = value
            } else {
              invalid = true
            }
          None => ()
        }

        if not(invalid) {
          tasks.push(
            new_task(
              id,
              node_id,
              cmd,
              needs,
              required~,
              srcs~,
              outs~,
              env~,
              cwd~,
              trigger_mode~,
            ),
          )
        }
      }
      "entrypoint" => {
        let args = starlark_arg_map_resolved(call, bindings, errors)
        starlark_validate_call_shape(call, args, errors)
        match args.get("targets") {
          Some(arg) =>
            if starlark_expect_string_list("entrypoint", "targets", arg, errors)
              is Some(targets) {
              for target in targets {
                entry_targets.push(target)
              }
            }
          None => ()
        }
      }
      "load" =>
        starlark_semantic_error(
          errors,
          call.line,
          call.column,
          "load() is only supported when parsing from fs",
        )
      _ =>
        starlark_semantic_error(
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
      starlark_semantic_error(
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
    ir: new_ir(workflow_name, nodes, tasks, entry_targets~, max_parallel~),
    errors,
  }
}
