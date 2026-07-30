let javascriptCodeMapQuery = #"""
; =============================================================================
; JavaScript code-map query  •  v5.0  •  2025-01-11
; Further refined for better code mapping
; =============================================================================

; =============================================================================
; 1) Import Declarations
; =============================================================================
(import_statement) @import

; =============================================================================
; 2) Export Declarations (re-exports only)
; =============================================================================
(export_statement
  source: (string)) @export

; Direct export statements (export class/const/function/etc.)
(export_statement) @export

; =============================================================================
; 3) Class Declarations
; =============================================================================
(class_declaration
  name: (identifier) @class)

; =============================================================================
; 4) Function Declarations - ONLY at program/module top level
; =============================================================================
; Regular function declarations - must be direct child of program
(program
  (function_declaration
	name: (identifier) @function.definition))

; Generator functions - must be direct child of program
(program
  (generator_function_declaration
	name: (identifier) @function.definition))

; Exported function declarations
(program
  (export_statement
	declaration: (function_declaration
	  name: (identifier) @function.definition)))

; =============================================================================
; 5) Method Definitions inside classes ONLY
; =============================================================================
(class_body
  (method_definition
	name: (property_identifier) @method))

(class_body
  (method_definition
	name: (string) @method))

(class_body
  (method_definition
	name: (number) @method))

; =============================================================================
; 6) Top-level arrow/function expression assignments ONLY
; =============================================================================
; Arrow functions - direct children of program only
(program
  (variable_declaration
	(variable_declarator
	  name: (identifier) @function.definition
	  value: (arrow_function))))

(program
  (lexical_declaration
	(variable_declarator
	  name: (identifier) @function.definition
	  value: (arrow_function))))

; Function expressions - direct children of program only
(program
  (variable_declaration
	(variable_declarator
	  name: (identifier) @function.definition
	  value: (function_expression))))

(program
  (lexical_declaration
	(variable_declarator
	  name: (identifier) @function.definition
	  value: (function_expression))))

; =============================================================================
; 7) Global Variables - Excluding functions and complex patterns
; =============================================================================
; Simple initialized variables (not functions)
(program
  (variable_declaration
	(variable_declarator
	  name: (identifier) @variable.global
	  value: [
		(string)
		(template_string)
		(number)
		(true)
		(false)
		(null)
		(undefined)
		(array)
		(regex)
		(new_expression)
		(call_expression)
		(await_expression)
		(identifier)
		(binary_expression)
		(unary_expression)
		(update_expression)
		(ternary_expression)
		(member_expression)
	  ])))

(program
  (lexical_declaration
	(variable_declarator
	  name: (identifier) @variable.global
	  value: [
		(string)
		(template_string)
		(number)
		(true)
		(false)
		(null)
		(undefined)
		(array)
		(regex)
		(new_expression)
		(call_expression)
		(await_expression)
		(identifier)
		(binary_expression)
		(unary_expression)
		(update_expression)
		(ternary_expression)
		(member_expression)
	  ])))

; Object literals (potential class-like structures) - separate handling
(program
  (variable_declaration
	(variable_declarator
	  name: (identifier) @variable.global
	  value: (object))))

(program
  (lexical_declaration
	(variable_declarator
	  name: (identifier) @variable.global
	  value: (object))))

; Uninitialized variables
(program
  (variable_declaration
	(variable_declarator
	  name: (identifier) @variable.global
	  !value)))

(program
  (lexical_declaration
	(variable_declarator
	  name: (identifier) @variable.global
	  !value)))

; =============================================================================
; 8) Class Fields/Properties
; =============================================================================
(class_body
  (field_definition
	property: (property_identifier) @variable.field))

(class_body
  (field_definition
	property: (private_property_identifier) @variable.field))

; =============================================================================
; 9) CommonJS Exports
; =============================================================================
; exports.functionName = function
(program
  (expression_statement
	(assignment_expression
	  left: (member_expression
		object: (identifier) @_exp (#eq? @_exp "exports")
		property: (property_identifier) @function.definition)
	  right: [(function_expression) (arrow_function)])))

; exports.propertyName = value (non-function)
(program
  (expression_statement
	(assignment_expression
	  left: (member_expression
		object: (identifier) @_exp (#eq? @_exp "exports")
		property: (property_identifier) @variable.global)
	  right: [
		(string)
		(template_string)
		(number)
		(true)
		(false)
		(null)
		(undefined)
		(object)
		(array)
		(identifier)
	  ])))

; =============================================================================
; 10) Parameters
; =============================================================================
(formal_parameters
  (identifier) @function.param)

(formal_parameters
  (rest_pattern
	(identifier) @function.param))

(formal_parameters
  (object_pattern
	(shorthand_property_identifier_pattern) @function.param))

; =============================================================================
; NOTE: This query works best with CodeMapGenerator as-is.
; For better object-as-class support, CodeMapGenerator would need modification.
; =============================================================================
"""#
