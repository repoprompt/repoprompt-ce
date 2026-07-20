//
//  RubyQueries.swift
//  RepoPrompt
//
//  Created by RepoPrompt on 2026-01-30.
//

import Foundation

let rubyHighlightQuery = """
; Minimal, compiler-safe Ruby highlight query

(string) @string
(comment) @comment
(integer) @number
(float) @number

(simple_symbol) @string.special.symbol
(delimited_symbol) @string.special.symbol
(hash_key_symbol) @string.special.symbol
(bare_symbol) @string.special.symbol

(constant) @constant
(identifier) @variable

"def" @keyword
"class" @keyword
"module" @keyword
"end" @keyword
"""
