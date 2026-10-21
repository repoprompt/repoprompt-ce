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
| Claude Code | native | refused | inlined | path mention | none enforced |
| Codex | native | refused | inlined | path mention | none enforced |
| ACP agent | native | refused | inlined | path mention | none enforced |
| Grok Build | refused | refused | inlined | path mention | none enforced |

Every image, PDF and text cell is grounded in encoder code that exists. Widen one only after a live
smoke proves delivery: Claude stream-json documents and ACP embedded resources are unproven. Text is
inlined on every route because inlining needs no transport support.

The Binary column is the one cell that is not about an encoder. The four routes that run on this
machine (Claude Code, Codex, ACP, Grok Build) can open a file themselves, so a binary such as a zip is
delivered as `.pathMention`: one inline text line naming the file, its size, and its absolute path,
which rides the existing `.inlineText` delivery and needs no encoder support. The four network routes
have no wire shape for arbitrary bytes and a local path means nothing to them, so a binary stays
refused there, by name. The mention is deliberately not a fenced block, and the planner never reads
the file's bytes for it. No zip is parsed, and `AttachmentClassifier` still sniffs a zip as `.binary`.

## The path rule

`OracleAttachment` used to be path-free. The rule is now narrower, not absent: it may carry an optional
absolute `localPath`, set by the loader from the physical path it actually opened (the file the MCP
`path` argument or the Agent Mode managed copy resolved to). The path exists so a local route can tell
its agent where the file is. Bytes and paths are never persisted (the type is not `Codable`), the path
is never displayed, and the path never reaches a network route: those routes refuse a binary before any
text is built, and no other kind renders the path. A relative path is never accepted, and a path with
a control character is dropped so it cannot break out of its one line. A binary with no usable path on
a path-mention route is refused with its own reason (`binaryHasNoLocalPath`) rather than dropped.

## Planning and refusal

`AttachmentPlanner.plan` is pure: a set plus a route in, `[PlannedAttachment]` or
`AttachmentAdmissionError` out. A single decision switch maps kind and capability to a delivery or a
refusal reason. A request containing one file the route cannot carry is refused
whole, naming each failing file and the reason. Nothing is silently dropped, because a dropped
attachment reads to the user as a model that ignored their file.

## Agent Mode is not an Oracle route

The eight rows describe Oracle one-shot encoders: a request where bytes ride the wire, a mention names
a local path, or the request is refused. Agent Mode is an interactive agent that can read files from disk. It sends native
images where the transport advertises image input, and every other attachment reaches the agent as an
`@path` reference (or a listed path) in the message text, so a zip reaches Claude Code, Codex, ACP and
Grok Build sessions as a line containing its absolute path. Agent Mode never calls the planner, so its tiles make no
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
No view branches on kind, extension, or MIME type. Badges and the type named in a tile's caption come from `UTType`, so a dropped `report.zip` reads as a
ZIP archive and there is no hand-written extension list. The pre-send route warning is derived from the
same capability row as the planner, so it appears for a binary on the network routes and not on the
local ones. PDF previews are page 1 rendered to the same bounded JPEG as an image
preview; a file that cannot be rendered yields no preview rather than a failure.

## Frozen formats

- The MCP argument is `attachments: [{ path, title? }]` on `ask_oracle` and `oracle_send`, owned by
  `OracleAttachmentContract`, which also derives both schema copies and their prose from the
  capability table and the limits. The retired `images` argument is rejected by name, with no alias.
  Both keys stay in the persisted-argument redaction set, because a rejected call is still persisted.
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
