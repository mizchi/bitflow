///|
fn starlark_path_dirname(path : String) -> String {
  match path.rev_find("/") {
    Some(0) => "/"
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
    None => "."
  }
}

///|
fn starlark_path_normalize(path : String) -> String {
  let is_abs = path.has_prefix("/")
  let parts : Array[String] = []
  for view in path.split("/") {
    let part = view.to_string()
    if part.length() == 0 || part == "." {
      continue
    }
    if part == ".." {
      if parts.length() > 0 && parts[parts.length() - 1] != ".." {
        parts.pop() |> ignore
      } else if not(is_abs) {
        parts.push(part)
      }
      continue
    }
    parts.push(part)
  }
  let body = parts.join("/")
  if is_abs {
    if body.length() == 0 {
      "/"
    } else {
      "/" + body
    }
  } else if body.length() == 0 {
    "."
  } else {
    body
  }
}

///|
fn starlark_resolve_load_path(base_path : String, raw_path : String) -> String {
  if raw_path.has_prefix("/") {
    starlark_path_normalize(raw_path)
  } else {
    let base_dir = starlark_path_dirname(base_path)
    if base_dir == "." {
      starlark_path_normalize(raw_path)
    } else {
      starlark_path_normalize(base_dir + "/" + raw_path)
    }
  }
}

///|
fn starlark_load_path_from_call(
  call : StarlarkCall,
  errors : Array[String],
) -> String? {
  let args = starlark_arg_map(call, errors)
  starlark_validate_call_shape(call, args, errors)
  guard args.get("path") is Some(target) else { return None }
  match target.value {
    Str(path) => Some(path)
    _ => {
      starlark_semantic_error(
        errors,
        target.line,
        target.column,
        "load.path must be string",
      )
      None
    }
  }
}

///|
fn starlark_collect_calls_from_fs(
  path : String,
  adapter : WorkflowAdapter,
  calls : Array[StarlarkCall],
  errors : Array[String],
  visiting : Map[String, Bool],
  loaded : Map[String, Bool],
  stack : Array[String],
) -> Unit {
  let normalized = starlark_path_normalize(path)
  if loaded.get(normalized).unwrap_or(false) {
    return
  }
  if visiting.get(normalized).unwrap_or(false) {
    let chain = if stack.length() == 0 {
      normalized
    } else {
      stack.join(" -> ") + " -> " + normalized
    }
    errors.push("load cycle detected: " + chain)
    return
  }
  visiting[normalized] = true
  stack.push(normalized)

  match (adapter.fs.read_text)(normalized) {
    Some(text) => {
      let syntax = parse_starlark_syntax(text)
      for err in syntax.errors {
        errors.push(normalized + ": " + err)
      }
      for call in syntax.calls {
        if call.name == "load" {
          match starlark_load_path_from_call(call, errors) {
            Some(raw_path) => {
              let resolved = starlark_resolve_load_path(normalized, raw_path)
              starlark_collect_calls_from_fs(
                resolved, adapter, calls, errors, visiting, loaded, stack,
              )
            }
            None => ()
          }
        } else {
          calls.push(call)
        }
      }
    }
    None => errors.push("failed to read loaded file: " + normalized)
  }

  stack.pop() |> ignore
  visiting[normalized] = false
  loaded[normalized] = true
}

///|
fn parse_starlark_subset_from_fs_impl(
  path : String,
  adapter : WorkflowAdapter,
) -> StarlarkParseResult {
  parse_starlark_subset_from_fs_with_inputs_impl(path, adapter, {})
}

///|
fn parse_starlark_subset_from_fs_with_inputs_impl(
  path : String,
  adapter : WorkflowAdapter,
  external_inputs : Map[String, String],
) -> StarlarkParseResult {
  let normalized = starlark_path_normalize(path)
  if (adapter.fs.exists)(normalized) == false {
    return {
      ir: new_ir("default", [], []),
      errors: ["failed to read workflow file: " + path],
    }
  }

  let calls : Array[StarlarkCall] = []
  let load_errors : Array[String] = []
  let visiting : Map[String, Bool] = {}
  let loaded : Map[String, Bool] = {}
  let stack : Array[String] = []
  starlark_collect_calls_from_fs(
    normalized, adapter, calls, load_errors, visiting, loaded, stack,
  )
  parse_starlark_calls_impl(calls, load_errors, external_inputs)
}
