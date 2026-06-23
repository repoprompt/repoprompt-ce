//
//  GoQueries.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-06.
//

// GoQueries.swift
// Make sure no tab characters are present; use only spaces for indentation.

import Foundation

let goQuery = """
; Function calls

(call_expression
  function: (identifier) @function)

(call_expression
  function: (identifier) @function.builtin
  (#match? @function.builtin "^(append|cap|close|complex|copy|delete|imag|len|make|new|panic|print|println|real|recover)$"))

(call_expression
  function: (selector_expression
	field: (field_identifier) @function.method))

; Function definitions

(function_declaration
  name: (identifier) @function)

(method_declaration
  name: (field_identifier) @function.method)

; Identifiers

(type_identifier) @type
(field_identifier) @property
(identifier) @variable

; Operators

[
  "--"
  "-"
  "-="
  ":="
  "!"
  "!="
  "..."
  "*"
  "*"
  "*="
  "/"
  "/="
  "&"
  "&&"
  "&="
  "%"
  "%="
  "^"
  "^="
  "+"
  "++"
  "+="
  "<-"
  "<"
  "<<"
  "<<="
  "<="
  "="
  "=="
  ">"
  ">="
  ">>"
  ">>="
  "|"
  "|="
  "||"
  "~"
] @operator

; Keywords

[
  "break"
  "case"
  "chan"
  "const"
  "continue"
  "default"
  "defer"
  "else"
  "fallthrough"
  "for"
  "func"
  "go"
  "goto"
  "if"
  "import"
  "interface"
  "map"
  "package"
  "range"
  "return"
  "select"
  "struct"
  "switch"
  "type"
  "var"
] @keyword

; Literals

[
  (interpreted_string_literal)
  (raw_string_literal)
  (rune_literal)
] @string

(escape_sequence) @escape

[
  (int_literal)
  (float_literal)
  (imaginary_literal)
] @number

[
  (true)
  (false)
  (nil)
  (iota)
] @constant.builtin

(comment) @comment
"""

/// Code-map (structural) query for Go, capturing top-level declarations, imports, etc.
let goCodeMapQuery = #"""
; ===================================
; 1) Package Declarations
; ===================================
(package_clause
  "package"
  (package_identifier) @package)

; ===================================
; 2) Import Declarations
; (This block was working already)
; ===================================
(import_declaration) @import
(import_spec
  (interpreted_string_literal) @import.path)

; ===================================
; 3) Function Declarations
; (This block was working already)
; ===================================
(function_declaration
  name: (identifier) @function.definition)

(method_declaration
  name: (field_identifier) @function.definition)

; ===================================
; 4) Global Variables (var)
; ===================================
(source_file
  (var_declaration
	(var_spec
	  (identifier)+ @variable.global
	  ; Optionally capture the type or init expression if needed
	)+))

; ===================================
; 5) Global Constants (const)
; ===================================
(source_file
  (const_declaration
	(const_spec
	  (identifier)+ @variable.global
	  ; Optionally capture type/expression
	)+))

; ===================================
; 6) Struct Declarations
; (This block was working already)
; ===================================
(type_declaration
  (type_spec
	name: (type_identifier) @type.struct
	type: (struct_type))) @type.class.decl

; ===================================
; 7) Struct Fields
; ===================================
(field_declaration
  (field_identifier)+ @variable.field
  ; e.g. (#match? @variable.field "^[A-Z]") if only exported
)
"""#
