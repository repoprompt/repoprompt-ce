# Agent orchestration: choose the authority and reconcile the receipt

This is an operator/model-guidance runbook, not a new transport policy. The shipped oversight inventory teaches the short direction rule; `rp-orchestrate` teaches the recovery procedure. Neither grants permission, changes a runtime gate, promises successful recovery, or replaces the user's explicit scope.

## Confirmed source boundaries

| Boundary | Owner / evidence | Consequence |
| --- | --- | --- |
| Message provenance | [AgentSessionLinkSendTransaction.swift](../../Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkSendTransaction.swift), `AgentSessionLinkMessageEnvelope` | `send` is always `bounded_coordination`. Managed `steer` uses `user_delegated_management`; words in the body cannot select that framing. |
| Managed delivery | [AgentSessionLinkRuntimeBridge.swift](../../Sources/RepoPrompt/Features/AgentMode/Runtime/SessionLinks/AgentSessionLinkRuntimeBridge.swift), `DeliveryKind`, `deliver`, `steer` | The commit fence re-proves management for `steer`, including idle delivery. A grant, not idle state or sender prose, authorizes it. |
| Lane first message | Same bridge, `createLane` | The optional message authorizes `.monitorSend` and uses `send`/`queueSend`; it does **not** have managed-steer provenance. |
| Worktree binding | [MCPWorktreeToolProvider.swift](../../Sources/RepoPrompt/Infrastructure/MCP/WindowTools/MCPWorktreeToolProvider.swift), session-binding contract; [AgentSessionTargetOperationGuard.swift](../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentSessionTargetOperationGuard.swift), `requireWorktreeBindingAuthority` | A live exact Manage grant admits an overseer's target binding; destination change still requires an idle provider with no queued work or pending interaction. Worktree creation can succeed while binding fails. |
| Child creation | [AgentRunMCPToolService.swift](../../Sources/RepoPrompt/Infrastructure/MCP/Agent/AgentRunMCPToolService.swift), `executeStart` preparation/discard scope | Explicit/inherited binding is prepared before provider dispatch; preparation failure attempts allocated-target discard. Do not infer complete cleanup or worktree removal from the thrown error. |
| Exact prompt responses | [agent-session-oversight-auto-wake.md](agent-session-oversight-auto-wake.md#inspecting-and-answering-prompts) | Managed `poll`/`wait` inspect the current interaction; `respond` applies only to that exact ID. Manual-only prompts cannot be answered by routing around the fence. |

Choosing `send` for a new managed assignment delivers a weaker, coordination-only envelope. Repeatedly retrying it cannot upgrade its provenance.

## Managed top-level lane versus spawned child

- Spawned `agent_run` children are the default path when oversight is unavailable. Oversight requires an Agent caller with the advertised tool, a current exact direct link and the relevant capability. A managed instruction is session-local: it does not authorize the recipient to manage its own targets. No grant is reciprocal or transitive.
- For a managed assignment, use `steer` even while idle. `send` is for coordination within existing work. A restricted link cannot be upgraded by choosing a different operation.
- For a fresh top-level lane, use `create_lane` **without** a message when a managed initial assignment is intended. Inspect its returned session, grant, and execution location, bind while idle if needed, then `steer`. `created_by_you` is provenance, not permission; no created lane inherits the creator's authority.
- `agent_run` controls the caller's own spawned children; it is not a general control path for linked top-level targets. The child alternative is `agent_run op=start` with `worktree`/`worktree_id`, or `worktree_create=true` and explicit `worktree_repo_root`, `worktree_base_ref`, and `worktree_branch`. Start-only worktree arguments do not belong on later `steer` calls. Do not bypass a denied oversight mutation by spawning a child.

## Stop, bind, verify, resume

An active target cannot self-rebind. Only when the user's scope authorizes stopping that exact managed target:

1. Inspect current state and any pending interaction. Do not use Stop to dismiss or bypass a user decision or explicit approval gate.
2. Use managed `stop` with a fresh key. Confirm settlement and binding readiness: idle provider, no queued work, no pending interaction. A stop receipt is not permission to assume every idle gate is satisfied.
3. Create/bind through `manage_worktree` using the exact `session_id` and explicit repository/worktree selectors. Preserve a dirty primary. Do not fall back to implicit `@wt`, first-root routing, or the primary after authority/binding failure.
4. Read back the durable binding and re-attest physical path/worktree ID, branch, HEAD, full porcelain, and RepoPrompt source routing. A created directory is not proof of a binding.
5. Deliver the authorized resume with managed `steer`. Stop never means Unlink, session deletion, or app lifecycle control.

This is a supported sequence, not a guarantee that any busy/loading/denied target can be forced into it. If idle settlement or authority cannot be established, report the exact unresolved state.

## Interrupted creation and bounded retries

A failed, interrupted, or indeterminate reply is not proof of no mutation. Inspect the returned operation/session/worktree identities and current durable state before retrying. A worktree can remain after creation or child-start preparation failure.

For child-start preparation failure, reconcile three separate facts: provider not started, allocated-child cleanup/no orphan, and retained worktree/binding state. Reuse a surviving intended worktree rather than creating duplicates. If any state is unknown, keep it unknown and reconcile before restarting. Retry only a reconciled, retryable state after a relevant change, with a bounded attempt. Repeated identical failure without state change is a blocker to report, not a retry loop.

Binding failure need not block separately permitted explicit-path immutable source/GitHub reads: pin the checkout/HEAD and scope and label source mapping. This is never a bypass of denied mutation or permission to use task-aware tools under untrusted routing.

## Decisions and validation receipts

Read the actual current `pending_interaction`, not a stale preview. Respond only with the exact current `interaction_id` and a respondable option under the user's instruction. Refresh if it changes; never replay approval. Handle authorized routine scoped prompts promptly. Manual-only, ambiguous, scope-expanding, destructive, or genuine user decisions go to the user/root coordinator through an authorized reporting path—not an assumed reverse link.

Status previews, queued jobs, interrupted jobs, and no-match test runs are not passes. Inspect current child/ticket receipts and logs; report the exit code, test match/count, and exact HEAD. For validation-only preflights capture HEAD before and after and require it unchanged. Piping a preflight to `tail` can hide the producer's failure; capture its exit code or use `pipefail`, not the final pipeline command's success.

Explicit conflict/approval gates remain binding even when source review or a rerun looks good. If told not to approve on conflict, post no approval while conflict remains; report it and seek authorized resolution. Use only operations actually advertised for this caller. Do not invent pin tools or use a tool's visibility as authority.

## Validation and limits

Regression checks cover emitted oversight guidance and its re-owed inventory revision, all three orchestrate variants, unchanged restricted capability rows, catalog migration convergence/budget, and the existing distinct escaped send/steer envelopes. They prove emitted wording and preserved source fences—not model compliance or live recovery success.
