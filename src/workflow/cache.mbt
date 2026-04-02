///|
pub struct FlowCacheStoreResult {
  entries : Map[String, String]
  issues : Array[String]
}

///|
pub struct FlowTaskCacheWritebackResult {
  entries : Map[String, String]
  updated : Array[String]
  issues : Array[String]
}

///|
pub fn new_task_cache_writeback_result(
  entries : Map[String, String],
  updated : Array[String],
  issues : Array[String],
) -> FlowTaskCacheWritebackResult {
  { entries, updated, issues }
}

///|
fn json_int(value : Int) -> Json {
  Json::number(value.to_double(), repr=value.to_string())
}

///|
fn cache_decision_json(decision : FlowTaskCacheDecision) -> Json {
  let fields : Map[String, Json] = {}
  fields["id"] = Json::string(decision.id)
  fields["cache_key"] = Json::string(decision.cache_key)
  fields["fingerprint"] = Json::string(decision.fingerprint)
  fields["hit"] = Json::boolean(decision.hit)
  Json::object(fields)
}

///|
fn cache_summary_json(result : FlowTaskCachePlanResult) -> Json {
  let mut hits = 0
  for decision in result.decisions {
    if decision.hit {
      hits += 1
    }
  }
  let summary : Map[String, Json] = {}
  summary["tasks"] = json_int(result.decisions.length())
  summary["hits"] = json_int(hits)
  summary["misses"] = json_int(result.decisions.length() - hits)
  Json::object(summary)
}

///|
fn cache_store_json(entries : Map[String, String]) -> Json {
  let fields : Map[String, Json] = {}
  for key, value in entries {
    fields[key] = Json::string(value)
  }
  Json::object(fields)
}

///|
fn string_array_json(values : Array[String]) -> Json {
  let items : Array[Json] = []
  for value in values {
    items.push(Json::string(value))
  }
  Json::array(items)
}

///|
pub fn read_flow_cache_store(
  path : String,
  adapter : WorkflowAdapter,
) -> FlowCacheStoreResult {
  guard (adapter.fs.read_text)(path) is Some(text) else {
    return { entries: {}, issues: [] }
  }
  if trim_ascii_space(text).length() == 0 {
    return { entries: {}, issues: [] }
  }
  try @json.parse(text) catch {
    err =>
      {
        entries: {},
        issues: ["failed to parse cache store '\{path}': \{err.to_string()}"],
      }
  } noraise {
    doc =>
      try {
        let entries : Map[String, String] = @json.from_json(doc)
        { entries, issues: [] }
      } catch {
        err =>
          {
            entries: {},
            issues: [
              "failed to decode cache store '\{path}': \{err.to_string()}",
            ],
          }
      }
  }
}

///|
pub fn write_flow_cache_store(
  path : String,
  entries : Map[String, String],
  adapter : WorkflowAdapter,
) -> Bool {
  (adapter.fs.write_text)(path, cache_store_json(entries).stringify(indent=2))
}

///|
pub fn render_task_cache_plan_json(result : FlowTaskCachePlanResult) -> String {
  let decisions : Array[Json] = []
  for decision in result.decisions {
    decisions.push(cache_decision_json(decision))
  }
  let issues : Array[Json] = []
  for issue in result.issues {
    issues.push(Json::string(issue))
  }
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(result.issues.length() == 0)
  root["summary"] = cache_summary_json(result)
  root["decisions"] = Json::array(decisions)
  root["issues"] = Json::array(issues)
  Json::object(root).stringify(indent=2)
}

///|
fn cache_writeback_summary_json(result : FlowTaskCacheWritebackResult) -> Json {
  let summary : Map[String, Json] = {}
  summary["updated"] = json_int(result.updated.length())
  summary["entries"] = json_int(result.entries.length())
  Json::object(summary)
}

///|
pub fn render_task_cache_writeback_json(
  result : FlowTaskCacheWritebackResult,
) -> String {
  let issues : Array[Json] = []
  for issue in result.issues {
    issues.push(Json::string(issue))
  }
  let root : Map[String, Json] = {}
  root["ok"] = Json::boolean(result.issues.length() == 0)
  root["summary"] = cache_writeback_summary_json(result)
  root["updated_task_ids"] = string_array_json(result.updated)
  root["issues"] = Json::array(issues)
  Json::object(root).stringify(indent=2)
}

///|
pub fn write_task_cache_plan_json(
  path : String,
  result : FlowTaskCachePlanResult,
  adapter : WorkflowAdapter,
) -> Bool {
  (adapter.fs.write_text)(path, render_task_cache_plan_json(result))
}

///|
pub fn writeback_task_cache(
  ir : FlowIr,
  signatures : Map[String, String],
  cache_entries : Map[String, String],
  successful_task_ids : Array[String],
) -> FlowTaskCacheWritebackResult {
  let issues = ir_issues(ir)
  let entries = cache_entries.copy()
  if issues.length() > 0 {
    return new_task_cache_writeback_result(entries, [], issues)
  }
  let tasks = task_node_map(ir.tasks)
  let nodes = node_id_map(ir.nodes)
  let updated : Array[String] = []
  for task_id in successful_task_ids {
    if updated.contains(task_id) {
      continue
    }
    guard tasks.get(task_id) is Some(task) else {
      issues.push("cache writeback task '\{task_id}' is unknown")
      continue
    }
    guard nodes.get(task.node) is Some(node) else {
      issues.push(
        "cache writeback task '\{task_id}' has unknown node '\{task.node}'",
      )
      continue
    }
    entries[flow_cache_key(task.id, task.node)] = flow_task_fingerprint(
      task, node, signatures,
    )
    updated.push(task_id)
  }
  new_task_cache_writeback_result(entries, updated, issues)
}

///|
pub fn plan_task_cache_from_fs(
  path : String,
  adapter : WorkflowAdapter,
  signatures : Map[String, String],
  cache_entries : Map[String, String],
) -> FlowTaskCachePlanResult {
  let parsed = parse_from_fs(path, adapter)
  if parsed.errors.length() > 0 {
    return { decisions: [], issues: parsed.errors }
  }
  plan_task_cache(parsed.ir, signatures, cache_entries)
}

///|
pub fn writeback_task_cache_from_fs(
  path : String,
  adapter : WorkflowAdapter,
  signatures : Map[String, String],
  cache_entries : Map[String, String],
  successful_task_ids : Array[String],
) -> FlowTaskCacheWritebackResult {
  let parsed = parse_from_fs(path, adapter)
  if parsed.errors.length() > 0 {
    return new_task_cache_writeback_result(
      cache_entries.copy(),
      [],
      parsed.errors,
    )
  }
  writeback_task_cache(
    parsed.ir,
    signatures,
    cache_entries,
    successful_task_ids,
  )
}

///|
pub fn plan_task_cache_from_fs_with_inputs(
  path : String,
  adapter : WorkflowAdapter,
  signatures : Map[String, String],
  cache_entries : Map[String, String],
  external_inputs : Map[String, String],
) -> FlowTaskCachePlanResult {
  let parsed = parse_from_fs_with_inputs(path, adapter, external_inputs)
  if parsed.errors.length() > 0 {
    return { decisions: [], issues: parsed.errors }
  }
  plan_task_cache(parsed.ir, signatures, cache_entries)
}

///|
pub fn writeback_task_cache_from_fs_with_inputs(
  path : String,
  adapter : WorkflowAdapter,
  signatures : Map[String, String],
  cache_entries : Map[String, String],
  successful_task_ids : Array[String],
  external_inputs : Map[String, String],
) -> FlowTaskCacheWritebackResult {
  let parsed = parse_from_fs_with_inputs(path, adapter, external_inputs)
  if parsed.errors.length() > 0 {
    return new_task_cache_writeback_result(
      cache_entries.copy(),
      [],
      parsed.errors,
    )
  }
  writeback_task_cache(
    parsed.ir,
    signatures,
    cache_entries,
    successful_task_ids,
  )
}

///|
pub fn plan_task_cache_from_fs_with_cli_env(
  path : String,
  adapter : WorkflowAdapter,
  signatures : Map[String, String],
  cache_entries : Map[String, String],
  cli_args : Array[String],
  env : Map[String, String],
  cli_flag? : String = "--var",
  env_prefix? : String = "BITFLOW_VAR_",
) -> FlowTaskCachePlanResult {
  let parsed = parse_from_fs_with_cli_env(
    path,
    adapter,
    cli_args,
    env,
    cli_flag~,
    env_prefix~,
  )
  if parsed.errors.length() > 0 {
    return { decisions: [], issues: parsed.errors }
  }
  plan_task_cache(parsed.ir, signatures, cache_entries)
}

///|
pub fn writeback_task_cache_from_fs_with_cli_env(
  path : String,
  adapter : WorkflowAdapter,
  signatures : Map[String, String],
  cache_entries : Map[String, String],
  successful_task_ids : Array[String],
  cli_args : Array[String],
  env : Map[String, String],
  cli_flag? : String = "--var",
  env_prefix? : String = "BITFLOW_VAR_",
) -> FlowTaskCacheWritebackResult {
  let parsed = parse_from_fs_with_cli_env(
    path,
    adapter,
    cli_args,
    env,
    cli_flag~,
    env_prefix~,
  )
  if parsed.errors.length() > 0 {
    return new_task_cache_writeback_result(
      cache_entries.copy(),
      [],
      parsed.errors,
    )
  }
  writeback_task_cache(
    parsed.ir,
    signatures,
    cache_entries,
    successful_task_ids,
  )
}
