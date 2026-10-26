# Codex user MCP snapshot import

Agent Mode uses CE-owned `CODEX_HOME` and `CODEX_SQLITE_HOME`. It does **not** load
ordinary Codex configuration automatically. Settings → CLI Providers → Codex
shows a names-only hint when user servers are available and offers **Import user
Codex MCP servers…** after connection. The source is `$CODEX_HOME/config.toml`
when set, otherwise `~/.codex/config.toml`. Source symlinks are supported for
managed dotfiles; the resolved source must still be a UTF-8 regular file.

Import is an explicit, confirmed, additive snapshot. It copies only new
`[mcp_servers.name]` definitions, including credentials stored inside those tables.
Auth files, hooks, model/provider settings, and other sections are not imported.
Source files are never modified. Existing managed definitions and permission
choices are preserved; reserved CE, CE Grok runtime, and computer-use identities
(including the `computer_use` alias) are never imported. Case-insensitive and TOML
Unicode-escaped aliases share identity for collision checks.

New definitions have `enabled = false`, and stale CE permission toggles for those
names are reset to disabled **before** publishing the file. If permission storage
fails, no definitions are published. If the subsequent file replacement fails,
the conservative disabled toggles may remain. Review MCP permissions and start a
new session to use a server. Import does **not** reload running controllers,
update or remove earlier imports, or synchronize subsequent source edits. Edit
CE's managed config explicitly to update an imported definition. This is partial
mitigation of #830, not `config/mcpServer/reload` or ongoing configuration sync.

## Validation and file safety

Files are bounded to 2 MiB. The managed destination and its parent must not be
symlinks; its directory must be owned by the current user and not group/world
writable. A fresh exclusive, no-follow `0600` file is synchronized and atomically
renamed only after the destination is re-read unchanged. No source values or raw
lines are included in status/errors. Names and key paths are quoted/escaped;
status lists are bounded to 20 entries.

Validation is per server: invalid or unsupported definitions are skipped while
valid servers are imported. Diagnostics identify server/key names or the line of
an unparseable section, never values. Unrelated malformed sections do not abort
valid MCP definitions. Ambiguous multiline content is not treated as a new table;
header-looking lines inside MCP multiline values invalidate that server because
the existing managed-config repairer is line-oriented. Unclosed multiline values
may hide subsequent tables, which are conservatively not imported.

The bounded TOML reader supports nested maps, inline values, tool approval tables,
OAuth tables, and string/object or array-table `env_vars`. It rejects duplicate or
conflicting keys/tables, invalid names/control characters, ambiguous inline/dotted
root server definitions, unsupported value forms, and excessive nesting. Servers
must specify exactly one command or URL and satisfy the pinned transport rules.

`Scripts/Fixtures/codex-mcp-import-schema.json` is the transitive
`RawMcpServerConfig` projection from the official **bundled** Codex config schema
(source URL and version are recorded in the fixture); only descriptions/defaults
are omitted. `Scripts/generate_codex_mcp_import_schema.py` generates the app's
Swift projection. `make dev-codex-schema-check` checks the generated projection
and bundled-version match in addition to the app-server contract. Update the
fixture from the new official schema and regenerate when changing the Codex pin.
The import does not run Codex to parse configuration or discover servers.

## Provider catalog coordination

PR #985 introduces a narrower `MCPServerCatalog(migratingCodexTOML:)` shape. It
must use the same pinned schema before migration consumes imported definitions:
`cwd`, `env_vars`, `http_headers`, `bearer_token_env_var`, startup timeouts,
`disabled_tools`, and nested env currently exceed that parser's accepted shape.
PR #837 also touches isolated Codex configuration. Reconcile shared config/UI
edits and retain the no-whole-config-copy boundary when integrating either PR.
