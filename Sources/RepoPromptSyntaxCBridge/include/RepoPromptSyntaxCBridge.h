#ifndef RepoPromptSyntaxCBridge_h
#define RepoPromptSyntaxCBridge_h

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
const TSLanguage * tree_sitter_typescript(void);
const TSLanguage * tree_sitter_tsx(void);

#endif /* RepoPromptSyntaxCBridge_h */
