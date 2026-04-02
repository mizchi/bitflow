///|
test "workflow cache: reads and writes cache store json" {
  let entries : Map[String, String] = {}
  entries[flow_cache_key("root:build", "root")] = "fp-root"
  entries[flow_cache_key("dep:test", "dep")] = "fp-dep"
  let adapter = WorkflowAdapter::new(
    FsAdapter::memory(),
    CommandAdapter::none(),
  )
  assert_eq(write_flow_cache_store("cache.json", entries, adapter), true)
  let stored = (adapter.fs.read_text)("cache.json")
  assert_true(stored is Some(_))
  match stored {
    Some(text) => {
      assert_true(@json.valid(text))
      let loaded = read_flow_cache_store("cache.json", adapter)
      assert_eq(loaded.issues.length(), 0)
      assert_eq(loaded.entries, entries)
    }
    None => assert_true(false)
  }
}

///|
test "workflow cache: invalid store json reports issue" {
  let adapter = WorkflowAdapter::new(
    FsAdapter::memory_with({ "cache.json": "{ invalid" }),
    CommandAdapter::none(),
  )
  let loaded = read_flow_cache_store("cache.json", adapter)
  assert_eq(loaded.entries.length(), 0)
  assert_true(loaded.issues.length() > 0)
  assert_true(loaded.issues[0].contains("cache.json"))
}

///|
test "workflow cache: cache plan json is structured and valid" {
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("dep:test", "dep", "test", ["root:build"]),
  ]
  let ir = new_ir("ci", nodes, tasks, entry_targets=["dep:test"])
  let signatures : Map[String, String] = {
    "root": "sig-root",
    "dep": "sig-dep",
  }
  let cache : Map[String, String] = {}
  cache[flow_cache_key("root:build", "root")] = flow_task_fingerprint(
    tasks[0],
    nodes[0],
    signatures,
  )
  let planned = plan_task_cache(ir, signatures, cache)
  let text = render_task_cache_plan_json(planned)
  assert_true(@json.valid(text))
  assert_true(text.contains("\"ok\": true"))
  assert_true(text.contains("\"hits\": 1"))
  assert_true(text.contains("\"misses\": 1"))
  assert_true(text.contains("\"cache_key\": \"root:build::root\""))
}

///|
test "workflow cache: plan_task_cache_from_fs uses parsed workflow and cache entries" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let adapter = WorkflowAdapter::new(
    FsAdapter::memory_with({ "workflow.star": src }),
    CommandAdapter::none(),
  )
  let parsed = parse_from_fs("workflow.star", adapter)
  assert_eq(parsed.errors.length(), 0)
  let signatures : Map[String, String] = { "root": "sig-root" }
  let cache : Map[String, String] = {}
  cache[flow_cache_key("root:build", "root")] = flow_task_fingerprint(
    parsed.ir.tasks[0],
    parsed.ir.nodes[0],
    signatures,
  )
  let planned = plan_task_cache_from_fs(
    "workflow.star", adapter, signatures, cache,
  )
  assert_eq(planned.issues.length(), 0)
  assert_eq(planned.decisions.length(), 1)
  assert_eq(planned.decisions[0].hit, true)
}

///|
test "workflow cache: writeback updates successful task fingerprints into entries" {
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("dep:test", "dep", "test", ["root:build"]),
  ]
  let ir = new_ir("ci", nodes, tasks, entry_targets=["dep:test"])
  let signatures : Map[String, String] = {
    "root": "sig-root",
    "dep": "sig-dep",
  }
  let cache : Map[String, String] = { "keep::existing": "fp-existing" }
  let writeback = writeback_task_cache(ir, signatures, cache, [
    "root:build", "dep:test",
  ])
  assert_eq(writeback.issues.length(), 0)
  assert_eq(writeback.updated.length(), 2)
  assert_eq(writeback.entries.get("keep::existing"), Some("fp-existing"))
  assert_eq(
    writeback.entries.get(flow_cache_key("root:build", "root")),
    Some(flow_task_fingerprint(tasks[0], nodes[0], signatures)),
  )
  assert_eq(
    writeback.entries.get(flow_cache_key("dep:test", "dep")),
    Some(flow_task_fingerprint(tasks[1], nodes[1], signatures)),
  )
}

///|
test "workflow cache: writeback reports unknown task ids" {
  let ir = new_ir("ci", [new_node("root", [])], [
    new_task("root:build", "root", "build", []),
  ])
  let writeback = writeback_task_cache(ir, { "root": "sig-root" }, {}, [
    "missing:task",
  ])
  assert_eq(writeback.updated.length(), 0)
  assert_true(writeback.issues.length() > 0)
  assert_true(writeback.issues[0].contains("missing:task"))
}

///|
test "workflow cache: writeback json is structured and valid" {
  let ir = new_ir("ci", [new_node("root", [])], [
    new_task("root:build", "root", "build", []),
  ])
  let writeback = writeback_task_cache(ir, { "root": "sig-root" }, {}, [
    "root:build",
  ])
  let text = render_task_cache_writeback_json(writeback)
  assert_true(@json.valid(text))
  assert_true(text.contains("\"ok\": true"))
  assert_true(text.contains("\"updated\": 1"))
  assert_true(text.contains("\"root:build\""))
}

///|
test "workflow cache: writeback roundtrip turns next plan into hit" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let adapter = WorkflowAdapter::new(
    FsAdapter::memory_with({ "workflow.star": src }),
    CommandAdapter::none(),
  )
  let signatures : Map[String, String] = { "root": "sig-root" }

  let first_plan = plan_task_cache_from_fs(
    "workflow.star",
    adapter,
    signatures,
    {},
  )
  assert_eq(first_plan.issues.length(), 0)
  assert_eq(first_plan.decisions.length(), 1)
  assert_eq(first_plan.decisions[0].hit, false)

  let writeback = writeback_task_cache_from_fs(
    "workflow.star",
    adapter,
    signatures,
    {},
    ["root:build"],
  )
  assert_eq(writeback.issues.length(), 0)
  assert_eq(writeback.updated.length(), 1)
  assert_eq(
    write_flow_cache_store("cache.json", writeback.entries, adapter),
    true,
  )

  let loaded = read_flow_cache_store("cache.json", adapter)
  assert_eq(loaded.issues.length(), 0)
  let second_plan = plan_task_cache_from_fs(
    "workflow.star",
    adapter,
    signatures,
    loaded.entries,
  )
  assert_eq(second_plan.issues.length(), 0)
  assert_eq(second_plan.decisions.length(), 1)
  assert_eq(second_plan.decisions[0].hit, true)
}
