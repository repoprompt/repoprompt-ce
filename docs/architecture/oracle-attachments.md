# Oracle and Agent Mode file attachments

Attachments used to be images. They are now any file the classifier recognizes, and the rules that
used to be spread across the loader, each encoder, and each view are concentrated in four owners
under `Sources/RepoPromptDomainRuntime/Attachments/`.

## The four owners

| Owner | Answers | Does not answer |
|---|---|---|
| `AttachmentClassifier` | What kind is this file, from its bytes | Whether anyone can send it |
| `AttachmentRouteCapability` | What one encoder route can deliver, per kind | What any particular request contains |
| `AttachmentPlanner` | What this request becomes on this route, or why it is refused | How bytes reach the wire |
| `AttachmentPresentation` | What a tile shows | Anything about delivery |

`AttachmentKind` is `.image`, `.pdf`, `.text`, `.binary`. Kind comes from a magic-number sniff, never
from the extension, so a `.png` holding CSV is text. A mismatch between extension and content is a
load error rather than a silent reclassification.

## Capability, one row per route

`AttachmentRoute` is keyed by the code that builds the wire payload, not by the provider company:
two providers sharing an encoder share a row. `AttachmentRouteCapability` has one field per kind and
no default values, so adding a kind breaks every row's initializer until each route answers for it.

| Route | Image | PDF | Text | Binary | Max encoded request |
|---|---|---|---|---|---|
| Anthropic Messages | native | native document | inlined | refused | 32 MB |
| OpenAI Responses | native | native document | inlined | refused | none enforced |
| OpenAI Chat Completions | native | refused | inlined | refused | none enforced |
| Custom OpenAI-compatible | native | refused | inlined | refused | none enforced |
| Claude Code | native | refused | inlined | refused | none enforced |
| Codex | native | refused | inlined | refused | none enforced |
| ACP agent | native | refused | inlined | refused | none enforced |
| Grok Build | refused | refused | inlined | refused | none enforced |

Every cell is grounded in encoder code that exists. Widen one only after a live smoke proves
delivery. Binary is refused on every route, including the local ones: the Claude Code, Codex, ACP and
Grok Build Oracle one-shots deliberately run without file tools (no Read/Bash, no shell, an empty
MCP configuration), so naming a path would admit a file the model can never open. Claude stream-json
documents and ACP embedded resources are unproven. Text is inlined on every route because inlining
needs no transport support.

## Planning and refusal

`AttachmentPlanner.plan` is pure: a set plus a route in, `[PlannedAttachment]` or
`AttachmentAdmissionError` out. A request containing one file the route cannot carry is refused
whole, naming each failing file and the reason. Nothing is silently dropped, because a dropped
attachment reads to the user as a model that ignored their file.

## Agent Mode is not an Oracle route

The eight rows describe Oracle one-shot encoders: a tool-less request where bytes ride the wire or the
request is refused. Agent Mode is an interactive agent that can read files from disk. It sends native
images where the transport advertises image input, and every other attachment reaches the agent as an
`@path` reference in the message text. Agent Mode never calls the planner, so its tiles make no
delivery claim and show no capability refusal. A refusal is real only where `AttachmentPlanner.plan`
runs: Oracle sends and the one-shot providers.

Agent Mode intake has its own limits, enforced before anything is read: a file larger than
`OracleAttachmentLimits.maxBytesPerFile` is refused by its directory-entry size, a folder is refused
by name, and both refusals appear in the transcript. Copy, content probe and identity hash run off the
main actor. Two attachments are the same file only when file name, size and content all match.

## Presentation

`AttachmentPresentation.make` maps persisted facts (kind, file name, byte count, preview
availability) to face, title, caption, badge, status, and accessibility label. One `AttachmentTile`
renders it at both geometries, 76x52 in the Agent Mode strip and 48x48 in the Oracle transcript chip.
No view branches on kind, extension, or MIME type. Badges come from `UTType`, so there is no
hand-written extension list. PDF previews are page 1 rendered to the same bounded JPEG as an image
preview; a file that cannot be rendered yields no preview rather than a failure.

## Frozen formats

- The MCP argument is `attachments: [{ path, title? }]` on `ask_oracle` and `oracle_send`, owned by
  `OracleAttachmentContract`, which also derives both schema copies and their prose from the
  capability table and the limits. The v1.6.0 `images` argument remains a deprecated, unadvertised
  alias bounded to its released meaning: every item must be a native PNG, JPEG, GIF or WebP image
  (`OracleAttachmentRequest.imageOnly`), any other file is refused with a pointer to `attachments`,
  and passing both keys is rejected. The direct headless backend rejects both, as v1.6.0 did. Both
  keys stay in the persisted-argument redaction set, because a rejected call is still persisted.
- Oracle chat history persists attachments under the JSON key `imageAttachments`, mapped through
  `CodingKeys`. Agent Mode transcripts use `attachments`. Rows written before kind existed decode as
  images.
- Provider wire strings (Codex `localImage`, Anthropic `image` blocks, ACP image content) are the
  vendors' format and are not ours to rename.

## Deliberately separate

`AgentTaggedFileAttachment` stays a live workspace reference resolved at send time into a
`<file_contents>` block under a token budget. An attachment is a byte snapshot taken once under the
loader's path authority. A file dropped on the composer is an attachment even when it lives in the
workspace, because rerouting it into a tagged reference would silently change what a drop does.

The path authority (`OracleImageWorkspaceAuthority` and the root-spec and session-attachment types
around it) keeps its logic and its names. Renaming types whose logic did not change would churn a
security-critical file for nothing.
