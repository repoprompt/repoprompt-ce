let csharpCodeMapQuery = #"""
; ===================================
; 1) Class Declarations
; ===================================
(class_declaration
  name: (identifier) @type.class) @type.class.decl

(struct_declaration
  name: (identifier) @type.struct) @type.class.decl

(interface_declaration
  name: (identifier) @type.interface) @type.interface.decl

; ===================================
; 2) Import ("using") Declarations
; ===================================
(using_directive) @import

; ===================================
; 3) Enum Declarations
; ===================================
(enum_declaration
  name: (identifier) @type.enum) @type.enum.decl

; ===================================
; 4) Enum Members
; ===================================
(enum_member_declaration
  name: (identifier) @enum.entry)

; ===================================
; 5) Method Declarations (top-level in a class or struct)
; ===================================
(method_declaration
  name: (identifier) @function.definition)

; Local functions (C# 7+)
(local_function_statement
  name: (identifier) @function.definition)

; ===================================
; 6) Field / Global Variables
;    For “global” in standard C#, we rely on static fields in top-level classes,
;    or top-level statements in file-scoped namespaces in newer versions.
; ===================================
(field_declaration
  (variable_declaration
	(variable_declarator
	  name: (identifier) @variable.global)))

; ===================================
; 7) Property Declarations
;    You can treat these as variables or keep them separate.
; ===================================
(property_declaration
  name: (identifier) @variable.global)

; ===================================
; 8) Parameter Declarations
;    The "parameter" node in the C# grammar typically holds (identifier) children.
; ===================================
(parameter
  name: (identifier) @function.param)
"""#
