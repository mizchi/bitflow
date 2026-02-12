///|
fn path_dirname(path : String) -> String {
  match path.rev_find("/") {
    Some(0) => "/"
    Some(idx) => String::unsafe_substring(path, start=0, end=idx)
    None => "."
  }
}

///|
fn path_normalize(path : String) -> String {
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
fn resolve_load_path(base_path : String, raw_path : String) -> String {
  if raw_path.has_prefix("/") {
    path_normalize(raw_path)
  } else {
    let base_dir = path_dirname(base_path)
    if base_dir == "." {
      path_normalize(raw_path)
    } else {
      path_normalize(base_dir + "/" + raw_path)
    }
  }
}

///|
fn workspace_root_from_path(path : String) -> String {
  if path.has_prefix("/") {
    path_dirname(path)
  } else {
    "."
  }
}

///|
fn is_within_workspace_root(workspace_root : String, path : String) -> Bool {
  let root = path_normalize(workspace_root)
  let target = path_normalize(path)
  if root == "." {
    return not(target.has_prefix("..")) && not(target.has_prefix("/"))
  }
  if root == "/" {
    return target.has_prefix("/")
  }
  target == root || target.has_prefix(root + "/")
}

///|
fn load_path_from_call(call : StarlarkCall, errors : Array[String]) -> String? {
  let args = arg_map(call, errors)
  validate_call_shape(call, args, errors)
  guard args.get("path") is Some(target) else { return None }
  match target.value {
    Str(path) => Some(path)
    _ => {
      semantic_error(
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
fn collect_calls_from_fs(
  path : String,
  workspace_root : String,
  read_text : (String) -> String?,
  calls : Array[StarlarkCall],
  errors : Array[String],
  visiting : Map[String, Bool],
  loaded : Map[String, Bool],
  stack : Array[String],
) -> Unit {
  let normalized = path_normalize(path)
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

  match read_text(normalized) {
    Some(text) => {
      let syntax = parse_syntax(text)
      for err in syntax.errors {
        errors.push(normalized + ": " + err)
      }
      for call in syntax.calls {
        if call.name == "load" {
          match load_path_from_call(call, errors) {
            Some(raw_path) => {
              let resolved = resolve_load_path(normalized, raw_path)
              if not(is_within_workspace_root(workspace_root, resolved)) {
                errors.push("load path escapes workspace root: " + resolved)
                continue
              }
              collect_calls_from_fs(
                resolved, workspace_root, read_text, calls, errors, visiting, loaded,
                stack,
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
fn parse_from_fs_impl(
  path : String,
  exists : (String) -> Bool,
  read_text : (String) -> String?,
) -> StarlarkParseResult {
  parse_from_fs_with_inputs_impl(path, exists, read_text, {})
}

///|
fn parse_from_fs_with_inputs_impl(
  path : String,
  exists : (String) -> Bool,
  read_text : (String) -> String?,
  external_inputs : Map[String, String],
) -> StarlarkParseResult {
  let normalized = path_normalize(path)
  let workspace_root = workspace_root_from_path(normalized)
  if exists(normalized) == false {
    return {
      workflow: {
        name: "default",
        max_parallel: 1,
        nodes: [],
        tasks: [],
        entry_targets: [],
      },
      errors: ["failed to read workflow file: " + path],
    }
  }

  let calls : Array[StarlarkCall] = []
  let load_errors : Array[String] = []
  let visiting : Map[String, Bool] = {}
  let loaded : Map[String, Bool] = {}
  let stack : Array[String] = []
  collect_calls_from_fs(
    normalized, workspace_root, read_text, calls, load_errors, visiting, loaded,
    stack,
  )
  parse_calls_impl(calls, load_errors, external_inputs)
}

///|
pub fn parse_from_fs(
  path : String,
  exists : (String) -> Bool,
  read_text : (String) -> String?,
) -> StarlarkParseResult {
  parse_from_fs_impl(path, exists, read_text)
}

///|
pub fn parse_from_fs_with_inputs(
  path : String,
  exists : (String) -> Bool,
  read_text : (String) -> String?,
  external_inputs : Map[String, String],
) -> StarlarkParseResult {
  parse_from_fs_with_inputs_impl(path, exists, read_text, external_inputs)
}
