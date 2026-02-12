///|
priv enum StarlarkValue {
  Str(String)
  Num(Int)
  Bool(Bool)
  List(Array[StarlarkValue])
  Dict(Map[String, StarlarkValue])
  Ref(String)
}

///|
priv struct StarlarkArg {
  name : String
  value : StarlarkValue
  line : Int
  column : Int
}

///|
priv struct StarlarkCall {
  name : String
  args : Array[StarlarkArg]
  line : Int
  column : Int
}

///|
priv struct StarlarkSyntaxResult {
  calls : Array[StarlarkCall]
  errors : Array[String]
}

///|
priv struct StarlarkParser {
  text : String
  mut idx : Int
  mut line : Int
  mut column : Int
  errors : Array[String]
}

///|
fn starlark_parser_new(text : String) -> StarlarkParser {
  { text, idx: 0, line: 1, column: 1, errors: [] }
}

///|
fn StarlarkParser::peek(self : StarlarkParser) -> UInt16? {
  if self.idx >= self.text.length() {
    None
  } else {
    Some(self.text.unsafe_get(self.idx))
  }
}

///|
fn StarlarkParser::advance(self : StarlarkParser) -> UInt16? {
  guard self.idx < self.text.length() else { return None }
  let ch = self.text.unsafe_get(self.idx)
  self.idx += 1
  if ch == '\n' {
    self.line += 1
    self.column = 1
  } else {
    self.column += 1
  }
  Some(ch)
}

///|
fn StarlarkParser::consume_char(self : StarlarkParser, ch : UInt16) -> Bool {
  match self.peek() {
    Some(next) if next == ch => {
      self.advance() |> ignore
      true
    }
    _ => false
  }
}

///|
fn starlark_is_digit(ch : UInt16) -> Bool {
  ch >= '0' && ch <= '9'
}

///|
fn starlark_is_ident_start(ch : UInt16) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
}

///|
fn starlark_is_ident_part(ch : UInt16) -> Bool {
  starlark_is_ident_start(ch) || starlark_is_digit(ch)
}

///|
fn starlark_is_inline_space(ch : UInt16) -> Bool {
  ch == ' ' || ch == '\t' || ch == '\r'
}

///|
fn StarlarkParser::push_error(self : StarlarkParser, msg : String) -> Unit {
  self.errors.push("line \{self.line}, col \{self.column}: " + msg)
}

///|
fn StarlarkParser::skip_inline_space(self : StarlarkParser) -> Unit {
  while self.peek() is Some(ch) {
    if starlark_is_inline_space(ch) {
      self.advance() |> ignore
    } else {
      break
    }
  }
}

///|
fn StarlarkParser::skip_comment(self : StarlarkParser) -> Unit {
  if not(self.consume_char('#')) {
    return
  }
  while self.peek() is Some(ch) {
    if ch == '\n' {
      break
    }
    self.advance() |> ignore
  }
}

///|
fn StarlarkParser::skip_statement_separators(self : StarlarkParser) -> Unit {
  while true {
    let mut progressed = false
    while self.peek() is Some(ch) {
      if starlark_is_inline_space(ch) || ch == '\n' || ch == ';' {
        self.advance() |> ignore
        progressed = true
      } else {
        break
      }
    }
    if self.peek() is Some('#') {
      self.skip_comment()
      progressed = true
    }
    if not(progressed) {
      break
    }
  }
}

///|
fn StarlarkParser::skip_value_space(self : StarlarkParser) -> Unit {
  while true {
    let mut progressed = false
    while self.peek() is Some(ch) {
      if starlark_is_inline_space(ch) || ch == '\n' {
        self.advance() |> ignore
        progressed = true
      } else {
        break
      }
    }
    if self.peek() is Some('#') {
      self.skip_comment()
      progressed = true
    }
    if not(progressed) {
      break
    }
  }
}

///|
fn StarlarkParser::parse_identifier(self : StarlarkParser) -> String? {
  guard self.peek() is Some(ch) && starlark_is_ident_start(ch) else {
    return None
  }
  let start = self.idx
  self.advance() |> ignore
  while self.peek() is Some(next) {
    if starlark_is_ident_part(next) {
      self.advance() |> ignore
    } else {
      break
    }
  }
  Some(String::unsafe_substring(self.text, start~, end=self.idx))
}

///|
fn StarlarkParser::parse_string(self : StarlarkParser) -> StarlarkValue? {
  guard self.peek() is Some(quote) else {
    self.push_error("expected string literal")
    return None
  }
  guard quote == '"' || quote.to_int() == 39 else {
    self.push_error("expected string literal")
    return None
  }
  self.advance() |> ignore
  let buf = StringBuilder::new()
  let mut escaped = false
  while self.peek() is Some(ch) {
    self.advance() |> ignore
    if escaped {
      escaped = false
      if ch == 'n' {
        buf.write_char('\n')
      } else if ch == 'r' {
        buf.write_char('\r')
      } else if ch == 't' {
        buf.write_char('\t')
      } else if ch == '\\' {
        buf.write_char('\\')
      } else if ch == '"' {
        buf.write_char('"')
      } else if ch.to_int() == 39 {
        buf.write_char(ch.unsafe_to_char())
      } else {
        self.push_error("invalid escape sequence")
        buf.write_char(ch.unsafe_to_char())
      }
      continue
    }
    if ch == '\\' {
      escaped = true
      continue
    }
    if ch == '\n' {
      self.push_error("unexpected newline in string literal")
      return None
    }
    if ch == quote {
      return Some(Str(buf.to_string()))
    }
    buf.write_char(ch.unsafe_to_char())
  }
  self.push_error("unterminated string literal")
  None
}

///|
fn StarlarkParser::parse_int(self : StarlarkParser) -> StarlarkValue? {
  let mut negative = false
  if self.consume_char('-') {
    negative = true
  }
  guard self.peek() is Some(first) && starlark_is_digit(first) else {
    self.push_error("expected integer literal")
    return None
  }
  let mut value = 0
  while self.peek() is Some(ch) {
    if starlark_is_digit(ch) {
      self.advance() |> ignore
      value = value * 10 + (ch.to_int() - '0'.to_int())
    } else {
      break
    }
  }
  if negative {
    value = -value
  }
  Some(Num(value))
}

///|
fn StarlarkParser::recover_to_arg_boundary(self : StarlarkParser) -> Unit {
  while self.peek() is Some(ch) {
    if ch == ',' || ch == ')' || ch == ']' || ch == '}' {
      break
    }
    self.advance() |> ignore
  }
}

///|
fn StarlarkParser::parse_list(self : StarlarkParser) -> StarlarkValue? {
  guard self.consume_char('[') else {
    self.push_error("expected '['")
    return None
  }
  let items : Array[StarlarkValue] = []
  self.skip_value_space()
  if self.consume_char(']') {
    return Some(List(items))
  }
  while true {
    self.skip_value_space()
    match self.parse_value() {
      Some(value) => items.push(value)
      None => {
        self.recover_to_arg_boundary()
        if self.consume_char(']') {
          break
        }
        if self.consume_char(',') {
          continue
        }
        break
      }
    }
    self.skip_value_space()
    if self.consume_char(',') {
      self.skip_value_space()
      if self.consume_char(']') {
        break
      }
      continue
    }
    if self.consume_char(']') {
      break
    }
    self.push_error("expected ',' or ']' in list literal")
    self.recover_to_arg_boundary()
    if self.consume_char(']') {
      break
    }
    if self.consume_char(',') {
      continue
    }
    break
  }
  Some(List(items))
}

///|
fn StarlarkParser::parse_dict(self : StarlarkParser) -> StarlarkValue? {
  guard self.consume_char('{') else {
    self.push_error("expected '{'")
    return None
  }
  let items : Map[String, StarlarkValue] = {}
  self.skip_value_space()
  if self.consume_char('}') {
    return Some(Dict(items))
  }
  while true {
    self.skip_value_space()
    let key = match self.parse_string() {
      Some(Str(text)) => text
      _ => {
        self.push_error("dict key must be string")
        self.recover_to_arg_boundary()
        if self.consume_char('}') {
          break
        }
        if self.consume_char(',') {
          continue
        }
        break
      }
    }

    self.skip_value_space()
    if not(self.consume_char(':')) {
      self.push_error("expected ':' after dict key")
      self.recover_to_arg_boundary()
      if self.consume_char('}') {
        break
      }
      if self.consume_char(',') {
        continue
      }
      break
    }

    self.skip_value_space()
    match self.parse_value() {
      Some(value) => items[key] = value
      None => {
        self.recover_to_arg_boundary()
        if self.consume_char('}') {
          break
        }
        if self.consume_char(',') {
          continue
        }
        break
      }
    }

    self.skip_value_space()
    if self.consume_char(',') {
      self.skip_value_space()
      if self.consume_char('}') {
        break
      }
      continue
    }
    if self.consume_char('}') {
      break
    }
    self.push_error("expected ',' or '}' in dict literal")
    self.recover_to_arg_boundary()
    if self.consume_char('}') {
      break
    }
    if self.consume_char(',') {
      continue
    }
    break
  }
  Some(Dict(items))
}

///|
fn starlark_parse_identifier_value(ident : String) -> StarlarkValue? {
  if ident == "True" || ident == "true" {
    Some(Bool(true))
  } else if ident == "False" || ident == "false" {
    Some(Bool(false))
  } else {
    Some(Ref(ident))
  }
}

///|
fn StarlarkParser::parse_value(self : StarlarkParser) -> StarlarkValue? {
  self.skip_value_space()
  guard self.peek() is Some(ch) else {
    self.push_error("expected value")
    return None
  }
  if ch == '"' || ch.to_int() == 39 {
    return self.parse_string()
  }
  if ch == '[' {
    return self.parse_list()
  }
  if ch == '{' {
    return self.parse_dict()
  }
  if ch == '-' || starlark_is_digit(ch) {
    return self.parse_int()
  }
  if starlark_is_ident_start(ch) {
    guard self.parse_identifier() is Some(ident) else {
      self.push_error("expected value")
      return None
    }
    return starlark_parse_identifier_value(ident)
  }
  self.push_error("unexpected token while parsing value")
  None
}

///|
fn StarlarkParser::parse_call_with_name(
  self : StarlarkParser,
  name : String,
  start_line : Int,
  start_col : Int,
) -> StarlarkCall? {
  guard self.consume_char('(') else {
    self.push_error("expected '(' after statement name")
    return None
  }
  let args : Array[StarlarkArg] = []
  self.skip_value_space()
  if self.consume_char(')') {
    return Some({ name, args, line: start_line, column: start_col })
  }
  if name == "load" {
    if self.peek() is Some(ch) && (ch == '"' || ch.to_int() == 39) {
      let arg_line = self.line
      let arg_col = self.column
      match self.parse_string() {
        Some(value) =>
          args.push({ name: "path", value, line: arg_line, column: arg_col })
        None => ()
      }
      self.skip_value_space()
      if self.consume_char(',') {
        self.skip_value_space()
      }
      if not(self.consume_char(')')) {
        if self.peek() is None {
          self.push_error("expected ')' to close load()")
        } else {
          self.push_error("load() expects load(\"path\") or load(path=\"...\")")
        }
        self.recover_to_arg_boundary()
        ignore(self.consume_char(')'))
      }
      return Some({ name, args, line: start_line, column: start_col })
    }
  }
  while true {
    self.skip_value_space()
    if self.peek() is None {
      self.push_error("expected ')' to close argument list")
      break
    }
    if self.peek() is Some('*') {
      self.push_error("splat arguments are not supported")
      self.recover_to_arg_boundary()
      if self.consume_char(')') {
        break
      }
      if self.consume_char(',') {
        continue
      }
      break
    }
    let arg_line = self.line
    let arg_col = self.column
    guard self.parse_identifier() is Some(arg_name) else {
      self.push_error("keyword argument must have form name=expr")
      self.recover_to_arg_boundary()
      if self.consume_char(')') {
        break
      }
      if self.consume_char(',') {
        continue
      }
      break
    }
    self.skip_value_space()
    if not(self.consume_char('=')) {
      self.push_error("keyword argument must have form name=expr")
      self.recover_to_arg_boundary()
      if self.consume_char(')') {
        break
      }
      if self.consume_char(',') {
        continue
      }
      break
    }
    match self.parse_value() {
      Some(value) =>
        args.push({ name: arg_name, value, line: arg_line, column: arg_col })
      None => {
        self.recover_to_arg_boundary()
        if self.consume_char(')') {
          break
        }
        if self.consume_char(',') {
          continue
        }
        break
      }
    }
    self.skip_value_space()
    if self.consume_char(',') {
      self.skip_value_space()
      if self.consume_char(')') {
        break
      }
      continue
    }
    if self.consume_char(')') {
      break
    }
    self.push_error("expected ',' or ')' after argument")
    self.recover_to_arg_boundary()
    if self.consume_char(')') {
      break
    }
    if self.consume_char(',') {
      continue
    }
    break
  }
  Some({ name, args, line: start_line, column: start_col })
}

///|
fn StarlarkParser::parse_assignment_with_name(
  self : StarlarkParser,
  name : String,
  start_line : Int,
  start_col : Int,
) -> StarlarkCall {
  let args : Array[StarlarkArg] = [
    { name: "name", value: Str(name), line: start_line, column: start_col },
  ]
  self.skip_value_space()
  let value_line = self.line
  let value_col = self.column
  match self.parse_value() {
    Some(value) =>
      args.push({ name: "value", value, line: value_line, column: value_col })
    None => ()
  }
  { name: "__assign__", args, line: start_line, column: start_col }
}

///|
fn StarlarkParser::parse_statement(self : StarlarkParser) -> StarlarkCall? {
  let start_line = self.line
  let start_col = self.column
  guard self.parse_identifier() is Some(name) else {
    self.push_error("expected statement name")
    return None
  }
  self.skip_inline_space()
  if self.consume_char('=') {
    return Some(self.parse_assignment_with_name(name, start_line, start_col))
  }
  self.parse_call_with_name(name, start_line, start_col)
}

///|
fn StarlarkParser::recover_to_statement_boundary(self : StarlarkParser) -> Unit {
  while self.peek() is Some(ch) {
    if ch == '\n' || ch == ';' {
      break
    }
    self.advance() |> ignore
  }
  if self.peek() is Some('\n') || self.peek() is Some(';') {
    self.advance() |> ignore
  }
}

///|
fn StarlarkParser::consume_statement_end(self : StarlarkParser) -> Unit {
  self.skip_inline_space()
  if self.peek() is None {
    return
  }
  if self.peek() is Some('#') {
    self.skip_comment()
    if self.peek() is Some('\n') {
      self.advance() |> ignore
    }
    self.skip_statement_separators()
    return
  }
  if self.consume_char(';') || self.consume_char('\n') {
    self.skip_statement_separators()
    return
  }
  self.push_error("expected newline or ';' after statement")
  self.recover_to_statement_boundary()
  self.skip_statement_separators()
}

///|
fn parse_starlark_syntax(text : String) -> StarlarkSyntaxResult {
  let parser = starlark_parser_new(text)
  let calls : Array[StarlarkCall] = []
  parser.skip_statement_separators()
  while parser.peek() is Some(_) {
    match parser.parse_statement() {
      Some(call) => calls.push(call)
      None => parser.recover_to_statement_boundary()
    }
    parser.consume_statement_end()
  }
  { calls, errors: parser.errors }
}
