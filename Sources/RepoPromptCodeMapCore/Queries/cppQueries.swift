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
