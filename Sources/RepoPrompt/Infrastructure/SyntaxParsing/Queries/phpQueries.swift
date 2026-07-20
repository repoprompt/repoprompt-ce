//
//  phpQueries.swift
//  RepoPrompt
//
//  Created by RepoPrompt on 2025-01-09.
//

import Foundation

/// PHP highlight query based on tree-sitter-php's highlights.scm
let phpHighlightQuery = """
; Keywords
"as" @keyword
"break" @keyword
"case" @keyword
"catch" @keyword
"class" @keyword
"const" @keyword
"continue" @keyword
"declare" @keyword
"default" @keyword
"do" @keyword
"echo" @keyword
"else" @keyword
"elseif" @keyword
"enddeclare" @keyword
"endforeach" @keyword
"endif" @keyword
"endswitch" @keyword
"endwhile" @keyword
"extends" @keyword
"abstract" @keyword
"final" @keyword
"finally" @keyword
"foreach" @keyword
"function" @keyword
"global" @keyword
"if" @keyword
"implements" @keyword
"include" @keyword
"include_once" @keyword
"insteadof" @keyword
"interface" @keyword
"namespace" @keyword
"new" @keyword
"private" @keyword
"protected" @keyword
"public" @keyword
"require" @keyword
"require_once" @keyword
"return" @keyword
"static" @keyword
"switch" @keyword
"throw" @keyword
"trait" @keyword
"try" @keyword
"use" @keyword
"while" @keyword
(abstract_modifier) @keyword
(final_modifier) @keyword
(readonly_modifier) @keyword
(static_modifier) @keyword
(visibility_modifier) @keyword

; Types
(primitive_type) @type.builtin
(cast_type) @type.builtin
(named_type) @type

; Variables
(variable_name) @variable

; Functions
(function_definition
  name: (name) @function)

(method_declaration
  name: (name) @function.method)

; Strings
(string) @string
(encapsed_string) @string
(heredoc) @string
(heredoc_body) @string
(nowdoc_body) @string

; Numbers
(integer) @number
(float) @number

; Constants
(boolean) @constant.builtin
(null) @constant.builtin

; Comments
(comment) @comment
"""

let phpTagQuery = """
(namespace_definition
 name: (namespace_name) @name) @definition.module

(interface_declaration
 name: (name) @name) @definition.interface

(trait_declaration
 name: (name) @name) @definition.interface

(class_declaration
 name: (name) @name) @definition.class

(class_interface_clause [(name) (qualified_name)] @name) @reference.implementation

(property_declaration
 (property_element (variable_name (name) @name))) @definition.field

(function_definition
 name: (name) @name) @definition.function

(method_declaration
 name: (name) @name) @definition.function

(object_creation_expression
 [
	(qualified_name (name) @name)
	(variable_name (name) @name)
 ]) @reference.class

(function_call_expression
 function: [
	(qualified_name (name) @name)
	(variable_name (name)) @name
 ]) @reference.call

(scoped_call_expression
 name: (name) @name) @reference.call

(member_call_expression
 name: (name) @name) @reference.call
"""

let basicPhpQuery = """
; === Minimal, compiler-safe PHP highlight query ===
; NOTE: Each pattern is on its own line (no top-level [ ... ] lists)
; and only node names present in the embedded grammar are referenced.

(string)         @string
(encapsed_string) @string
(heredoc)        @string
(heredoc_body)   @string

(boolean) @constant.builtin
(null)    @constant.builtin
(integer) @number
(float)   @number
(comment) @comment

; sprinkle a few keywords so unit tests detect highlighting
"function" @keyword
"class"    @keyword
"return"   @keyword
"if"       @keyword
"else"     @keyword
"""
