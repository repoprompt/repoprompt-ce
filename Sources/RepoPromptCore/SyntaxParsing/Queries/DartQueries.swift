//
//  DartQueries.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-06.
//
//  DartQueries.swift
//  Make sure no tab characters are present; use only spaces for indentation.

import Foundation

let dartQuery = """
; Variable
(identifier) @variable

; Keywords
; --------------------
[
	(assert_builtin)
	(break_builtin)
	(const_builtin)
	(part_of_builtin)
	(rethrow_builtin)
	(void_type)
	"abstract"
	"as"
	"async"
	"async*"
	"await"
	"base"
	"case"
	"catch"
	"class"
	"continue"
	"covariant"
	"default"
	"deferred"
	"do"
	"dynamic"
	"else"
	"enum"
	"export"
	"extends"
	"extension"
	"external"
	"factory"
	"final"
	"finally"
	"for"
	"Function"
	"get"
	"hide"
	"if"
	"implements"
	"import"
	"in"
	"interface"
	"is"
	"late"
	"library"
	"mixin"
	"new"
	"on"
	"operator"
	"part"
	"required"
	"return"
	"sealed"
	"set"
	"show"
	"static"
	"super"
	"switch"
	"sync*"
	"throw"
	"try"
	"typedef"
	"var"
	"when"
	"while"
	"with"
	"yield"
] @keyword

; Methods
; --------------------

; NOTE: This query is a bit of a work around for the fact that the dart grammar doesn't
; specifically identify a node as a function call
(((identifier) @function (#match? @function "^_?[a-z]"))
 . (selector . (argument_part))) @function

; Annotations
; --------------------
(annotation
  name: (identifier) @attribute)

; Operators and Tokens
; --------------------
(template_substitution
  "$" @punctuation.special
  "{" @punctuation.special
  "}" @punctuation.special
) @none

(template_substitution
  "$" @punctuation.special
  (identifier_dollar_escaped) @variable
) @none

(escape_sequence) @string.escape

[
 "@" 
 "=>"
 ".."
 "??"
 "=="
 "?"
 ":"
 "&&"
 "%"
 "<"
 ">"
 "="
 ">="
 "<="
 "||"
 "~/"
 (increment_operator)
 (is_operator)
 (prefix_operator)
 (equality_operator)
 (additive_operator)
] @operator

(type_arguments
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

(type_parameters
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

[
  "("
  ")"
  "["
  "]"
  "{"
  "}"
] @punctuation.bracket

; Delimiters
; --------------------
[
  ";"
  "."
  ","
] @punctuation.delimiter

; Types
; --------------------
(type_identifier) @type
((type_identifier) @type.builtin
  (#match? @type.builtin "^(int|double|String|bool|List|Set|Map|Runes|Symbol)$"))
(class_definition
  name: (identifier) @type)
(constructor_signature
  name: (identifier) @type)
(scoped_identifier
  scope: (identifier) @type)
(function_signature
  name: (identifier) @function)
(getter_signature
  (identifier) @function)
(setter_signature
  name: (identifier) @function)

((scoped_identifier
  scope: (identifier) @type
  name: (identifier) @type)
 (#match? @type "^[a-zA-Z]"))

; Enums
; -------------------
(enum_declaration
  name: (identifier) @type)
(enum_constant
  name: (identifier) @identifier.constant)

; Variables
; --------------------
; var keyword
(inferred_type) @keyword

((identifier) @type
 (#match? @type "^_?[A-Z].*[a-z]"))

("Function" @type)

(this) @variable.builtin

; properties

(unconditional_assignable_selector
  (identifier) @property)

(conditional_assignable_selector
  (identifier) @property)

(cascade_section
  (cascade_selector
	(identifier) @property))

((selector
  (unconditional_assignable_selector (identifier) @function))
  (selector (argument_part (arguments)))
)

(cascade_section
  (cascade_selector (identifier) @function)
  (argument_part (arguments))
)

; assignments
(assignment_expression
  left: (assignable_expression) @variable)

(this) @variable.builtin

; Parameters
; --------------------
(formal_parameter
	name: (identifier) @identifier.parameter)

(named_argument
  (label (identifier) @identifier.parameter))

; Literals
; --------------------
[
	(hex_integer_literal)
	(decimal_integer_literal)
	(decimal_floating_point_literal)
	; TODO: inaccessbile nodes
	; (octal_integer_literal)
	; (hex_floating_point_literal)
] @number

(string_literal) @string
(symbol_literal (identifier) @constant) @constant
(true) @boolean
(false) @boolean
(null_literal) @constant.null

(documentation_comment) @comment
(comment) @comment
"""

let dartCodeMapQuery = """
; ===================================
; 1) Class Declarations
; ===================================
(class_definition
  name: (identifier) @type.class) @type.class.decl

; ===================================
; 2) Constructor Declarations (incl. factory)
; ===================================
(constructor_signature
	(identifier) @function.definition)

; factory constructors (e.g. "factory Foo.bar(...)")
(method_signature
	(factory_constructor_signature
	(_)
	"."
	(identifier) @function.definition))

; ===================================
; 3) Function / Method Declarations
;    – top-level functions (direct child of program)
;    – methods  (function_signature inside method_signature)
;    – getters / setters
; ===================================
(program
  (function_signature
	name: (identifier) @function.definition))

(method_signature
  (function_signature
	name: (identifier) @function.definition))

(getter_signature
  name: (identifier) @function.definition)

(setter_signature
  name: (identifier) @function.definition)

; ===================================
; 4) Variable Declarations
; ===================================
(program
  (declaration
	(initialized_identifier_list
	  (initialized_identifier
		(identifier) @variable.global))))

; ===================================
; 5) Parameter Declarations
; ===================================
(formal_parameter
  (identifier) @function.param)
"""
