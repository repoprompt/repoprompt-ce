# Worktrees

RepoPrompt CE can create Git worktrees for MCP tools and Agent Mode. For app-managed worktrees, you can ask RepoPrompt to copy selected local files that are useful for development but should not be committed.

The common example is a local environment file:

```text
main checkout has .env.local
RepoPrompt creates .repoprompt-worktrees/my-repo-agent
RepoPrompt copies .env.local into the new worktree
agent starts with the same local setup
```

## Copying local ignored files with `.worktreeinclude`

Create a file named `.worktreeinclude` at the repository root of your main checkout.

RepoPrompt reads that file when it creates a new app-managed worktree. The file uses `.gitignore` syntax: one pattern per line, `#` comments, directory patterns, globs, and `!` negation patterns work the same way they do in `.gitignore`.

Only files that pass both checks are copied:

1. Git already treats the file as ignored, using the repository's normal ignore rules.
2. The file matches `.worktreeinclude` with a positive final match.

That means tracked files are not copied from your dirty working tree, and ordinary untracked files are not copied just because they match `.worktreeinclude`. The file must already be Git-ignored.

## Example

```gitignore
# .gitignore
.env.local
config/secrets.json
certs/local/
```

```gitignore
# .worktreeinclude
.env.local
config/secrets.json
certs/local/
certs/local/**

# Keep this one out even though the directory is included.
!certs/local/production.pem
```

With those files in the repo root, RepoPrompt copies ignored local files such as:

- `.env.local`
- `config/secrets.json`
- files under `certs/local/`

RepoPrompt does not copy:

- tracked files, even if their names match `.worktreeinclude`
- unignored untracked files
- files excluded by a later `!` pattern
- symlinks, directories, non-regular files, unsafe paths, or files that would overwrite an existing destination file

## Where it applies

`.worktreeinclude` copying only applies to RepoPrompt-managed worktrees, such as worktrees created under the app's `.repoprompt-worktrees` container by Agent Mode or `manage_worktree create`.

If you create a worktree at an explicit external path with `allow_external_path=true`, RepoPrompt creates the worktree but does not copy `.worktreeinclude` files into it.

## Output and diagnostics

Successful copying is silent. If everything requested is copied, RepoPrompt does not add extra output.

If something goes wrong after the worktree was created, RepoPrompt keeps the worktree and reports the copy issue where it can:

- `manage_worktree create` may include a warning in its output.
- Agent Mode and descriptor-only flows record production-safe diagnostics for debugging.

For example, if the destination file already exists, the worktree still exists and the warning explains that the file was skipped rather than overwritten.

## Be careful with broad patterns

RepoPrompt does not add a hidden file-count or size limit to `.worktreeinclude` copying. If you write a broad pattern such as `**` or `local-cache/**`, RepoPrompt may copy a lot of local data into every new app-managed worktree.

Use narrow patterns for the files agents actually need. A good `.worktreeinclude` is usually a short list of local setup files, not a second copy of your whole ignored cache directory.

## Permanently retiring an app-managed worktree

Worktree retirement is a separate, irreversible operator flow. It is advertised in
`manage_worktree`, but remains default-off. A DEBUG app can activate the flow only when
its launch environment contains this exact policy receipt:

```text
REPOPROMPT_DEBUG_WORKTREE_RETIREMENT_POLICY_RECEIPT=repoprompt-ce.authoritative-worktree-retirement.debug.v1
```

The DEBUG composition root validates and installs that receipt exactly once, before MCP
server startup. Missing, empty, or different values fail closed. Release builds compile
out the environment key, validator, and installation API, so they have no activation path.

Ordinary MCP clients cannot activate retirement. Dispatch also requires the dedicated
`manage_worktree.retire` action grant. RepoPrompt installs that grant only in Agent Mode
connection policy; plain CLI callers do not receive it. The grant does not bypass the
DEBUG receipt, release separation, or the two-stage authorization.

The first call does not delete anything. It closes generation-aware RepoPrompt admission,
drains app-owned sessions, bindings, workspace roots, watchers, mutation leases, and Git
processes, then seals the target and returns a short-lived, single-use
`authorization_token`.

Apply the sealed authorization with a second `manage_worktree` call:
`{"op":"retire","authorization_token":"<authorization-token>"}`. RepoPrompt re-attests
physical directory identities and the exact content manifest under its serialized executor
before deleting the worktree. Caller booleans never replace the sealed token.

### Evidence and failure behavior

- Successful apply records permanent evidence, including the single-use authorization
  digest, generation, manifest digest, Git removal result, and postconditions.
- Repeating the token call after completion returns the same evidence instead of deleting
  again.
- A failed or expired sealed operation becomes `blocked_residue`. That worktree identity
  cannot be silently retried or reused; inspect the returned evidence and resolve it
  explicitly.
- The machine-readable authority scope is exactly `repoprompt_control_plane`.
- That scope covers RepoPrompt-controlled sessions, bindings, writers, watchers, and Git
  operations. It does **not** cover arbitrary external processes, external open handles, or
  same-user filesystem writes outside RepoPrompt's control. Stop or inspect such external
  actors before approving apply.
