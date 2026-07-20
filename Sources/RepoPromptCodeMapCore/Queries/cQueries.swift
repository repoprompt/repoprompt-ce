let cCodeMapQuery = #"""
; ===================================
; 1) Import Declarations (#include)
; ===================================
(preproc_include) @import

; ===================================
; 2) Function Definitions
;    e.g. int main() { ... }
; ===================================
(function_definition
  declarator: (function_declarator
	declarator: (identifier) @function.definition
  )
)

; ===================================
; 3) Global Variables
;    Matches various top-level forms,
;    including multiple declarations (int a=0, b=1;),
;    pointers (int *p), arrays (char arr[10]), etc.
; ===================================

; 3a) init_declarator (e.g. int a=0, b=1;)
(translation_unit
  (declaration
	(init_declarator
	  declarator: (identifier) @variable.global
	)
  )
)

; 3b) pointer_declarator (e.g. int *ptr;)
(translation_unit
  (declaration
	(pointer_declarator
	  declarator: (identifier) @variable.global
	)
  )
)

; 3c) array_declarator (e.g. int arr[100];)
(translation_unit
  (declaration
	(array_declarator
	  declarator: (identifier) @variable.global
	)
  )
)

; 3d) single direct declarator (e.g. int x;)
(translation_unit
  (declaration
	declarator: (identifier) @variable.global
  )
)

; ===================================
; 4) Struct & Union Declarations
;    Named with optional braces
; ===================================
(struct_specifier
  (type_identifier)? @type.struct
  (field_declaration_list)?
) @type.class.decl

(union_specifier
  (type_identifier)? @type.struct
  (field_declaration_list)?
) @type.class.decl

; ===================================
; 5) Struct Fields
; ===================================
(field_declaration
  declarator: (field_identifier) @variable.field)

(field_declaration
  declarator: (pointer_declarator
	declarator: (field_identifier) @variable.field))

(field_declaration
  declarator: (array_declarator
	declarator: (field_identifier) @variable.field))

; ===================================
; 6) Enum Declarations
;    Named enum with optional enumerators
; ===================================
(enum_specifier
  name: (type_identifier) @type.enum
  (enumerator_list)?
) @type.enum.decl

; typedef enum { ... } Name;
(type_definition
  type: (enum_specifier)
  declarator: (type_identifier) @type.enum
) @type.enum.decl

; ===================================
; 7) Enum Variants
; ===================================
(enumerator
  name: (identifier) @enum.entry
)

; ===================================
; 8) Macros
;    Captures both function-style and simple #defines
; ===================================
(preproc_function_def
  name: (identifier) @macro)

(preproc_def
  name: (identifier) @macro)
"""#

/*
 ; ===================================
 ; 5) Struct / Union Fields
 ;    Each struct_declarator with an identifier
 ; ===================================
 (struct_declaration
 (specifier_qualifier_list)
 (struct_declarator_list
 (struct_declarator
 declarator: (choice
 (pointer_declarator
 declarator: (identifier) @variable.field
 )
 (array_declarator
 declarator: (identifier) @variable.field
 )
 (identifier) @variable.field
 )
 )+
 )
 ";"
 )

 */
