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
