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
