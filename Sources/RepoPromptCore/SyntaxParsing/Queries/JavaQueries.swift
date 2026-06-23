//
//  JavaQueries.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-06.
//

// JavaQuery.swift
// Make sure no tab characters are present; use only spaces for indentation.

import Foundation

let javaQuery = """
; Variables

(identifier) @variable

; Methods

(method_declaration
  name: (identifier) @function.method)
(method_invocation
  name: (identifier) @function.method)
(super) @function.builtin

; Annotations

(annotation
  name: (identifier) @attribute)
(marker_annotation
  name: (identifier) @attribute)

"@" @operator

; Types

(type_identifier) @type

(interface_declaration
  name: (identifier) @type)
(class_declaration
  name: (identifier) @type)
(enum_declaration
  name: (identifier) @type)

((field_access
  object: (identifier) @type)
 (#match? @type "^[A-Z]"))
((scoped_identifier
  scope: (identifier) @type)
 (#match? @type "^[A-Z]"))
((method_invocation
  object: (identifier) @type)
 (#match? @type "^[A-Z]"))
((method_reference
  . (identifier) @type)
 (#match? @type "^[A-Z]"))

(constructor_declaration
  name: (identifier) @type)

[
  (boolean_type)
  (integral_type)
  (floating_point_type)
  (floating_point_type)
  (void_type)
] @type.builtin

; Constants

((identifier) @constant
 (#match? @constant "^_*[A-Z][A-Z\\d_]+$"))

; Builtins

(this) @variable.builtin

; Literals

[
  (hex_integer_literal)
  (decimal_integer_literal)
  (octal_integer_literal)
  (decimal_floating_point_literal)
  (hex_floating_point_literal)
] @number

[
  (character_literal)
  (string_literal)
] @string
(escape_sequence) @string.escape

[
  (true)
  (false)
  (null_literal)
] @constant.builtin

[
  (line_comment)
  (block_comment)
] @comment

; Keywords

[
  "abstract"
  "assert"
  "break"
  "case"
  "catch"
  "class"
  "continue"
  "default"
  "do"
  "else"
  "enum"
  "exports"
  "extends"
  "final"
  "finally"
  "for"
  "if"
  "implements"
  "import"
  "instanceof"
  "interface"
  "module"
  "native"
  "new"
  "non-sealed"
  "open"
  "opens"
  "package"
  "permits"
  "private"
  "protected"
  "provides"
  "public"
  "requires"
  "record"
  "return"
  "sealed"
  "static"
  "strictfp"
  "switch"
  "synchronized"
  "throw"
  "throws"
  "to"
  "transient"
  "transitive"
  "try"
  "uses"
  "volatile"
  "when"
  "while"
  "with"
  "yield"
] @keyword
"""

let javaCodeMapQuery = #"""
; ===================================
; 1) Class Declarations
; ===================================
(class_declaration
  name: (identifier) @type.class) @type.class.decl

(interface_declaration
  name: (identifier) @type.interface) @type.interface.decl

; ===================================
; 3) Method Declarations
; ===================================
(method_declaration
  name: (identifier) @function.definition)

; ===================================
; 4) Parameter Declarations
;    Observed structure: (formal_parameter range: {…} childCount:2)
;    child 0 => (integral_type | boolean_type | type_identifier)
;    child 1 => (identifier)
; ===================================
(formal_parameter
  (_)
  (identifier) @function.param
)

; ===================================
; 5) Enum Declarations
;    (You might have none in this file, but we keep it for completeness)
; ===================================
(enum_declaration
  name: (identifier) @type.enum) @type.enum.decl

; Enum members
(enum_constant
  name: (identifier) @enum.entry)
"""#
