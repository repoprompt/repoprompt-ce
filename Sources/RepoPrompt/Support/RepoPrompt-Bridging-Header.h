//  RepoPrompt-Bridging-Header.h
//
//  Item 4 transitional residual: syntax declarations only. Item 5 moves these
//  declarations into RepoPromptSyntaxCBridge and removes the target-wide header.

#ifndef RepoPrompt_Bridging_Header_h
#define RepoPrompt_Bridging_Header_h

// Forward declare TSLanguage so the compiler knows it's a struct.
typedef struct TSLanguage TSLanguage;

const TSLanguage * tree_sitter_javascript(void);
const TSLanguage * tree_sitter_python(void);
const TSLanguage * tree_sitter_c_sharp(void);
const TSLanguage * tree_sitter_swift(void);
const TSLanguage * tree_sitter_c(void);
const TSLanguage * tree_sitter_cpp(void);
const TSLanguage * tree_sitter_rust(void);
const TSLanguage * tree_sitter_go(void);
const TSLanguage * tree_sitter_java(void);
const TSLanguage * tree_sitter_dart(void);
const TSLanguage * tree_sitter_php(void);
const TSLanguage * tree_sitter_ruby(void);

#endif /* RepoPrompt_Bridging_Header_h */
