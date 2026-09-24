# PR #1057 debug-app proof

Captured with Cua Driver against the CE debug app built from the PR source on 2026-09-23 and 2026-09-24. The screenshots show real macOS controls. State readbacks and the Devin log establish what ran; the images alone do not prove execution.

| Path | Visible result | Runtime or state readback |
| --- | --- | --- |
| [Oracle picker](oracle-picker.png) and [selected model](oracle-selected.png) | The Devin submenu lists models with effort labels. Choosing Claude Sonnet 4.6 updated the Oracle row. | `app_settings models.planning_model` read `devin_custom_claude-sonnet-4-6` after selection. The original `custom_provider_claude-opus-5-5-batch-max` was restored and read back afterward. |
| [Astra High Oracle run](oracle-astra-high.png) | The Oracle / Plan Model row shows `GPT-6 Astra · High`; the new chat shows the Oracle's `Hi!` reply. Cua Driver's live menu tree also contained `GPT-6 Astra · XHigh`. | The one-shot Devin log recorded `model_input=gpt-6-astra-high` and `resolved_model_uid=gpt-6-astra-high`. The chat reported the Oracle's exact reply as `Hi!`. |
| [Context Builder](context-builder-result.png) | The completed run's tab shows `2 files`. | `context_builder` returned `status: completed`, `file_count: 2`, and selected `AgentRuntimeProviderService.swift` plus `DevinACPAgentProvider.swift`. Debug routing recorded `final_args: --permission-mode auto acp` for the nested Devin process. |
| [Agent model and effort](agent-model-effort.png) | Agent Mode shows `Devin CLI · SWE-2`; its live effort menu offers Medium, High, and Max, with Max selected. | `DevinPermissionLevelTests` and `AgentMCPModelParameterSupportTests` passed; the regression checks preserve the raw model ID while displaying its effort. |
| [Built-in Chat model picker](chat-model-picker.png) | The separate Built-in Chat field opens the Devin submenu with effort-labelled model rows. | The saved Built-in Chat model remained `custom_provider_deepseek-instant`, with Oracle sync off. The screenshot proves the picker renders; it does not claim a chat completion was sent. |

## Why Oracle has no separate effort picker

Agent Mode and the Context Builder agent run through ACP. They can select a model and apply its live `thought_level` parameter separately. Oracle uses a one-shot Devin print run: `devin --model gpt-6-astra-high --prompt-file <file> -p`. Devin CLI 3000.11.3 accepts `--model` with `-p`; there is no separate one-shot `--effort` flag in its help. The Oracle picker therefore lists effort-qualified model IDs such as `gpt-6-astra-high` and `gpt-6-astra-xhigh` as model choices. The selected UID carries the effort to Devin. Fusion and SWE rows are not expanded because their thought choices do not consistently map to CLI model IDs.

The 2026-09-24 change passed 37 focused `DevinPermissionLevelTests`, strict lint, and debug packaging. The Cua-driven Oracle greeting and the matching Devin log are the live proof for Astra High. Hosted CI on the PR head is a separate check.
