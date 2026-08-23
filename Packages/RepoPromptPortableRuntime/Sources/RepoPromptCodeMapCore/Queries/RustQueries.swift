let rustCodeMapQuery = #"""
; ===================================
; 1) Struct Declarations
; ===================================
(struct_item
  (type_identifier) @type.struct) @type.class.decl

; ===================================
; 2) Import Declarations
; ===================================
(use_declaration) @import

; ===================================
; 3) Function Declarations
;    (top-level free functions only)
; ----------------------------------
(source_file
	(function_item
	(identifier) @function.definition))

(source_file
	(function_signature_item
	(identifier) @function.definition))

; ===================================
; 4) Global Variables
;    Typically top-level `const_item` or `static_item`.
; ===================================
(const_item
  (identifier) @variable.global)

(static_item
  (identifier) @variable.global)

; ===================================
; 5) Struct Fields
;    If you want only `pub` fields, you’ll need extra logic.
; ===================================
(field_declaration
  (field_identifier) @variable.field)

; ===================================
; 6) Enum Declarations
; ===================================
(enum_item
  (type_identifier) @type.enum) @type.enum.decl

; ===================================
; 7) Enum Variants
; ===================================
(enum_variant
  (identifier) @enum.entry)

; ===================================
; 8) Trait Declarations
; ===================================
(trait_item
  (type_identifier) @type.interface) @type.interface.decl

; ===================================
; 9) Impl Items (methods inside impl)
;    Functions appear under a `declaration_list`.
; ===================================
(impl_item
  type: (type_identifier) @rust.impl.type
) @rust.impl.decl

(impl_item
  type: (generic_type
    type: (type_identifier) @rust.impl.type
  )
) @rust.impl.decl

(impl_item
  (declaration_list
	(function_item
	  (identifier) @function.definition
	)+
  )
)
"""#
