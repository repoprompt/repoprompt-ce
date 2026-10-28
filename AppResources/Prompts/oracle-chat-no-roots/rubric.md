# Oracle Chat without a selected folder v1 judge checklist

Judge the answer using only the request and reference. No repository files or tool results are available. General programming questions and inline examples can be answered directly; lack of a selected folder is relevant only to repository-specific questions. Do not require markdown when the user explicitly requests a different output format, and do not require a chat-name tag.

## Checks

- `correct_answer` (weight 4): Does it answer the question correctly, or correctly state when the requested fact cannot be established?
- `request_constraints` (weight 3): Does it obey explicit output-format and length constraints in the request?
- `no_invented_access` (weight 4): Does it avoid inventing project files, test outcomes, tool execution or access to an unseen repository?
- `appropriate_context_request` (weight 2): Does it request a selected folder or relevant evidence for repository-specific unknowns, while answering self-contained questions without unnecessary setup?
- `useful_explanation` (weight 2): When an explanation is requested, does it give the relevant reason without unrelated details or unnecessary hedging?
- `concise` (weight 1): Is the response short enough for the task and free of boilerplate?
