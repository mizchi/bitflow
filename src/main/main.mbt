///|
pub struct CliRunSpec {
  command : String
  show_help : Bool
  workflow_path : String
  cache_store_path : String
  signatures : Map[String, String]
  success_task_ids : Array[String]
  errors : Array[String]
}

///|
fn drop_program_name(raw_args : Array[String]) -> Array[String] {
  if raw_args.length() <= 1 {
    return []
  }
  let args : Array[String] = []
  for i in 1..<raw_args.length() {
    args.push(raw_args[i])
  }
  args
}

///|
pub fn parse_main_cli_args(raw_args : Array[String]) -> CliRunSpec {
  let args = drop_program_name(raw_args)
  let errors : Array[String] = []
  let signature_result = @wf.parse_external_inputs(
    args,
    {},
    cli_flag="--signature",
    env_prefix="BITFLOW_SIGNATURE_",
  )
  for _err in signature_result.errors {
    errors.push("option --signature expects key=value")
  }
  let mut command = "check"
  let mut show_help = false
  let mut workflow_path = ""
  let mut cache_store_path = ""
  let success_task_ids : Array[String] = []
  let mut i = 0
  if args.length() > 0 &&
    (
      args[0] == "check" ||
      args[0] == "cache-plan" ||
      args[0] == "cache-writeback"
    ) {
    command = args[0]
    i += 1
  }
  while i < args.length() {
    let arg = args[i]
    if arg == "-h" || arg == "--help" {
      show_help = true
      i += 1
      continue
    }
    if arg == "--var" {
      if i + 1 >= args.length() {
        errors.push("option --var expects key=value")
        i += 1
      } else {
        i += 2
      }
      continue
    }
    if arg.has_prefix("--var=") {
      i += 1
      continue
    }
    if arg == "--signature" {
      if i + 1 >= args.length() {
        errors.push("option --signature expects key=value")
        i += 1
      } else {
        i += 2
      }
      continue
    }
    if arg.has_prefix("--signature=") {
      i += 1
      continue
    }
    if arg == "--cache-store" {
      if i + 1 >= args.length() {
        errors.push("option --cache-store expects path")
        i += 1
      } else {
        cache_store_path = args[i + 1]
        i += 2
      }
      continue
    }
    if arg.has_prefix("--cache-store=") {
      cache_store_path = String::unsafe_substring(
        arg,
        start="--cache-store=".length(),
        end=arg.length(),
      )
      if cache_store_path.length() == 0 {
        errors.push("option --cache-store expects path")
      }
      i += 1
      continue
    }
    if arg == "--success" {
      if i + 1 >= args.length() {
        errors.push("option --success expects task id")
        i += 1
      } else {
        success_task_ids.push(args[i + 1])
        i += 2
      }
      continue
    }
    if arg.has_prefix("--success=") {
      let task_id = String::unsafe_substring(
        arg,
        start="--success=".length(),
        end=arg.length(),
      )
      if task_id.length() == 0 {
        errors.push("option --success expects task id")
      } else {
        success_task_ids.push(task_id)
      }
      i += 1
      continue
    }
    if arg.has_prefix("-") {
      errors.push("unknown option: " + arg)
      i += 1
      continue
    }
    if workflow_path.length() == 0 {
      workflow_path = arg
    } else {
      errors.push("multiple workflow paths: '\{workflow_path}' and '\{arg}'")
    }
    i += 1
  }
  if !show_help && workflow_path.length() == 0 {
    errors.push("workflow path is required")
  }
  if !show_help &&
    (command == "cache-plan" || command == "cache-writeback") &&
    cache_store_path.length() == 0 {
    errors.push("option --cache-store is required")
  }
  {
    command,
    show_help,
    workflow_path,
    cache_store_path,
    signatures: signature_result.values,
    success_task_ids,
    errors,
  }
}

///|
fn host_fs_adapter() -> @wf.FsAdapter {
  @wf.FsAdapter::new(
    fn(path : String) {
      try @xfs.read_file_to_string(path) catch {
        _ => None
      } noraise {
        text => Some(text)
      }
    },
    fn(path : String, content : String) {
      try @xfs.write_string_to_file(path, content) catch {
        _ => false
      } noraise {
        _ => true
      }
    },
    fn(path : String) { @xfs.path_exists(path) },
    fn() -> Array[String] { [] },
  )
}

///|
fn print_usage() -> Unit {
  println("Usage: bitflow [check] <workflow.star> [--var KEY=VALUE]...")
  println(
    "       bitflow cache-plan <workflow.star> --cache-store <path> [--signature KEY=VALUE]...",
  )
  println(
    "       bitflow cache-writeback <workflow.star> --cache-store <path> [--signature KEY=VALUE] [--success TASK_ID]...",
  )
  println("Env override: BITFLOW_VAR_<name>=<value>")
}

///|
fn print_parse_errors(errors : Array[String]) -> Unit {
  for err in errors {
    println("error: " + err)
  }
}

///|
fn main {
  let raw_args = @xsys.get_cli_args()
  let spec = parse_main_cli_args(raw_args)
  if spec.show_help {
    print_usage()
    return
  }
  if spec.errors.length() > 0 {
    print_parse_errors(spec.errors)
    print_usage()
    @xsys.exit(2)
  }
  let adapter = @wf.WorkflowAdapter::new(
    host_fs_adapter(),
    @wf.CommandAdapter::none(),
  )
  if spec.command == "cache-plan" {
    let cache_store = @wf.read_flow_cache_store(spec.cache_store_path, adapter)
    let planned : @wf.FlowTaskCachePlanResult = if cache_store.issues.length() >
      0 {
      @wf.new_task_cache_plan_result([], cache_store.issues)
    } else {
      @wf.plan_task_cache_from_fs_with_cli_env(
        spec.workflow_path,
        adapter,
        spec.signatures,
        cache_store.entries,
        drop_program_name(raw_args),
        @xsys.get_env_vars(),
      )
    }
    println(@wf.render_task_cache_plan_json(planned))
    if planned.issues.length() > 0 {
      @xsys.exit(1)
    }
    return
  }
  if spec.command == "cache-writeback" {
    let cache_store = @wf.read_flow_cache_store(spec.cache_store_path, adapter)
    let writeback : @wf.FlowTaskCacheWritebackResult = if cache_store.issues.length() >
      0 {
      @wf.new_task_cache_writeback_result({}, [], cache_store.issues)
    } else {
      @wf.writeback_task_cache_from_fs_with_cli_env(
        spec.workflow_path,
        adapter,
        spec.signatures,
        cache_store.entries,
        spec.success_task_ids,
        drop_program_name(raw_args),
        @xsys.get_env_vars(),
      )
    }
    let persisted = if writeback.issues.length() == 0 {
      @wf.write_flow_cache_store(
        spec.cache_store_path,
        writeback.entries,
        adapter,
      )
    } else {
      true
    }
    let final_writeback = if !persisted {
      @wf.new_task_cache_writeback_result(
        writeback.entries,
        writeback.updated,
        ["failed to write cache store '\{spec.cache_store_path}'"],
      )
    } else {
      writeback
    }
    println(@wf.render_task_cache_writeback_json(final_writeback))
    if final_writeback.issues.length() > 0 {
      @xsys.exit(1)
    }
    return
  }
  let parsed = @wf.parse_from_fs_with_cli_env(
    spec.workflow_path,
    adapter,
    drop_program_name(raw_args),
    @xsys.get_env_vars(),
  )
  if parsed.errors.length() > 0 {
    print_parse_errors(parsed.errors)
    @xsys.exit(1)
  }
  println("workflow=\{parsed.ir.name}")
  println("nodes=\{parsed.ir.nodes.length().to_string()}")
  println("tasks=\{parsed.ir.tasks.length().to_string()}")
}

///|
test "main cli: parses check command with workflow path and var flags" {
  let spec = parse_main_cli_args([
    "bitflow", "check", "workflow.star", "--var", "profile=prod", "--var=retries=3",
  ])
  assert_eq(spec.command, "check")
  assert_eq(spec.show_help, false)
  assert_eq(spec.workflow_path, "workflow.star")
  assert_eq(spec.cache_store_path, "")
  assert_eq(spec.signatures.length(), 0)
  assert_eq(spec.success_task_ids.length(), 0)
  assert_eq(spec.errors.length(), 0)
}

///|
test "main cli: reports missing workflow path and malformed var option" {
  let spec = parse_main_cli_args(["bitflow", "--var"])
  let text = spec.errors.join("\n")
  assert_true(text.contains("option --var expects key=value"))
  assert_true(text.contains("workflow path is required"))
}

///|
test "main cli: accepts help flag without workflow path" {
  let spec = parse_main_cli_args(["bitflow", "--help"])
  assert_eq(spec.show_help, true)
  assert_eq(spec.errors.length(), 0)
}

///|
test "main cli: reports unknown option and multiple workflow paths" {
  let spec = parse_main_cli_args([
    "bitflow", "--unknown", "workflow.star", "other.star",
  ])
  let text = spec.errors.join("\n")
  assert_true(text.contains("unknown option"))
  assert_true(text.contains("multiple workflow paths"))
}

///|
test "main cli: parses cache-plan command with cache store and signatures" {
  let spec = parse_main_cli_args([
    "bitflow", "cache-plan", "workflow.star", "--cache-store", "cache.json", "--signature",
    "root=sig-root", "--signature=dep=sig-dep",
  ])
  assert_eq(spec.command, "cache-plan")
  assert_eq(spec.workflow_path, "workflow.star")
  assert_eq(spec.cache_store_path, "cache.json")
  assert_eq(spec.signatures.get("root"), Some("sig-root"))
  assert_eq(spec.signatures.get("dep"), Some("sig-dep"))
  assert_eq(spec.errors.length(), 0)
}

///|
test "main cli: cache-plan requires cache store and well-formed signatures" {
  let spec = parse_main_cli_args([
    "bitflow", "cache-plan", "workflow.star", "--signature", "broken",
  ])
  let text = spec.errors.join("\n")
  assert_true(text.contains("option --signature expects key=value"))
  assert_true(text.contains("option --cache-store is required"))
}

///|
test "main cli: parses cache-writeback command with success tasks" {
  let spec = parse_main_cli_args([
    "bitflow", "cache-writeback", "workflow.star", "--cache-store=cache.json", "--signature=root=sig-root",
    "--success", "root:build", "--success=dep:test",
  ])
  assert_eq(spec.command, "cache-writeback")
  assert_eq(spec.workflow_path, "workflow.star")
  assert_eq(spec.cache_store_path, "cache.json")
  assert_eq(spec.signatures.get("root"), Some("sig-root"))
  assert_eq(spec.success_task_ids.length(), 2)
  assert_eq(spec.success_task_ids[0], "root:build")
  assert_eq(spec.success_task_ids[1], "dep:test")
  assert_eq(spec.errors.length(), 0)
}

///|
test "main cli: cache-writeback validates success option arity" {
  let spec = parse_main_cli_args([
    "bitflow", "cache-writeback", "workflow.star", "--cache-store", "cache.json",
    "--success",
  ])
  let text = spec.errors.join("\n")
  assert_true(text.contains("option --success expects task id"))
}
