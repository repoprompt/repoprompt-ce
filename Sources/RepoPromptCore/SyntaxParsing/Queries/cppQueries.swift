//
//  cppQueries.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-06.
//

// CppQueries.swift
// Make sure no tab characters are present; use only spaces for indentation.

import Foundation

let cppQuery = """
; Functions

(call_expression
  function: (qualified_identifier
	name: (identifier) @function))

(template_function
  name: (identifier) @function)

(template_method
  name: (field_identifier) @function)

(template_function
  name: (identifier) @function)

(function_declarator
  declarator: (qualified_identifier
	name: (identifier) @function))

(function_declarator
  declarator: (field_identifier) @function)

; Types

((namespace_identifier) @type
 (#match? @type "^[A-Z]"))

(auto) @type

; Constants

(this) @variable.builtin
(null "nullptr" @constant)

; Modules
(module_name
  (identifier) @module)

; Keywords

[
 "catch"
 "class"
 "co_await"
 "co_return"
 "co_yield"
 "constexpr"
 "constinit"
 "consteval"
 "delete"
 "explicit"
 "final"
 "friend"
 "mutable"
 "namespace"
 "noexcept"
 "new"
 "override"
 "private"
 "protected"
 "public"
 "template"
 "throw"
 "try"
 "typename"
 "using"
 "concept"
 "requires"
 "virtual"
 "import"
 "export"
 "module"
] @keyword

; Strings

(raw_string_literal) @string
"""

// New C++ Code‑Map Query modeled after the Swift version.
// This query is organized into sections similar to the Swift query,
// but with node types and names specialized for C++.

// CppQueries.swift
// New C++ Code‑Map Query modeled after the Swift version.
// Adjusted for tree-sitter-cpp using union patterns for member variables.

let cppCodeMapQuery = #"""
; ===================================
; 1) Import Declarations
;    #include lines, captured as “@import”
; ===================================
(preproc_include) @import

; ===================================
; 2) Function Declarations
;    ...
(function_definition
  declarator: (function_declarator
	declarator: (identifier) @function.definition
  )
)
(function_definition
  declarator: (function_declarator
	declarator: (field_identifier) @function.definition
  )
)
(function_definition
  declarator: (function_declarator
	declarator: (qualified_identifier
	  name: (identifier) @function.definition
	)
  )
)

; ===================================
; 3) Global Variable Declarations
;    ...
(translation_unit
  (declaration
	(init_declarator
	  declarator: (identifier) @variable.global
	)
  )
)

; ===================================
; 4) Macros
;    ...
(preproc_def) @macro

; ===================================
; 5) Parameter Declarations
;    ...
(parameter_declaration
  declarator: (identifier) @function.param
)

; ===================================
; 6) Enum Entries
;    ...
(enumerator
  name: (identifier) @enum.entry
)

; ===================================
; 7) Struct & Class Declarations
;    Only capture real definitions with braces
; ===================================
(struct_specifier
  name: (type_identifier) @type.class
  body: (field_declaration_list)
) @type.class.decl

(class_specifier
  name: (type_identifier) @type.class
  body: (field_declaration_list)
) @type.class.decl

; Enum declarations (for range containment of enum methods)
(enum_specifier
  name: (type_identifier) @type.enum
) @type.enum.decl
"""#
