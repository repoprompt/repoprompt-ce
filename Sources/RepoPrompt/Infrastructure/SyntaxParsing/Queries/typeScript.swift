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

// Code-map query for TypeScript / TSX
// Captures used by `CodeMapGenerator`:
//   • @import        – top-level imports
//   • @export        – export statements (NOTE: Currently captures full declaration body)
//   • @type.class    – class names (matches Swift pattern)
//   • @interface     – interface names
//   • @type.enum     – enum names
//   • @function.definition – functions and methods
//   • @variable.global – variables and class properties
//   • @typeAlias     – type-alias declarations
