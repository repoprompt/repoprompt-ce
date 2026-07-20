let rubyCodeMapQuery = #"""
; ==========================
; 1) Imports (require)
; ==========================
(call
  method: (identifier) @import
  (#match? @import "^(require|require_relative)$"))

; ==========================
; 2) Class / Module declarations
; ==========================
(class
  name: (constant) @type.class) @type.class.decl

(class
  name: (scope_resolution) @type.class) @type.class.decl

(module
  name: (constant) @type.class) @type.class.decl

(module
  name: (scope_resolution) @type.class) @type.class.decl

; ==========================
; 3) Methods
; ==========================
(method
  name: (_) @function.definition) @function.definition

(singleton_method
  name: (_) @function.definition) @function.definition

; ==========================
; 4) Variables / Constants
; ==========================
(assignment
  left: (instance_variable) @variable.field)

(assignment
  left: (class_variable) @variable.field)

(assignment
  left: (global_variable) @variable.global)

(assignment
  left: (constant) @constant.global)

(operator_assignment
  left: (instance_variable) @variable.field)

(operator_assignment
  left: (class_variable) @variable.field)

(operator_assignment
  left: (global_variable) @variable.global)

(operator_assignment
  left: (constant) @constant.global)
"""#
