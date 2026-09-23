# PR #1057 debug-app proof

Captured with Cua Driver against the CE debug app built from the implementation source on 2026-09-23. The screenshots show the actual macOS controls; the MCP readbacks below establish state and execution. The images are not synthetic mockups.

| Path | Visible result | Runtime or state readback |
| --- | --- | --- |
| [Oracle picker](oracle-picker.png) and [selected model](oracle-selected.png) | The Devin submenu lists models with effort labels. Choosing Claude Sonnet 4.6 updated the Oracle row. | `app_settings models.planning_model` read `devin_custom_claude-sonnet-4-6` after selection. The original `custom_provider_claude-opus-5-5-batch-max` was restored and read back afterward. |
| [Context Builder](context-builder-result.png) | The completed run's tab shows `2 files`. | `context_builder` returned `status: completed`, `file_count: 2`, and selected `AgentRuntimeProviderService.swift` plus `DevinACPAgentProvider.swift`. Debug routing recorded `final_args: --permission-mode auto acp` for the nested Devin process. |
| [Agent model and effort](agent-model-effort.png) | Agent Mode shows `Devin CLI · SWE-2`; its live effort menu offers Medium, High, and Max, with Max selected. | `DevinPermissionLevelTests` and `AgentMCPModelParameterSupportTests` passed; the regression checks preserve the raw model ID while displaying its effort. |
| [Built-in Chat model picker](chat-model-picker.png) | The separate Built-in Chat field opens the Devin submenu with effort-labelled model rows. | The saved Built-in Chat model remained `custom_provider_deepseek-instant`, with Oracle sync off. The screenshot proves the picker renders; it does not claim a chat completion was sent. |

Local PR-ready validation passed strict lint, the full root test lane, and the RepoPrompt product build. `make dev-smoke` passed against the running CE debug app. These checks are separate from hosted CI on the PR head.
