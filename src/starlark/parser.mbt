///|
priv enum StarlarkValue {
  Str(String)
  Num(Int)
  Bool(Bool)
  NoneValue
  List(Array[StarlarkValue])
  Dict(Map[String, StarlarkValue])
  Ref(String)
  Neg(StarlarkValue)
  Index(StarlarkValue, StarlarkValue)
  Slice(StarlarkValue, StarlarkValue?, StarlarkValue?)
  MethodCall(StarlarkValue, String, Array[StarlarkValue])
  Call(String, Array[StarlarkValue])
  Add(StarlarkValue, StarlarkValue)
  Sub(StarlarkValue, StarlarkValue)
  Mul(StarlarkValue, StarlarkValue)
  FloorDiv(StarlarkValue, StarlarkValue)
  Mod(StarlarkValue, StarlarkValue)
  Eq(StarlarkValue, StarlarkValue)
  NotEq(StarlarkValue, StarlarkValue)
  Lt(StarlarkValue, StarlarkValue)
  Lte(StarlarkValue, StarlarkValue)
  Gt(StarlarkValue, StarlarkValue)
  Gte(StarlarkValue, StarlarkValue)
  In(StarlarkValue, StarlarkValue)
  NotIn(StarlarkValue, StarlarkValue)
  Not(StarlarkValue)
  And(StarlarkValue, StarlarkValue)
  Or(StarlarkValue, StarlarkValue)
  IfExpr(StarlarkValue, StarlarkValue, StarlarkValue)
}

///|
priv enum StarlarkCompareOp {
  Eq
  NotEq
  Lt
  Lte
  Gt
  Gte
  In
  NotIn
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
fn parser_new(text : String) -> StarlarkParser {
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
fn StarlarkParser::consume_two_chars(
  self : StarlarkParser,
  ch1 : UInt16,
  ch2 : UInt16,
) -> Bool {
  guard self.idx + 1 < self.text.length() else { return false }
  guard self.text.unsafe_get(self.idx) == ch1 else { return false }
  guard self.text.unsafe_get(self.idx + 1) == ch2 else { return false }
  self.advance() |> ignore
  self.advance() |> ignore
  true
}

///|
fn StarlarkParser::consume_keyword(
  self : StarlarkParser,
  keyword : String,
) -> Bool {
  let saved_idx = self.idx
  let saved_line = self.line
  let saved_col = self.column
  match self.parse_identifier() {
    Some(ident) if ident == keyword => true
    _ => {
      self.idx = saved_idx
      self.line = saved_line
      self.column = saved_col
      false
    }
  }
}

///|
fn StarlarkParser::consume_not_in_operator(self : StarlarkParser) -> Bool {
  let saved_idx = self.idx
  let saved_line = self.line
  let saved_col = self.column
  if self.consume_keyword("not") {
    self.skip_inline_space()
    if self.consume_keyword("in") {
      return true
    }
  }
  self.idx = saved_idx
  self.line = saved_line
  self.column = saved_col
  false
}

///|
fn is_digit(ch : UInt16) -> Bool {
  ch >= '0' && ch <= '9'
}

///|
fn is_ident_start(ch : UInt16) -> Bool {
  (ch >= 'a' && ch <= 'z') || (ch >= 'A' && ch <= 'Z') || ch == '_'
}

///|
fn is_ident_part(ch : UInt16) -> Bool {
  is_ident_start(ch) || is_digit(ch)
}

///|
fn is_inline_space(ch : UInt16) -> Bool {
  ch == ' ' || ch == '\t' || ch == '\r'
}

///|
fn StarlarkParser::push_error(self : StarlarkParser, msg : String) -> Unit {
  self.errors.push("line \{self.line}, col \{self.column}: " + msg)
}

///|
fn StarlarkParser::skip_inline_space(self : StarlarkParser) -> Unit {
  while self.peek() is Some(ch) {
    if is_inline_space(ch) {
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
      if is_inline_space(ch) || ch == '\n' || ch == ';' {
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
      if is_inline_space(ch) || ch == '\n' {
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
  guard self.peek() is Some(ch) && is_ident_start(ch) else { return None }
  let start = self.idx
  self.advance() |> ignore
  while self.peek() is Some(next) {
    if is_ident_part(next) {
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
  guard self.peek() is Some(first) && is_digit(first) else {
    self.push_error("expected integer literal")
    return None
  }
  let mut value = 0
  while self.peek() is Some(ch) {
    if is_digit(ch) {
      self.advance() |> ignore
      value = value * 10 + (ch.to_int() - '0'.to_int())
    } else {
      break
    }
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
fn parse_identifier_value(ident : String) -> StarlarkValue? {
  if ident == "True" || ident == "true" {
    Some(Bool(true))
  } else if ident == "False" || ident == "false" {
    Some(Bool(false))
  } else if ident == "None" {
    Some(NoneValue)
  } else {
    Some(Ref(ident))
  }
}

///|
fn StarlarkParser::parse_primary_value(self : StarlarkParser) -> StarlarkValue? {
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
  if ch == '(' {
    self.advance() |> ignore
    self.skip_value_space()
    if self.consume_char(')') {
      return Some(List([]))
    }
    match self.parse_value() {
      Some(first) => {
        self.skip_value_space()
        if self.consume_char(',') {
          let items : Array[StarlarkValue] = [first]
          while true {
            self.skip_value_space()
            if self.consume_char(')') {
              return Some(List(items))
            }
            match self.parse_value() {
              Some(value) => items.push(value)
              None => {
                self.skip_value_space()
                if not(self.consume_char(')')) {
                  self.push_error("expected ')' to close expression")
                }
                return None
              }
            }
            self.skip_value_space()
            if self.consume_char(',') {
              continue
            }
            if self.consume_char(')') {
              return Some(List(items))
            }
            self.push_error("expected ')' to close expression")
            return None
          }
        }
        if not(self.consume_char(')')) {
          self.push_error("expected ')' to close expression")
          return None
        }
        return Some(first)
      }
      None => {
        self.skip_value_space()
        if not(self.consume_char(')')) {
          self.push_error("expected ')' to close expression")
        }
        return None
      }
    }
  }
  if is_digit(ch) {
    return self.parse_int()
  }
  if is_ident_start(ch) {
    guard self.parse_identifier() is Some(ident) else {
      self.push_error("expected value")
      return None
    }
    self.skip_inline_space()
    if self.consume_char('(') {
      return self.parse_expr_call_with_name(ident)
    }
    return parse_identifier_value(ident)
  }
  self.push_error("unexpected token while parsing value")
  None
}

///|
fn StarlarkParser::parse_value(self : StarlarkParser) -> StarlarkValue? {
  self.parse_if_value()
}

///|
fn StarlarkParser::parse_if_value(self : StarlarkParser) -> StarlarkValue? {
  guard self.parse_or_value() is Some(then_value) else { return None }
  self.skip_inline_space()
  if not(self.consume_keyword("if")) {
    return Some(then_value)
  }
  guard self.parse_or_value() is Some(cond_value) else { return None }
  self.skip_inline_space()
  if not(self.consume_keyword("else")) {
    self.push_error("expected 'else' in conditional expression")
    return None
  }
  guard self.parse_if_value() is Some(else_value) else { return None }
  Some(IfExpr(cond_value, then_value, else_value))
}

///|
fn StarlarkParser::parse_or_value(self : StarlarkParser) -> StarlarkValue? {
  guard self.parse_and_value() is Some(first) else { return None }
  let mut value = first
  while true {
    self.skip_inline_space()
    if not(self.consume_keyword("or")) {
      break
    }
    match self.parse_and_value() {
      Some(rhs) => value = Or(value, rhs)
      None => return None
    }
  }
  Some(value)
}

///|
fn StarlarkParser::parse_and_value(self : StarlarkParser) -> StarlarkValue? {
  guard self.parse_not_value() is Some(first) else { return None }
  let mut value = first
  while true {
    self.skip_inline_space()
    if not(self.consume_keyword("and")) {
      break
    }
    match self.parse_not_value() {
      Some(rhs) => value = And(value, rhs)
      None => return None
    }
  }
  Some(value)
}

///|
fn StarlarkParser::parse_not_value(self : StarlarkParser) -> StarlarkValue? {
  self.skip_inline_space()
  if self.consume_keyword("not") {
    match self.parse_not_value() {
      Some(value) => return Some(Not(value))
      None => return None
    }
  }
  self.parse_compare_value()
}

///|
fn StarlarkParser::parse_compare_value(self : StarlarkParser) -> StarlarkValue? {
  guard self.parse_add_value() is Some(first) else { return None }
  guard self.parse_compare_op() is Some(first_op) else { return Some(first) }
  guard self.parse_add_value() is Some(second) else { return None }

  let mut chain_expr = compare_expr(first_op, first, second)
  let mut prev_rhs = second
  while self.parse_compare_op() is Some(next_op) {
    guard self.parse_add_value() is Some(next_rhs) else { return None }
    let next_expr = compare_expr(next_op, prev_rhs, next_rhs)
    chain_expr = And(chain_expr, next_expr)
    prev_rhs = next_rhs
  }
  Some(chain_expr)
}

///|
fn StarlarkParser::parse_add_value(self : StarlarkParser) -> StarlarkValue? {
  guard self.parse_mul_value() is Some(first) else { return None }
  let mut value = first
  while true {
    self.skip_inline_space()
    if self.consume_char('+') {
      match self.parse_mul_value() {
        Some(rhs) => value = Add(value, rhs)
        None => return None
      }
      continue
    }
    if self.consume_char('-') {
      match self.parse_mul_value() {
        Some(rhs) => value = Sub(value, rhs)
        None => return None
      }
      continue
    }
    break
  }
  Some(value)
}

///|
fn StarlarkParser::parse_mul_value(self : StarlarkParser) -> StarlarkValue? {
  guard self.parse_unary_value() is Some(first) else { return None }
  let mut value = first
  while true {
    self.skip_inline_space()
    if self.consume_two_chars('/', '/') {
      match self.parse_unary_value() {
        Some(rhs) => value = FloorDiv(value, rhs)
        None => return None
      }
      continue
    }
    if self.consume_char('*') {
      match self.parse_unary_value() {
        Some(rhs) => value = Mul(value, rhs)
        None => return None
      }
      continue
    }
    if self.consume_char('%') {
      match self.parse_unary_value() {
        Some(rhs) => value = Mod(value, rhs)
        None => return None
      }
      continue
    }
    break
  }
  Some(value)
}

///|
fn StarlarkParser::parse_unary_value(self : StarlarkParser) -> StarlarkValue? {
  self.skip_inline_space()
  if self.consume_char('-') {
    match self.parse_unary_value() {
      Some(value) => Some(Neg(value))
      None => None
    }
  } else {
    self.parse_postfix_value()
  }
}

///|
fn StarlarkParser::parse_postfix_value(self : StarlarkParser) -> StarlarkValue? {
  guard self.parse_primary_value() is Some(first) else { return None }
  let mut value = first
  while true {
    self.skip_inline_space()
    if self.consume_char('.') {
      self.skip_value_space()
      guard self.parse_identifier() is Some(method_name) else {
        self.push_error("expected method name after '.'")
        return None
      }
      self.skip_value_space()
      if not(self.consume_char('(')) {
        self.push_error("expected '(' after method name")
        return None
      }
      match self.parse_method_call_with_receiver(value, method_name) {
        Some(next_value) => {
          value = next_value
          continue
        }
        None => return None
      }
    }
    if not(self.consume_char('[')) {
      break
    }
    self.skip_value_space()
    if self.consume_char(':') {
      let (ok, end_bound) = self.parse_slice_bound_optional()
      if not(ok) {
        self.skip_value_space()
        if not(self.consume_char(']')) {
          self.push_error("expected ']' to close slice expression")
        }
        return None
      }
      self.skip_value_space()
      if not(self.consume_char(']')) {
        self.push_error("expected ']' to close slice expression")
        return None
      }
      value = Slice(value, None, end_bound)
      continue
    }

    let first_part = match self.parse_value() {
      Some(parsed) => parsed
      None => {
        self.skip_value_space()
        if not(self.consume_char(']')) {
          self.push_error("expected ']' to close index expression")
        }
        return None
      }
    }
    self.skip_value_space()
    if self.consume_char(':') {
      let (ok, end_bound) = self.parse_slice_bound_optional()
      if not(ok) {
        self.skip_value_space()
        if not(self.consume_char(']')) {
          self.push_error("expected ']' to close slice expression")
        }
        return None
      }
      self.skip_value_space()
      if not(self.consume_char(']')) {
        self.push_error("expected ']' to close slice expression")
        return None
      }
      value = Slice(value, Some(first_part), end_bound)
      continue
    } else {
      if not(self.consume_char(']')) {
        self.push_error("expected ']' to close index expression")
        return None
      }
      value = Index(value, first_part)
    }
  }
  Some(value)
}

///|
fn StarlarkParser::parse_method_call_with_receiver(
  self : StarlarkParser,
  receiver : StarlarkValue,
  name : String,
) -> StarlarkValue? {
  let args : Array[StarlarkValue] = []
  self.skip_value_space()
  if self.consume_char(')') {
    return Some(MethodCall(receiver, name, args))
  }
  while true {
    match self.parse_value() {
      Some(value) => args.push(value)
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
    self.push_error("expected ',' or ')' in call expression")
    self.recover_to_arg_boundary()
    if self.consume_char(')') {
      break
    }
    if self.consume_char(',') {
      continue
    }
    break
  }
  Some(MethodCall(receiver, name, args))
}

///|
fn StarlarkParser::parse_slice_bound_optional(
  self : StarlarkParser,
) -> (Bool, StarlarkValue?) {
  self.skip_value_space()
  if self.peek() is Some(']') {
    return (true, None)
  }
  match self.parse_value() {
    Some(value) => (true, Some(value))
    None => (false, None)
  }
}

///|
fn StarlarkParser::parse_expr_call_with_name(
  self : StarlarkParser,
  name : String,
) -> StarlarkValue? {
  let args : Array[StarlarkValue] = []
  self.skip_value_space()
  if self.consume_char(')') {
    return Some(Call(name, args))
  }
  while true {
    match self.parse_value() {
      Some(value) => args.push(value)
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
    self.push_error("expected ',' or ')' in call expression")
    self.recover_to_arg_boundary()
    if self.consume_char(')') {
      break
    }
    if self.consume_char(',') {
      continue
    }
    break
  }
  Some(Call(name, args))
}

///|
fn compare_expr(
  op : StarlarkCompareOp,
  left : StarlarkValue,
  right : StarlarkValue,
) -> StarlarkValue {
  match op {
    Eq => Eq(left, right)
    NotEq => NotEq(left, right)
    Lt => Lt(left, right)
    Lte => Lte(left, right)
    Gt => Gt(left, right)
    Gte => Gte(left, right)
    In => In(left, right)
    NotIn => NotIn(left, right)
  }
}

///|
fn StarlarkParser::parse_compare_op(
  self : StarlarkParser,
) -> StarlarkCompareOp? {
  self.skip_inline_space()
  if self.consume_two_chars('=', '=') {
    return Some(Eq)
  }
  if self.consume_two_chars('!', '=') {
    return Some(NotEq)
  }
  if self.consume_two_chars('<', '=') {
    return Some(Lte)
  }
  if self.consume_two_chars('>', '=') {
    return Some(Gte)
  }
  if self.consume_char('<') {
    return Some(Lt)
  }
  if self.consume_char('>') {
    return Some(Gt)
  }
  if self.consume_not_in_operator() {
    return Some(NotIn)
  }
  if self.consume_keyword("in") {
    return Some(In)
  }
  None
}

///|
fn StarlarkParser::parse_load_path_arg(
  self : StarlarkParser,
  args : Array[StarlarkArg],
) -> Bool {
  let arg_line = self.line
  let arg_col = self.column
  if self.peek() is Some(ch) && (ch == '"' || ch.to_int() == 39) {
    match self.parse_string() {
      Some(value) => {
        args.push({ name: "path", value, line: arg_line, column: arg_col })
        return true
      }
      None => return false
    }
  }
  guard self.parse_identifier() is Some(arg_name) else {
    self.push_error("load() first argument must be string path or path=\"...\"")
    return false
  }
  self.skip_value_space()
  if not(self.consume_char('=')) {
    self.push_error("load() first argument must be string path or path=\"...\"")
    return false
  }
  if arg_name != "path" {
    self.push_error("load() first argument must be string path or path=\"...\"")
    self.skip_value_space()
    ignore(self.parse_value())
    return false
  }
  self.skip_value_space()
  match self.parse_string() {
    Some(value) => {
      args.push({ name: "path", value, line: arg_line, column: arg_col })
      true
    }
    None => false
  }
}

///|
fn StarlarkParser::parse_load_import_arg(self : StarlarkParser) -> Bool {
  if self.peek() is Some(ch) && (ch == '"' || ch.to_int() == 39) {
    return self.parse_string() is Some(_)
  }
  if self.peek() is Some('*') {
    self.push_error("splat arguments are not supported")
    return false
  }
  guard self.parse_identifier() is Some(_alias_name) else {
    self.push_error("load() import must be string or alias=\"symbol\"")
    return false
  }
  self.skip_value_space()
  if not(self.consume_char('=')) {
    self.push_error("load() import must be string or alias=\"symbol\"")
    return false
  }
  self.skip_value_space()
  self.parse_string() is Some(_)
}

///|
fn StarlarkParser::parse_load_call(
  self : StarlarkParser,
  name : String,
  start_line : Int,
  start_col : Int,
) -> StarlarkCall {
  let args : Array[StarlarkArg] = []
  self.skip_value_space()
  if self.consume_char(')') {
    self.push_error("load() requires path argument")
    return { name, args, line: start_line, column: start_col }
  }

  if not(self.parse_load_path_arg(args)) {
    self.recover_to_arg_boundary()
  }

  while true {
    self.skip_value_space()
    if self.consume_char(')') {
      break
    }
    if self.peek() is None {
      self.push_error("expected ')' to close load()")
      break
    }
    if not(self.consume_char(',')) {
      self.push_error("expected ',' or ')' after load() argument")
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
    if self.consume_char(')') {
      break
    }
    if self.peek() is None {
      self.push_error("expected ')' to close load()")
      break
    }
    if not(self.parse_load_import_arg()) {
      self.recover_to_arg_boundary()
      if self.consume_char(')') {
        break
      }
    }
  }

  { name, args, line: start_line, column: start_col }
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
  if name == "load" {
    return Some(self.parse_load_call(name, start_line, start_col))
  }
  let args : Array[StarlarkArg] = []
  self.skip_value_space()
  if self.consume_char(')') {
    return Some({ name, args, line: start_line, column: start_col })
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
fn parse_syntax(text : String) -> StarlarkSyntaxResult {
  let parser = parser_new(text)
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
