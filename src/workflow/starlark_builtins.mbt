///|
priv struct StarlarkBuiltinArgSpec {
  name : String
  required : Bool
}

///|
priv struct StarlarkBuiltinSpec {
  canonical_name : String
  names : Array[String]
  args : Array[StarlarkBuiltinArgSpec]
}

///|
fn starlark_builtin_arg(
  name : String,
  required? : Bool = false,
) -> StarlarkBuiltinArgSpec {
  { name, required }
}

///|
fn starlark_builtin_specs() -> Array[StarlarkBuiltinSpec] {
  [
    {
      canonical_name: "workflow",
      names: ["workflow"],
      args: [starlark_builtin_arg("name"), starlark_builtin_arg("max_parallel")],
    },
    {
      canonical_name: "node",
      names: ["node"],
      args: [
        starlark_builtin_arg("id", required=true),
        starlark_builtin_arg("depends_on"),
        starlark_builtin_arg("required"),
      ],
    },
    {
      canonical_name: "task",
      names: ["task", "target"],
      args: [
        starlark_builtin_arg("id", required=true),
        starlark_builtin_arg("node", required=true),
        starlark_builtin_arg("cmd", required=true),
        starlark_builtin_arg("needs"),
        starlark_builtin_arg("required"),
        starlark_builtin_arg("srcs"),
        starlark_builtin_arg("outs"),
        starlark_builtin_arg("env"),
        starlark_builtin_arg("cwd"),
        starlark_builtin_arg("trigger"),
      ],
    },
    {
      canonical_name: "entrypoint",
      names: ["entrypoint"],
      args: [starlark_builtin_arg("targets", required=true)],
    },
    {
      canonical_name: "var",
      names: ["var"],
      args: [
        starlark_builtin_arg("name", required=true),
        starlark_builtin_arg("type"),
        starlark_builtin_arg("required"),
        starlark_builtin_arg("default", required=true),
      ],
    },
    {
      canonical_name: "config",
      names: ["config"],
      args: [
        starlark_builtin_arg("name", required=true),
        starlark_builtin_arg("value", required=true),
      ],
    },
    {
      canonical_name: "load",
      names: ["load"],
      args: [starlark_builtin_arg("path", required=true)],
    },
    {
      canonical_name: "__assign__",
      names: ["__assign__"],
      args: [
        starlark_builtin_arg("name", required=true),
        starlark_builtin_arg("value", required=true),
      ],
    },
  ]
}

///|
fn starlark_builtin_spec_for(name : String) -> StarlarkBuiltinSpec? {
  for spec in starlark_builtin_specs() {
    if spec.names.contains(name) {
      return Some(spec)
    }
  }
  None
}

///|
fn starlark_builtin_canonical_name(name : String) -> String {
  match starlark_builtin_spec_for(name) {
    Some(spec) => spec.canonical_name
    None => name
  }
}

///|
fn starlark_builtin_allowed_args(name : String) -> Array[String] {
  match starlark_builtin_spec_for(name) {
    Some(spec) => {
      let args : Array[String] = []
      for arg in spec.args {
        args.push(arg.name)
      }
      args
    }
    None => []
  }
}

///|
fn starlark_builtin_required_args(name : String) -> Array[String] {
  match starlark_builtin_spec_for(name) {
    Some(spec) => {
      let args : Array[String] = []
      for arg in spec.args {
        if arg.required {
          args.push(arg.name)
        }
      }
      args
    }
    None => []
  }
}
