///|
fn index_map(nodes : Array[@workflow.FlowNode]) -> Map[String, Int] {
  let result : Map[String, Int] = Map([])
  for i in 0..<nodes.length() {
    result[nodes[i].id] = i
  }
  result
}

///|
test "workflow: topological order keeps dependency precedence" {
  let nodes = [
    @workflow.new_node("root", []),
    @workflow.new_node("dep", ["root"]),
    @workflow.new_node("leaf", ["dep"]),
    @workflow.new_node("extra", []),
  ]
  let ordered = @workflow.topological_nodes(nodes)
  let idx = index_map(ordered)
  assert_true(idx.get("root").unwrap_or(-1) < idx.get("dep").unwrap_or(-1))
  assert_true(idx.get("dep").unwrap_or(-1) < idx.get("leaf").unwrap_or(-1))
}

///|
test "workflow: dependency cycle is detectable" {
  let nodes = [
    @workflow.new_node("root", ["dep"]),
    @workflow.new_node("dep", ["root"]),
  ]
  assert_eq(@workflow.has_dependency_cycle(nodes), true)
}

///|
test "workflow: graph issues reports duplicate id and unknown dependency" {
  let nodes = [
    @workflow.new_node("dup", []),
    @workflow.new_node("dup", ["missing"]),
  ]
  let issues = @workflow.graph_issues(nodes)
  let text = issues.join("\n")
  assert_true(text.contains("duplicate node id"))
  assert_true(text.contains("depends on unknown node"))
}

///|
test "workflow: graph issues reports dependency cycle" {
  let nodes = [@workflow.new_node("a", ["b"]), @workflow.new_node("b", ["a"])]
  let text = @workflow.graph_issues(nodes).join("\n")
  assert_true(text.contains("dependency graph has a cycle"))
}

///|
test "workflow: expand affected propagates to neighbors and dependents" {
  let nodes = [
    @workflow.new_node("root", []),
    @workflow.new_node("dep", ["root"]),
    @workflow.new_node("leaf", ["dep"]),
    @workflow.new_node("extra", []),
  ]
  let changed : Map[String, Bool] = { "dep": true }
  let affected = @workflow.expand_affected_nodes(nodes, changed)
  assert_eq(affected.get("root") is Some(_), true)
  assert_eq(affected.get("dep") is Some(_), true)
  assert_eq(affected.get("leaf") is Some(_), true)
  assert_eq(affected.get("extra") is Some(_), false)
}

///|
test "workflow: expand affected ignores unknown initial node ids" {
  let nodes = [
    @workflow.new_node("root", []),
    @workflow.new_node("dep", ["root"]),
  ]
  let affected = @workflow.expand_affected_nodes(nodes, { "unknown": true })
  assert_eq(affected.get("root") is Some(_), false)
  assert_eq(affected.get("dep") is Some(_), false)
}

///|
test "workflow: fingerprint changes when dependency signature changes" {
  let node = @workflow.new_node("pkg", ["root"])
  let signatures : Map[String, String] = { "pkg": "pkg-1", "root": "root-1" }
  let fp1 = @workflow.flow_fingerprint("test", "just test", node, signatures)
  signatures["root"] = "root-2"
  let fp2 = @workflow.flow_fingerprint("test", "just test", node, signatures)
  assert_eq(fp1 == fp2, false)
}

///|
test "workflow: cache key scopes by task and node" {
  assert_eq(@workflow.flow_cache_key("test", "pkg"), "test::pkg")
}
