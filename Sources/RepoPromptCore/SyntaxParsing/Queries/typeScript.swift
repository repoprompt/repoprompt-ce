//
//  typeScript.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-10.
//

//
//  typeScript.swift
//  RepoPrompt
//
//  Created by Eric Provencher on 2025-02-10.
//  Contains two queries for TypeScript/TSX:
//   1) A highlight query (combining highlights.scm, locals.scm, tags.scm).
//   2) A code-map query for tracking top-level imports, classes, interfaces, functions, etc.
//  Uses only spaces for indentation.
//

import Foundation

/// Main highlight query for TypeScript/TSX.
/// Combines the logic from highlights.scm, locals.scm, and tags.scm.
let typeScriptHighlightQuery = #"""
; ---- Types ----
(type_identifier) @type
(predefined_type) @type.builtin

((identifier) @type
 (#match? @type "^[A-Z]"))

(type_arguments
  "<" @punctuation.bracket
  ">" @punctuation.bracket)

; ---- Variables ----
(required_parameter (identifier) @variable.parameter)
(optional_parameter (identifier) @variable.parameter)

; ---- Keywords ----
[ "abstract"
  "declare"
  "enum"
  "export"
  "implements"
  "interface"
  "keyof"
  "namespace"
  "private"
  "protected"
  "public"
  "type"
  "readonly"
  "override"
  "satisfies"
] @keyword

; ---- Locals (from locals.scm) ----
(required_parameter (identifier) @local.definition)
(optional_parameter (identifier) @local.definition)

; ---- Definitions (from tags.scm) ----
(function_signature
  name: (identifier) @definition.function)

(method_signature
  name: (property_identifier) @definition.method)

(abstract_method_signature
  name: (property_identifier) @definition.method)

(abstract_class_declaration
  name: (type_identifier) @definition.class)

(module
  name: (identifier) @definition.module)

(interface_declaration
  name: (type_identifier) @definition.interface)

(type_annotation
  (type_identifier) @reference.type)

(new_expression
  constructor: (identifier) @reference.class)
"""#

/// Code-map query for TypeScript / TSX
/// Captures used by `CodeMapGenerator`:
///   • @import        – top-level imports
///   • @export        – export statements (NOTE: Currently captures full declaration body)
///   • @type.class    – class names (matches Swift pattern)
///   • @interface     – interface names
///   • @type.enum     – enum names
///   • @function.definition – functions and methods
///   • @variable.global – variables and class properties
///   • @typeAlias     – type-alias declarations
let typeScriptCodeMapQuery = #"""
; =============================================================================
; TypeScript code-map query  •  v3.0  •  2026-01-29
; Works with tree-sitter-typescript 0.20.2
;
; Updated to use capture names that match CodeMapGenerator routing:
;   - @method for class methods (not @function.definition)
;   - @variable.field for class fields (not @variable.global)
;   - @method_signature, @property_signature for interface members
;   - Container range captures for range-based containment
; =============================================================================


; =============================================================================
; Top-level Container Range Captures (prevents local container leakage)
; =============================================================================
(program (class_declaration) @ts.class.decl)
(program (export_statement (class_declaration) @ts.class.decl))

(program (interface_declaration) @ts.interface.decl)
(program (export_statement (interface_declaration) @ts.interface.decl))


; =============================================================================
; Imports
; =============================================================================
(import_statement) @import



; =============================================================================
; Exports (all export statements + source for re-exports)
; =============================================================================
(program (export_statement) @export)
(program (export_statement source: (string) @export.source))



; =============================================================================
; Top-level Classes (name capture for boundaries)
; =============================================================================
(program
    (class_declaration
        name: (type_identifier) @type.class))
(program
    (export_statement
        (class_declaration
            name: (type_identifier) @type.class)))



; =============================================================================
; Class Members: Methods -> @method (scoped to top-level classes only)
; =============================================================================
(program
    (class_declaration
        body: (class_body
            (method_definition
                name: (property_identifier) @method))))
(program
    (export_statement
        (class_declaration
            body: (class_body
                (method_definition
                    name: (property_identifier) @method)))))

(program
    (class_declaration
        body: (class_body
            (method_definition
                name: (private_property_identifier) @method))))
(program
    (export_statement
        (class_declaration
            body: (class_body
                (method_definition
                    name: (private_property_identifier) @method)))))

;; Computed method names
(program
    (class_declaration
        body: (class_body
            (method_definition
                name: (computed_property_name) @method))))
(program
    (export_statement
        (class_declaration
            body: (class_body
                (method_definition
                    name: (computed_property_name) @method)))))

;; Signatures inside class bodies (abstract/overload-like)
(program
    (class_declaration
        body: (class_body
            (method_signature
                name: (property_identifier) @method))))
(program
    (export_statement
        (class_declaration
            body: (class_body
                (method_signature
                    name: (property_identifier) @method)))))

(program
    (class_declaration
        body: (class_body
            (abstract_method_signature
                name: (property_identifier) @method))))
(program
    (export_statement
        (class_declaration
            body: (class_body
                (abstract_method_signature
                    name: (property_identifier) @method)))))


; =============================================================================
; Class Members: Fields -> @variable.field (scoped to top-level classes only)
; =============================================================================
(program
    (class_declaration
        body: (class_body
            (public_field_definition
                name: (property_identifier) @variable.field))))
(program
    (export_statement
        (class_declaration
            body: (class_body
                (public_field_definition
                    name: (property_identifier) @variable.field)))))

(program
    (class_declaration
        body: (class_body
            (public_field_definition
                name: (private_property_identifier) @variable.field))))
(program
    (export_statement
        (class_declaration
            body: (class_body
                (public_field_definition
                    name: (private_property_identifier) @variable.field)))))


; =============================================================================
; Top-level Interfaces (name capture for boundaries)
; =============================================================================
(program
    (interface_declaration
        name: (type_identifier) @interface))
(program
    (export_statement
        (interface_declaration
            name: (type_identifier) @interface)))



; =============================================================================
; Interface Members (scoped to top-level interfaces only)
; =============================================================================
(program
    (interface_declaration
        body: (interface_body
            (method_signature
                name: (property_identifier) @method_signature))))
(program
    (export_statement
        (interface_declaration
            body: (interface_body
                (method_signature
                    name: (property_identifier) @method_signature)))))

(program
    (interface_declaration
        body: (interface_body
            (property_signature
                name: (property_identifier) @property_signature))))
(program
    (export_statement
        (interface_declaration
            body: (interface_body
                (property_signature
                    name: (property_identifier) @property_signature)))))

(program
    (interface_declaration
        body: (interface_body
            (call_signature) @call_signature)))
(program
    (export_statement
        (interface_declaration
            body: (interface_body
                (call_signature) @call_signature))))

(program
    (interface_declaration
        body: (interface_body
            (construct_signature) @construct_signature)))
(program
    (export_statement
        (interface_declaration
            body: (interface_body
                (construct_signature) @construct_signature))))

(program
    (interface_declaration
        body: (interface_body
            (index_signature) @index_signature)))
(program
    (export_statement
        (interface_declaration
            body: (interface_body
                (index_signature) @index_signature))))


; =============================================================================
; Top-level Type Aliases (prevents local type alias leakage)
; =============================================================================
(program
    (type_alias_declaration
        name: (type_identifier) @typeAlias))
(program
    (export_statement
        (type_alias_declaration
            name: (type_identifier) @typeAlias)))



; =============================================================================
; Top-level Enums (prevents local enum leakage)
; =============================================================================
(program
    (enum_declaration
        name: (identifier) @type.enum))
(program
    (export_statement
        (enum_declaration
            name: (identifier) @type.enum)))

;; Enum entries (cases) - scoped to top-level enums
(program
    (enum_declaration
        body: (enum_body
            (enum_assignment
                name: (property_identifier) @enum.entry))))
(program
    (export_statement
        (enum_declaration
            body: (enum_body
                (enum_assignment
                    name: (property_identifier) @enum.entry)))))

(program
    (enum_declaration
        body: (enum_body
            (enum_assignment
                name: (string) @enum.entry))))
(program
    (export_statement
        (enum_declaration
            body: (enum_body
                (enum_assignment
                    name: (string) @enum.entry)))))



; =============================================================================
; Top-level Functions (scoped to program level)
; =============================================================================
;; Regular function declarations (capture name only to avoid body in definitionLine)
(program
    (function_declaration
        name: (identifier) @function.definition))

(program
    (function_signature
        name: (identifier) @function.definition))

;; Exported function declarations
(program
    (export_statement
        (function_declaration
            name: (identifier) @function.definition)))


; =============================================================================
; Top-level Arrow Functions -> @function.definition
; =============================================================================
;; export const foo = (...) => ...
(program
    (export_statement
        (lexical_declaration
            (variable_declarator
                name: (identifier) @function.definition
                value: (arrow_function)))))

;; const foo = (...) => ...
(program
    (lexical_declaration
        (variable_declarator
            name: (identifier) @function.definition
            value: (arrow_function))))

;; Parenthesized arrow: const foo = ((...) => ...)
(program
    (lexical_declaration
        (variable_declarator
            name: (identifier) @function.definition
            value: (parenthesized_expression (arrow_function)))))
(program
    (export_statement
        (lexical_declaration
            (variable_declarator
                name: (identifier) @function.definition
                value: (parenthesized_expression (arrow_function))))))


; =============================================================================
; Top-level Property Assignment Functions -> @function.definition
; Pattern: Tabs.List = () => ... or Tabs.List = function() {}
; =============================================================================
(program
    (expression_statement
        (assignment_expression
            left: (member_expression) @function.definition
            right: (arrow_function))))

(program
    (expression_statement
        (assignment_expression
            left: (member_expression) @function.definition
            right: (function_expression))))


; =============================================================================
; HOC Wrappers -> @function.definition
; Pattern: forwardRef(...), memo(...), React.forwardRef(...), React.memo(...)
; =============================================================================
;; const Foo = forwardRef(...)
(program
    (lexical_declaration
        (variable_declarator
            name: (identifier) @function.definition
            value: (call_expression
                function: (identifier) @_hoc)))
    (#match? @_hoc "^(forwardRef|memo)$"))
(program
    (export_statement
        (lexical_declaration
            (variable_declarator
                name: (identifier) @function.definition
                value: (call_expression
                    function: (identifier) @_hoc))))
    (#match? @_hoc "^(forwardRef|memo)$"))

;; const Foo = React.forwardRef(...) / React.memo(...)
(program
    (lexical_declaration
        (variable_declarator
            name: (identifier) @function.definition
            value: (call_expression
                function: (member_expression
                    object: (identifier) @_obj
                    property: (property_identifier) @_prop))))
    (#match? @_obj "^React$")
    (#match? @_prop "^(forwardRef|memo)$"))
(program
    (export_statement
        (lexical_declaration
            (variable_declarator
                name: (identifier) @function.definition
                value: (call_expression
                    function: (member_expression
                        object: (identifier) @_obj
                        property: (property_identifier) @_prop)))))
    (#match? @_obj "^React$")
    (#match? @_prop "^(forwardRef|memo)$"))


; =============================================================================
; Object.assign Wrapped Components -> @function.definition
; Pattern: const Accordion = Object.assign(AccordionBase, {...})
; =============================================================================
(program
    (lexical_declaration
        (variable_declarator
            name: (identifier) @function.definition
            value: (call_expression
                function: (member_expression
                    object: (identifier) @_obj2
                    property: (property_identifier) @_prop2))))
    (#match? @_obj2 "^Object$")
    (#match? @_prop2 "^assign$"))
(program
    (export_statement
        (lexical_declaration
            (variable_declarator
                name: (identifier) @function.definition
                value: (call_expression
                    function: (member_expression
                        object: (identifier) @_obj2
                        property: (property_identifier) @_prop2)))))
    (#match? @_obj2 "^Object$")
    (#match? @_prop2 "^assign$"))


; =============================================================================
; Top-level Variables (scoped to program level, excludes arrow functions)
; =============================================================================
;; Exclude arrow functions (handled above as functions)
(program
    (lexical_declaration
        (variable_declarator
            name: (identifier) @variable.global
            value: (_) @_val))
    (#not-match? @_val "=>"))

;; Variable declarations without initializers
(program
    (lexical_declaration
        (variable_declarator
            name: (identifier) @variable.global
            !value)))

;; Exported variables
(program
    (export_statement
        (lexical_declaration
            (variable_declarator
                name: (identifier) @variable.global
                value: (_) @_val2))
        (#not-match? @_val2 "=>")))

"""#
