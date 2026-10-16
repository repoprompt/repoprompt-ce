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
