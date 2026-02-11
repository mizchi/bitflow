///|
fn run_ok(_task : FlowTask) -> (Bool, String) {
  (true, "")
}

///|
fn run_fail(task : FlowTask) -> (Bool, String) {
  if task.id == "dep:test" {
    (false, "dep failed")
  } else {
    (true, "")
  }
}

///|
fn run_optional_fail(task : FlowTask) -> (Bool, String) {
  if task.id == "root:lint" {
    (false, "lint failed")
  } else {
    (true, "")
  }
}

///|
fn trim_ascii_space(s : String) -> String {
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
fn parse_chunk_expected_literal(raw : String) -> String? {
  let text = trim_ascii_space(raw)
  if text.length() < 2 {
    return None
  }
  if text.has_prefix("\"") && text.has_suffix("\"") {
    return Some(String::unsafe_substring(text, start=1, end=text.length() - 1))
  }
  let first = text.unsafe_get(0)
  let last = text.unsafe_get(text.length() - 1)
  if first.to_int() == 96 && last.to_int() == 96 {
    return Some(String::unsafe_substring(text, start=1, end=text.length() - 1))
  }
  None
}

///|
fn parse_chunk_source_line(line : String) -> (String, String?) {
  match line.find("###") {
    Some(idx) => {
      let code = trim_ascii_space(
        String::unsafe_substring(line, start=0, end=idx),
      )
      let expected_text = String::unsafe_substring(
        line,
        start=idx + 3,
        end=line.length(),
      )
      (code, parse_chunk_expected_literal(expected_text))
    }
    None => (trim_ascii_space(line), None)
  }
}

///|
fn parse_starlark_go_chunked_cases(text : String) -> Array[(String, String?)] {
  let lines : Array[String] = []
  for view in text.split("\n") {
    lines.push(view.to_string())
  }
  // Sentinel delimiter to flush last case.
  lines.push("---")

  let cases : Array[(String, String?)] = []
  let mut current_lines : Array[String] = []
  let mut current_expected : String? = None

  for raw_line in lines {
    let trimmed = trim_ascii_space(raw_line)
    if trimmed == "---" {
      if current_lines.length() > 0 {
        cases.push((current_lines.join("\n"), current_expected))
      }
      current_lines = []
      current_expected = None
      continue
    }
    if trimmed.length() == 0 {
      continue
    }
    if trimmed.has_prefix("#") && raw_line.find("###") is None {
      continue
    }
    let (code, expected) = parse_chunk_source_line(raw_line)
    if code.length() > 0 {
      current_lines.push(code)
    }
    match expected {
      Some(value) => current_expected = Some(value)
      None => ()
    }
  }
  cases
}

///|
fn starlark_go_errors_subset_chunked_embedded() -> String {
  let text =
    #|# source=embedded-fallback
    #|workflow(1+2 = 3) ### "keyword argument must have form name=expr"
    #|---
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", *, needs=[]) ### "splat arguments are not supported"
    #|---
    #|workflow(name="ci",
    #|### "expected ')' to close argument list"
    #|---
    #|workflow(name="ci",)
    #|node(id="root", depends_on=[],)
    #|task(id="root:build", node="root", cmd="build", needs=[],)
    #|entrypoint(targets=["root:build"],)
    #|---
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="\x-0", needs=[]) ### "invalid escape sequence"
  text
}

///|
#cfg(target="js")
extern "js" fn read_starlark_go_errors_subset_from_fs() -> String? =
  #| function() {
  #|   try {
  #|     const fs = require("node:fs");
  #|     const path = require("node:path");
  #|     const cwd = (typeof process !== "undefined" && typeof process.cwd === "function")
  #|       ? process.cwd()
  #|       : ".";
  #|     const candidates = [
  #|       path.join(cwd, "src/workflow/testdata/starlark_go_errors_subset.star"),
  #|       path.join(cwd, "../src/workflow/testdata/starlark_go_errors_subset.star"),
  #|       path.join(cwd, "../../src/workflow/testdata/starlark_go_errors_subset.star"),
  #|       "src/workflow/testdata/starlark_go_errors_subset.star",
  #|     ];
  #|     for (const p of candidates) {
  #|       if (fs.existsSync(p)) {
  #|         return fs.readFileSync(p, "utf8");
  #|       }
  #|     }
  #|     return null;
  #|   } catch (_err) {
  #|     return null;
  #|   }
  #| }

///|
#cfg(target="js")
fn starlark_go_errors_subset_chunked() -> String {
  let fallback = starlark_go_errors_subset_chunked_embedded()
  match read_starlark_go_errors_subset_from_fs() {
    Some(text) => text
    None => fallback
  }
}

///|
#cfg(not(target="js"))
fn starlark_go_errors_subset_chunked() -> String {
  starlark_go_errors_subset_chunked_embedded()
}

///|
#cfg(target="js")
fn expected_starlark_go_errors_source_marker() -> String {
  "# source=external-file"
}

///|
#cfg(not(target="js"))
fn expected_starlark_go_errors_source_marker() -> String {
  "# source=embedded-fallback"
}

///|
test "workflow engine: direct API executes topological tasks" {
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("dep:test", "dep", "test", ["root:build"]),
  ]
  let ir = new_ir(
    "ci",
    nodes,
    tasks,
    entry_targets=["dep:test"],
    max_parallel=2,
  )
  let result = execute_ir(ir, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.state, "completed")
  assert_eq(result.order.length(), 2)
  assert_eq(result.steps[0].status, "success")
  assert_eq(result.steps[1].status, "success")
}

///|
test "workflow engine: required failure blocks dependent task" {
  let nodes = [
    new_node("root", []),
    new_node("dep", ["root"]),
    new_node("leaf", ["dep"]),
  ]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("dep:test", "dep", "test", ["root:build"]),
    new_task("leaf:deploy", "leaf", "deploy", ["dep:test"]),
  ]
  let ir = new_ir("ci", nodes, tasks)
  let result = execute_ir(ir, run_fail)
  assert_eq(result.ok, false)
  assert_eq(result.state, "partial_failed")
  let text = result.steps.map(step => step.id + ":" + step.status).join("\n")
  assert_true(text.contains("dep:test:failed"))
  assert_true(text.contains("leaf:deploy:blocked"))
}

///|
test "workflow engine: entry target executes only transitive dependencies" {
  let nodes = [
    new_node("root", []),
    new_node("dep", ["root"]),
    new_node("extra", []),
  ]
  let tasks = [
    new_task("root:build", "root", "build", []),
    new_task("dep:test", "dep", "test", ["root:build"]),
    new_task("extra:lint", "extra", "lint", []),
  ]
  let ir = new_ir("ci", nodes, tasks, entry_targets=["dep:test"])
  let result = execute_ir(ir, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.order.length(), 2)
  assert_true(result.order.contains("root:build"))
  assert_true(result.order.contains("dep:test"))
  assert_eq(result.order.contains("extra:lint"), false)
}

///|
test "workflow engine: optional task failure keeps workflow completed" {
  let nodes = [new_node("root", []), new_node("dep", ["root"])]
  let tasks = [
    new_task("root:lint", "root", "lint", [], required=false),
    new_task("dep:test", "dep", "test", [], required=true),
  ]
  let ir = new_ir("ci", nodes, tasks)
  let result = execute_ir(ir, run_optional_fail)
  assert_eq(result.ok, true)
  assert_eq(result.state, "completed")
  let text = result.steps.map(step => step.id + ":" + step.status).join("\n")
  assert_true(text.contains("root:lint:failed"))
  assert_true(text.contains("dep:test:success"))
}

///|
test "workflow engine: execute_ir returns invalid when ir has issues" {
  let nodes = [new_node("root", ["missing"])]
  let tasks = [new_task("root:test", "unknown", "test", ["missing:task"])]
  let ir = new_ir("ci", nodes, tasks, entry_targets=["missing:target"])
  let result = execute_ir(ir, run_ok)
  assert_eq(result.ok, false)
  assert_eq(result.state, "invalid")
  assert_eq(result.steps.length(), 0)
  assert_true(result.issues.length() >= 3)
  let text = result.issues.join("\n")
  assert_true(
    text.contains("node: node 'root' depends on unknown node 'missing'"),
  )
  assert_true(text.contains("targets unknown node"))
  assert_true(text.contains("depends on unknown task"))
  assert_true(text.contains("entry target 'missing:target' does not exist"))
}

///|
test "workflow engine: starlark subset parses and runs" {
  let src =
    #|workflow(name="ci", max_parallel=4)
    #|node(id="root", depends_on=[])
    #|node(id="dep", depends_on=["root"])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|task(id="dep:test", node="dep", cmd="test", needs=["root:build"])
    #|entrypoint(targets=["dep:test"])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.nodes.length(), 2)
  assert_eq(parsed.ir.tasks.length(), 2)
  let result = execute_ir(parsed.ir, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.steps.length(), 2)
}

///|
test "workflow engine: starlark subset parser reports unknown function" {
  let src =
    #|workflow(name="ci")
    #|unknown_call(x="y")
  let parsed = parse_starlark_subset(src)
  assert_true(parsed.errors.length() > 0)
  assert_true(parsed.errors.join("\n").contains("unknown statement"))
}

///|
test "workflow engine: starlark parser supports cmd array and inline comments" {
  let src =
    #|workflow(name="ci") # inline comment
    #|node(id="root", depends_on=[])
    #|task(id="root:test", node="root", cmd=["just", "test"], needs=[]) # tail comment
    #|entrypoint(targets=["root:test"])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.tasks.length(), 1)
  assert_eq(parsed.ir.tasks[0].cmd, "just test")
  let result = execute_ir(parsed.ir, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.steps.length(), 1)
}

///|
test "workflow engine: execute_starlark_subset runs parsed workflow directly" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let result = execute_starlark_subset(src, run_ok)
  assert_eq(result.ok, true)
  assert_eq(result.state, "completed")
  assert_eq(result.order.length(), 1)
  assert_eq(result.steps[0].status, "success")
}

///|
test "workflow engine: starlark compatibility accepts semicolon separated calls" {
  let src =
    #|workflow(name='ci'); node(id='root', depends_on=[]); task(id='root:build', node='root', cmd='build', needs=[]); entrypoint(targets=['root:build'])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.name, "ci")
  assert_eq(parsed.ir.nodes.length(), 1)
  assert_eq(parsed.ir.tasks.length(), 1)
  assert_eq(parsed.ir.entry_targets.length(), 1)
}

///|
test "workflow engine: starlark compatibility accepts trailing comma in call args" {
  let src =
    #|workflow(name="ci",)
    #|node(id="root", depends_on=[],)
    #|task(id="root:test", node="root", cmd=["just", "test",], needs=[],)
    #|entrypoint(targets=["root:test"],)
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.tasks.length(), 1)
  assert_eq(parsed.ir.tasks[0].cmd, "just test")
}

///|
test "workflow engine: starlark compatibility supports single quote and bool literal" {
  let src =
    #|workflow(name='ci')
    #|node(id='root', depends_on=[], required=False)
    #|task(id='root:lint', node='root', cmd='lint', needs=[], required=True)
    #|entrypoint(targets=['root:lint'])
  let parsed = parse_starlark_subset(src)
  assert_eq(parsed.errors.length(), 0)
  assert_eq(parsed.ir.nodes.length(), 1)
  assert_eq(parsed.ir.nodes[0].required, false)
  assert_eq(parsed.ir.tasks[0].required, true)
}

///|
test "workflow engine: starlark semantics rejects unknown keyword argument" {
  let src =
    #|workflow(name="ci", unknown=1)
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|entrypoint(targets=["root:build"])
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("unknown argument"))
}

///|
test "workflow engine: starlark semantics rejects duplicate keyword argument" {
  let src =
    #|workflow(name="ci", name="prod")
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("duplicate argument"))
}

///|
test "workflow engine: starlark semantics validates list element types" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|node(id="dep", depends_on=["root", 1])
    #|task(id="root:build", node="root", cmd="build", needs=[])
    #|task(id="dep:test", node="dep", cmd="test", needs=["root:build"])
    #|entrypoint(targets=["dep:test"])
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("depends_on"))
}

///|
test "workflow engine: starlark compatibility rejects splat arguments" {
  let src =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", *, needs=[])
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("splat arguments"))
}

///|
test "workflow engine: starlark compatibility requires name=expr keyword syntax" {
  let src =
    #|workflow(1+2 = 3)
  let parsed = parse_starlark_subset(src)
  let text = parsed.errors.join("\n")
  assert_true(text.contains("keyword argument must have form name=expr"))
}

///|
test "workflow engine: starlark-go errors.star failure subset" {
  // Derived from google/starlark-go/syntax/testdata/errors.star
  let case_keyword_arg =
    #|workflow(1+2 = 3)
  let case_splat =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="build", *, needs=[])
  let case_invalid_escape =
    #|workflow(name="ci")
    #|node(id="root", depends_on=[])
    #|task(id="root:build", node="root", cmd="\x-0", needs=[])
  let case_unclosed_paren =
    #|workflow(name="ci",
  let cases = [
    (case_keyword_arg, "keyword argument must have form name=expr"),
    (case_splat, "splat arguments are not supported"),
    (case_invalid_escape, "invalid escape sequence"),
    (case_unclosed_paren, "expected ')' to close argument list"),
  ]
  for entry in cases {
    let (source, expected) = entry
    let parsed = parse_starlark_subset(source)
    let text = parsed.errors.join("\n")
    assert_true(text.contains(expected))
  }
}

///|
test "workflow engine: starlark-go errors.star trailing comma subset" {
  // Equivalent to "f(a,)" style trailing comma acceptance in errors.star
  let case_trailing_comma_a =
    #|workflow(name="ci",)
    #|node(id="root", depends_on=[],)
    #|task(id="root:build", node="root", cmd="build", needs=[],)
    #|entrypoint(targets=["root:build"],)
  let case_trailing_comma_b =
    #|workflow(name='ci',)
    #|node(id='root', depends_on=['dep',],)
    #|task(id='root:build', node='root', cmd=['just', 'test',], needs=[],)
    #|entrypoint(targets=['root:build',],)
  let cases = [case_trailing_comma_a, case_trailing_comma_b]
  for source in cases {
    let parsed = parse_starlark_subset(source)
    assert_eq(parsed.errors.length(), 0)
  }
}

///|
test "workflow engine: starlark-go chunked errors subset is executable" {
  let chunked_text = starlark_go_errors_subset_chunked()
  let source_marker = expected_starlark_go_errors_source_marker()
  assert_true(chunked_text.contains(source_marker))
  let cases = parse_starlark_go_chunked_cases(chunked_text)
  assert_eq(cases.length(), 5)
  for entry in cases {
    let (source, expected) = entry
    let parsed = parse_starlark_subset(source)
    match expected {
      Some(msg) => assert_true(parsed.errors.join("\n").contains(msg))
      None => assert_eq(parsed.errors.length(), 0)
    }
  }
}
