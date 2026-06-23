//  cSharpQueries.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-06.
//  Updated to use new C# queries.
//
// Make sure no tab characters are present; use only spaces for indentation.

import Foundation

let csharpQuery = """
(identifier) @variable

;; Methods

(method_declaration name: (identifier) @function)
(local_function_statement name: (identifier) @function)

;; Types

(interface_declaration name: (identifier) @type)
(class_declaration name: (identifier) @type)
(enum_declaration name: (identifier) @type)
(struct_declaration (identifier) @type)
(record_declaration (identifier) @type)
(namespace_declaration name: (identifier) @module)

(generic_name (identifier) @type)
(type_parameter (identifier) @property.definition)
(parameter type: (identifier) @type)
(type_argument_list (identifier) @type)
(as_expression right: (identifier) @type)
(is_expression right: (identifier) @type)

(constructor_declaration name: (identifier) @constructor)
(destructor_declaration name: (identifier) @constructor)

(_ type: (identifier) @type)

(base_list (identifier) @type)

(predefined_type) @type.builtin

;; Enum
(enum_member_declaration (identifier) @property.definition)

;; Literals

[
  (real_literal)
  (integer_literal)
] @number

[
  (character_literal)
  (string_literal)
  (raw_string_literal)
  (verbatim_string_literal)
  (interpolated_string_expression)
  (interpolation_start)
  (interpolation_quote)
] @string

(escape_sequence) @string.escape

[
  (boolean_literal)
  (null_literal)
] @constant.builtin

;; Comments

(comment) @comment

;; Tokens

[
  ";"
  "."
  ","
] @punctuation.delimiter

[
  "--"
  "-"
  "-="
  "&"
  "&="
  "&&"
  "+"
  "++"
  "+="
  "<"
  "<="
  "<<"
  "<<="
  "="
  "=="
  "!"
  "!="
  "=>"
  ">"
  ">="
  ">>"
  ">>="
  ">>>"
  ">>>="
  "|"
  "|="
  "||"
  "?"
  "??"
  "??="
  "^"
  "^="
  "~"
  "*"
  "*="
  "/"
  "/="
  "%"
  "%="
  ":"
] @operator

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
  (interpolation_brace)
] @punctuation.bracket

;; Keywords

[
  (modifier)
  "this"
  (implicit_type)
] @keyword

[
  "add"
  "alias"
  "as"
  "base"
  "break"
  "case"
  "catch"
  "checked"
  "class"
  "continue"
  "default"
  "delegate"
  "do"
  "else"
  "enum"
  "event"
  "explicit"
  "extern"
  "finally"
  "for"
  "foreach"
  "global"
  "goto"
  "if"
  "implicit"
  "interface"
  "is"
  "lock"
  "namespace"
  "notnull"
  "operator"
  "params"
  "return"
  "remove"
  "sizeof"
  "stackalloc"
  "static"
  "struct"
  "switch"
  "throw"
  "try"
  "typeof"
  "unchecked"
  "using"
  "while"
  "new"
  "await"
  "in"
  "yield"
  "get"
  "set"
  "when"
  "out"
  "ref"
  "from"
  "where"
  "select"
  "record"
  "init"
  "with"
  "let"
] @keyword

;; Attribute

(attribute name: (identifier) @attribute)

;; Parameters

(parameter
  name: (identifier) @variable.parameter)

;; Type constraints

(type_parameter_constraints_clause (identifier) @property.definition)

;; Method calls

(invocation_expression (member_access_expression name: (identifier) @function))
"""

let csharpCodeMapQuery = #"""
; ===================================
; 1) Class Declarations
; ===================================
(class_declaration
  name: (identifier) @type.class) @type.class.decl

(struct_declaration
  name: (identifier) @type.struct) @type.class.decl

(interface_declaration
  name: (identifier) @type.interface) @type.interface.decl

; ===================================
; 2) Import ("using") Declarations
; ===================================
(using_directive) @import

; ===================================
; 3) Enum Declarations
; ===================================
(enum_declaration
  name: (identifier) @type.enum) @type.enum.decl

; ===================================
; 4) Enum Members
; ===================================
(enum_member_declaration
  name: (identifier) @enum.entry)

; ===================================
; 5) Method Declarations (top-level in a class or struct)
; ===================================
(method_declaration
  name: (identifier) @function.definition)

; Local functions (C# 7+)
(local_function_statement
  name: (identifier) @function.definition)

; ===================================
; 6) Field / Global Variables
;    For “global” in standard C#, we rely on static fields in top-level classes,
;    or top-level statements in file-scoped namespaces in newer versions.
; ===================================
(field_declaration
  (variable_declaration
	(variable_declarator
	  name: (identifier) @variable.global)))

; ===================================
; 7) Property Declarations
;    You can treat these as variables or keep them separate.
; ===================================
(property_declaration
  name: (identifier) @variable.global)

; ===================================
; 8) Parameter Declarations
;    The "parameter" node in the C# grammar typically holds (identifier) children.
; ===================================
(parameter
  name: (identifier) @function.param)
"""#
