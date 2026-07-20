let swiftCodeMapQuery = #"""
; ===================================
; Swift CodeMap Query - Updated for range-based containment
; ===================================

; ===================================
; 1) Type Container Declarations (with full range for containment)
; ===================================
; Capture class/struct/actor/enum/extension declarations - full node for range
; NOTE: In tree-sitter-swift, extensions are also parsed as class_declaration
; with declaration_kind: "extension", so this single pattern captures all of them
(class_declaration) @swift.type.decl

; Capture the type name separately - handles simple type identifiers
(class_declaration
  name: (type_identifier) @swift.type.name)

; Capture the type name when wrapped in user_type (common for extensions)
; This is critical for extensions like "extension Foo" where name is user_type
(class_declaration
  name: (user_type (type_identifier) @swift.type.name))

; Protocol declarations (separate for interfaces bucket)
(protocol_declaration) @swift.protocol.decl

(protocol_declaration
  name: (type_identifier) @swift.protocol.name)

; ===================================
; 2) Import Declarations
; ===================================
(import_declaration) @import

; ===================================
; 3) Top-level Function Declarations (global functions)
;    Only functions directly under source_file
; ===================================
(source_file
  (function_declaration) @swift.function.toplevel)

; ===================================
; 4) Member Functions (methods inside type bodies)
; ===================================
; NOTE: Extensions also use class_body in tree-sitter-swift, so this pattern
; already captures methods inside extensions - no separate extension_body needed
(class_body
  (function_declaration) @swift.function.method)

(enum_class_body
  (function_declaration) @swift.function.method)

(protocol_body
  (protocol_function_declaration) @swift.protocol.method)

; ===================================
; 5) Function Names (for all function types)
; ===================================
(function_declaration
  name: (simple_identifier) @swift.function.name)

(protocol_function_declaration
  name: (simple_identifier) @swift.function.name)

; ===================================
; 6) Parameter Declarations (with proper field captures)
; ===================================
; Capture the full parameter node for grouping
(parameter) @swift.param.node

; Capture parameter components using grammar fields
(parameter
  external_name: (simple_identifier) @swift.param.external)

(parameter
  name: (simple_identifier) @swift.param.local)

; Capture the parameter's type by position (field label doesn't work reliably)
(parameter
  ":"
  (parameter_modifiers)?
  (_) @swift.param.type)

; ===================================
; 7) Property Declarations
; ===================================
; Capture full property declarations for precise extraction
(property_declaration) @swift.property.decl
(protocol_property_declaration) @swift.protocol.property.decl

; Top-level properties (globals)
(source_file
  (property_declaration
    (value_binding_pattern)
    (pattern (simple_identifier) @swift.property.toplevel)
  )
)

; Class/struct/enum member properties
(class_body
  (property_declaration
    (value_binding_pattern)
    (pattern (simple_identifier) @swift.property.member)
  )
)

(enum_class_body
  (property_declaration
    (value_binding_pattern)
    (pattern (simple_identifier) @swift.property.member)
  )
)

; NOTE: Extension properties are captured by class_body pattern above since
; tree-sitter-swift uses class_body for extensions too

; Protocol property declarations
(protocol_property_declaration
  (pattern (simple_identifier) @swift.protocol.property))

; ===================================
; 8) Enum Declarations (body-discriminated)
; ===================================
(class_declaration
  name: (type_identifier) @type.enum
  body: (enum_class_body))

; ===================================
; 9) Enum Entries
; ===================================
(enum_entry
  name: (simple_identifier) @enum.entry)

; ===================================
; 10) Macros
; ===================================
(macro_declaration) @macro

; ===================================
; Legacy captures for backwards compatibility
; (used by existing routing until Swift-specific path is complete)
; ===================================
(class_declaration
  name: (type_identifier) @type.class)

(function_declaration) @function.definition
"""#
