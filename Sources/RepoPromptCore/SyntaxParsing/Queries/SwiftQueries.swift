//
//  SwiftQueries.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-06.
//  Updated to match the tree-sitter-swift grammar (per attached JSON).
//  Ensure only spaces are used for indentation.
//

import Foundation

let swiftQuery = #"""
[ "." ";" ":" "," ] @punctuation.delimiter
[ "\\(" "(" ")" "[" "]" "{" "}"] @punctuation.bracket ; TODO: "\\(" ")" in interpolations should be @punctuation.special

; Identifiers
(attribute) @variable
(type_identifier) @type
(self_expression) @variable.builtin
(user_type (type_identifier) @variable.builtin (#eq? @variable.builtin "Self"))

; Declarations
"func" @keyword.function
[
  (visibility_modifier)
  (member_modifier)
  (function_modifier)
  (property_modifier)
  (parameter_modifier)
  (inheritance_modifier)
] @keyword

(function_declaration (simple_identifier) @method)
(init_declaration ["init" @constructor])
(deinit_declaration ["deinit" @constructor])
(throws) @keyword
"async" @keyword
"await" @keyword
(where_keyword) @keyword
(parameter external_name: (simple_identifier) @parameter)
(parameter name: (simple_identifier) @parameter)
(type_parameter (type_identifier) @parameter)
(inheritance_constraint (identifier (simple_identifier) @parameter))
(equality_constraint (identifier (simple_identifier) @parameter))
(pattern bound_identifier: (simple_identifier)) @variable

[
  "typealias"
  "struct"
  "class"
  "actor"
  "enum"
  "protocol"
  "extension"
  "indirect"
  "nonisolated"
  "override"
  "convenience"
  "required"
  "mutating"
  "associatedtype"
  "package"
] @keyword

(opaque_type ["some" @keyword])
(existential_type ["any" @keyword])

(precedence_group_declaration
 ["precedencegroup" @keyword]
 (simple_identifier) @type)
(precedence_group_attribute
 (simple_identifier) @keyword
 [(simple_identifier) @type
  (boolean_literal) @boolean])

[
  (getter_specifier)
  (setter_specifier)
  (modify_specifier)
] @keyword

(class_body (property_declaration (pattern (simple_identifier) @property)))
(protocol_property_declaration (pattern (simple_identifier) @property))

(import_declaration ["import" @include])

(enum_entry ["case" @keyword])

; Function calls
(call_expression (simple_identifier) @function.call) ; foo()
(call_expression ; foo.bar.baz(): highlight the baz()
  (navigation_expression
	(navigation_suffix (simple_identifier) @function.call)))
((navigation_expression
   (simple_identifier) @type) ; SomeType.method(): highlight SomeType as a type
   (#match? @type "^[A-Z]"))
(call_expression (simple_identifier) @keyword (#eq? @keyword "defer")) ; defer { ... }

(try_operator) @operator
(try_operator ["try" @keyword])

(directive) @function.macro
(diagnostic) @function.macro

; Statements
(for_statement ["for" @repeat])
(for_statement ["in" @repeat])
(for_statement (pattern) @variable)
(else) @keyword
(as_operator) @keyword

["while" "repeat" "continue" "break"] @repeat

["let" "var"] @keyword

(guard_statement ["guard" @conditional])
(if_statement ["if" @conditional])
(switch_statement ["switch" @conditional])
(switch_entry ["case" @keyword])
(switch_entry ["fallthrough" @keyword])
(switch_entry (default_keyword) @keyword)
"return" @keyword.return
(ternary_expression
  ["?" ":"] @conditional)

["do" (throw_keyword) (catch_keyword)] @keyword

(statement_label) @label

; Comments
[
 (comment)
 (multiline_comment)
] @comment @spell

; String literals
(line_str_text) @string
(str_escaped_char) @string
(multi_line_str_text) @string
(raw_str_part) @string
(raw_str_end_part) @string
(raw_str_interpolation_start) @punctuation.special
["\"" "\"\"\""] @string

; Lambda literals
(lambda_literal ["in" @keyword.operator])

; Basic literals
[
 (integer_literal)
 (hex_literal)
 (oct_literal)
 (bin_literal)
] @number
(real_literal) @float
(boolean_literal) @boolean
"nil" @variable.builtin

; Regex literals
(regex_literal) @string.regex

; Operators
(custom_operator) @operator
[
 "!"
 "?"
 "+"
 "-"
 "*"
 "/"
 "%"
 "="
 "+="
 "-="
 "*="
 "/="
 "<"
 ">"
 "<="
 ">="
 "++"
 "--"
 "&"
 "~"
 "%="
 "!="
 "!=="
 "=="
 "==="
 "??"

 "->"

 "..<"
 "..."
] @operator

(value_parameter_pack ["each" @keyword])
(value_pack_expansion ["repeat" @keyword])
(type_parameter_pack ["each" @keyword])
(type_pack_expansion ["repeat" @keyword])
"""#

let swiftCodeMapQuery = #"""
; ===================================
; Swift CodeMap Query - Updated for range-based containment
; ===================================

; ===================================
; 1) Type Container Declarations (with full range for containment)
; ===================================
; Capture class/struct/actor/enum/extension declarations - full node for range
; NOTE: In tree-sitter-swift, extensions are also parsed as class_declaration
; with declaration_kind: "extension", so this single pattern captures all of them
(class_declaration) @swift.type.decl

; Capture the type name separately - handles simple type identifiers
(class_declaration
  name: (type_identifier) @swift.type.name)

; Capture the type name when wrapped in user_type (common for extensions)
; This is critical for extensions like "extension Foo" where name is user_type
(class_declaration
  name: (user_type (type_identifier) @swift.type.name))

; Protocol declarations (separate for interfaces bucket)
(protocol_declaration) @swift.protocol.decl

(protocol_declaration
  name: (type_identifier) @swift.protocol.name)

; ===================================
; 2) Import Declarations
; ===================================
(import_declaration) @import

; ===================================
; 3) Top-level Function Declarations (global functions)
;    Only functions directly under source_file
; ===================================
(source_file
  (function_declaration) @swift.function.toplevel)

; ===================================
; 4) Member Functions (methods inside type bodies)
; ===================================
; NOTE: Extensions also use class_body in tree-sitter-swift, so this pattern
; already captures methods inside extensions - no separate extension_body needed
(class_body
  (function_declaration) @swift.function.method)

(enum_class_body
  (function_declaration) @swift.function.method)

(protocol_body
  (protocol_function_declaration) @swift.protocol.method)

; ===================================
; 5) Function Names (for all function types)
; ===================================
(function_declaration
  name: (simple_identifier) @swift.function.name)

(protocol_function_declaration
  name: (simple_identifier) @swift.function.name)

; ===================================
; 6) Parameter Declarations (with proper field captures)
; ===================================
; Capture the full parameter node for grouping
(parameter) @swift.param.node

; Capture parameter components using grammar fields
(parameter
  external_name: (simple_identifier) @swift.param.external)

(parameter
  name: (simple_identifier) @swift.param.local)

; Capture the parameter's type by position (field label doesn't work reliably)
(parameter
  ":"
  (parameter_modifiers)?
  (_) @swift.param.type)

; ===================================
; 7) Property Declarations
; ===================================
; Capture full property declarations for precise extraction
(property_declaration) @swift.property.decl
(protocol_property_declaration) @swift.protocol.property.decl

; Top-level properties (globals)
(source_file
  (property_declaration
    (value_binding_pattern)
    (pattern (simple_identifier) @swift.property.toplevel)
  )
)

; Class/struct/enum member properties
(class_body
  (property_declaration
    (value_binding_pattern)
    (pattern (simple_identifier) @swift.property.member)
  )
)

(enum_class_body
  (property_declaration
    (value_binding_pattern)
    (pattern (simple_identifier) @swift.property.member)
  )
)

; NOTE: Extension properties are captured by class_body pattern above since
; tree-sitter-swift uses class_body for extensions too

; Protocol property declarations
(protocol_property_declaration
  (pattern (simple_identifier) @swift.protocol.property))

; ===================================
; 8) Enum Declarations (body-discriminated)
; ===================================
(class_declaration
  name: (type_identifier) @type.enum
  body: (enum_class_body))

; ===================================
; 9) Enum Entries
; ===================================
(enum_entry
  name: (simple_identifier) @enum.entry)

; ===================================
; 10) Macros
; ===================================
(macro_declaration) @macro

; ===================================
; Legacy captures for backwards compatibility
; (used by existing routing until Swift-specific path is complete)
; ===================================
(class_declaration
  name: (type_identifier) @type.class)

(function_declaration) @function.definition
"""#
