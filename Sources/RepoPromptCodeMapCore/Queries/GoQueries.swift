let goCodeMapQuery = #"""
; ===================================
; 1) Package Declarations
; ===================================
(package_clause
  "package"
  (package_identifier) @package)

; ===================================
; 2) Import Declarations
; (This block was working already)
; ===================================
(import_declaration) @import
(import_spec
  (interpreted_string_literal) @import.path)

; ===================================
; 3) Function Declarations
; (This block was working already)
; ===================================
(function_declaration
  name: (identifier) @function.definition)

(method_declaration
  name: (field_identifier) @function.definition)

; ===================================
; 4) Global Variables (var)
; ===================================
(source_file
  (var_declaration
	(var_spec
	  (identifier)+ @variable.global
	  ; Optionally capture the type or init expression if needed
	)+))

; ===================================
; 5) Global Constants (const)
; ===================================
(source_file
  (const_declaration
	(const_spec
	  (identifier)+ @variable.global
	  ; Optionally capture type/expression
	)+))

; ===================================
; 6) Struct Declarations
; (This block was working already)
; ===================================
(type_declaration
  (type_spec
	name: (type_identifier) @type.struct
	type: (struct_type))) @type.class.decl

; ===================================
; 7) Struct Fields
; ===================================
(field_declaration
  (field_identifier)+ @variable.field
  ; e.g. (#match? @variable.field "^[A-Z]") if only exported
)
"""#
