//
//  PythonQueries.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-06.
//
// PythonQueries.swift
// Make sure no tab characters are present; use only spaces for indentation.

import Foundation

let pythonQuery = """
; Identifier naming conventions

(identifier) @variable

((identifier) @constructor
 (#match? @constructor "^[A-Z]"))

((identifier) @constant
 (#match? @constant "^[A-Z][A-Z_]*$"))

; Function calls

(decorator) @function
(decorator
  (identifier) @function)

(call
  function: (attribute attribute: (identifier) @function.method))
(call
  function: (identifier) @function)

; Builtin functions

((call
  function: (identifier) @function.builtin)
 (#match?
   @function.builtin
   "^(abs|all|any|ascii|bin|bool|breakpoint|bytearray|bytes|callable|chr|classmethod|compile|complex|delattr|dict|dir|divmod|enumerate|eval|exec|filter|float|format|frozenset|getattr|globals|hasattr|hash|help|hex|id|input|int|isinstance|issubclass|iter|len|list|locals|map|max|memoryview|min|next|object|oct|open|ord|pow|print|property|range|repr|reversed|round|set|setattr|slice|sorted|staticmethod|str|sum|super|tuple|type|vars|zip|__import__)$"))

; Function definitions

(function_definition
  name: (identifier) @function)

(attribute attribute: (identifier) @property)
(type (identifier) @type)

; Literals

[
  (none)
  (true)
  (false)
] @constant.builtin

[
  (integer)
  (float)
] @number

(comment) @comment
(string) @string
(escape_sequence) @escape

(interpolation
  "{" @punctuation.special
  "}" @punctuation.special) @embedded

[
  "-"
  "-="
  "!="
  "*"
  "**"
  "**="
  "*="
  "/"
  "//"
  "//="
  "/="
  "&"
  "&="
  "%"
  "%="
  "^"
  "^="
  "+"
  "->"
  "+="
  "<"
  "<<"
  "<<="
  "<="
  "<>"
  "="
  ":="
  "=="
  ">"
  ">="
  ">>"
  ">>="
  "|"
  "|="
  "~"
  "@="
  "and"
  "in"
  "is"
  "not"
  "or"
  "is not"
  "not in"
] @operator

[
  "as"
  "assert"
  "async"
  "await"
  "break"
  "class"
  "continue"
  "def"
  "del"
  "elif"
  "else"
  "except"
  "exec"
  "finally"
  "for"
  "from"
  "global"
  "if"
  "import"
  "lambda"
  "nonlocal"
  "pass"
  "print"
  "raise"
  "return"
  "try"
  "while"
  "with"
  "yield"
  "match"
  "case"
] @keyword
"""

let pythonCodeMapQuery = #"""
; ===================================
; 1) Class Declarations
; ===================================
(class_definition
  name: (identifier) @type.class) @type.class.decl

; ===================================
; 2) Import Declarations
; ===================================
(import_statement) @import
(import_from_statement) @import

; ===================================
; 3) Function Declarations
;    Capture the entire function_definition node so we get `def foo(...):`.
; ===================================
(function_definition) @function.definition

; ===================================
; 4) Variable Declarations (top-level or class-level)
;    We ignore local vars in function bodies for simplicity.
; ===================================
(module
  (expression_statement
	(assignment
	  left: (identifier) @variable.global
	)
  )
)

(class_definition
  body: (block
	(expression_statement
	  (assignment
		left: (identifier) @variable.global
	  )
	)
  )
)

; ============ Plain Parameters ============
(parameters
  (identifier) @function.param)

; ============ Default Parameters ============
(parameters
  (default_parameter) @function.param)
"""#
