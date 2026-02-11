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
fn parse_starlark_subset_impl(text : String) -> StarlarkParseResult {
  let syntax = parse_starlark_syntax(text)
  parse_starlark_calls_impl(syntax.calls, syntax.errors)
}

///|
fn parse_starlark_calls_impl(
  calls : Array[StarlarkCall],
  syntax_errors : Array[String],
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

  for call in calls {
    match call.name {
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
        let args = starlark_arg_map(call, errors)
        starlark_validate_unknown_args(call, ["name", "max_parallel"], errors)

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
        let args = starlark_arg_map(call, errors)
        starlark_validate_unknown_args(
          call,
          ["id", "depends_on", "required"],
          errors,
        )
        let mut invalid = false
        let mut id = ""
        let mut depends_on : Array[String] = []
        let mut required = true

        match starlark_required_arg(call, args, "id", errors) {
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
        let args = starlark_arg_map(call, errors)
        starlark_validate_unknown_args(
          call,
          ["id", "node", "cmd", "needs", "required"],
          errors,
        )
        let mut invalid = false
        let mut id = ""
        let mut node_id = ""
        let mut cmd = ""
        let mut needs : Array[String] = []
        let mut required = true

        match starlark_required_arg(call, args, "id", errors) {
          Some(arg) =>
            if starlark_expect_string("task", "id", arg, errors) is Some(value) {
              id = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match starlark_required_arg(call, args, "node", errors) {
          Some(arg) =>
            if starlark_expect_string("task", "node", arg, errors)
              is Some(value) {
              node_id = value
            } else {
              invalid = true
            }
          None => invalid = true
        }

        match starlark_required_arg(call, args, "cmd", errors) {
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

        if not(invalid) {
          tasks.push(new_task(id, node_id, cmd, needs, required~))
        }
      }
      "entrypoint" => {
        let args = starlark_arg_map(call, errors)
        starlark_validate_unknown_args(call, ["targets"], errors)
        match starlark_required_arg(call, args, "targets", errors) {
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

  {
    ir: new_ir(workflow_name, nodes, tasks, entry_targets~, max_parallel~),
    errors,
  }
}
