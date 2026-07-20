let phpCodeMapQuery = #"""
; ==========================
; 1) Namespaces & Imports
; ==========================
(namespace_definition
  name: (namespace_name) @module)

(namespace_use_clause
  (name) @import)

(namespace_use_clause
  (qualified_name (name) @import))

; ==========================
; 2) Class-like declarations
; ==========================
(class_declaration      name: (name) @type.class) @type.class.decl
(interface_declaration  name: (name) @type.interface) @type.interface.decl
(trait_declaration      name: (name) @type.trait) @type.class.decl
(enum_declaration       name: (name) @type.enum) @type.enum.decl

; ==========================
; 3) Functions & Methods
; ==========================
(function_definition    name: (name) @function.definition)
(method_declaration     name: (name) @function.definition)

; ==========================
; 4) Properties - ONLY actual property declarations
; ==========================
(property_declaration
  (property_element
	(variable_name (name) @variable.field)))

; ==========================
; 5) Constants - class constants only
; ==========================
(const_declaration
  (const_element
	(name) @constant.class))

; ==========================
; 6) Parameters
; ==========================
(formal_parameters
  (simple_parameter
	name: (variable_name (name) @function.param)))

(formal_parameters
  (property_promotion_parameter
	name: (variable_name (name) @function.param)))

(formal_parameters
  (variadic_parameter
	name: (variable_name (name) @function.param)))

; ==========================
; 7) Enum Cases
; ==========================
(enum_case
  name: (name) @enum.entry)
"""#
