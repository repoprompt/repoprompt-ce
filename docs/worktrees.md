# Worktrees

RepoPrompt CE can create Git worktrees for MCP tools and Agent Mode. For app-managed worktrees, you can ask RepoPrompt to copy selected local files that are useful for development but should not be committed.

## Copy-on-write checkouts on APFS

RepoPrompt automatically attempts APFS copy-on-write cloning for app-managed worktrees created by Agent Mode or `manage_worktree create`. When the new worktree starts from exactly the same tree as a clean source checkout on the same APFS volume, RepoPrompt uses `git worktree add --no-checkout` and fills its tracked files with APFS clones. Cloned files share disk blocks with the source until either copy is modified, so the new worktree initially uses almost no additional space for tracked files. You do not need to pass a special creation flag. If checkout speed matters more than disk space, `manage_worktree create` accepts `clone_tracked_checkout=false` to use Git checkout instead. Local benchmarks found that cloning saved nearly all private tracked-file bytes but took longer to create the worktree.

The result is verified before it is accepted: Git builds the new worktree's index from `HEAD`, re-hashes every cloned file during `git update-index --refresh`, and the worktree must report a clean `git status`. The branch, upstream tracking, lock, and `HEAD` are exactly what the ordinary command would produce, because the same `git worktree add` arguments are used.

RepoPrompt uses an ordinary Git checkout instead when any of these apply:

- the base ref resolves to a different tree than the source checkout's `HEAD`
- the source has staged or unstaged changes to tracked files, or assume-unchanged, skip-worktree, or unmerged index entries
- sparse checkout, submodules, `core.symlinks=false`, `core.autocrlf`, or `core.eol=crlf`
- `filter` (including Git LFS), `working-tree-encoding`, `ident`, or `eol=crlf` attributes on any tracked path
- a `post-checkout` hook, whether a hook file or a configured hook, because `--no-checkout` would skip it
- tracked paths that collide on a case- or normalization-insensitive volume
- the destination is outside the app-managed container, `force` is requested, the volumes differ, or the volume cannot clone

If cloning fails after Git has created the worktree, RepoPrompt runs `git reset --hard` inside that new worktree only, producing Git's own checkout, and verifies it is clean. Your source worktree, branches, and other worktrees are never modified. If that fallback cannot be verified, creation fails with an error naming the worktree path so you can inspect it.

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

Each selected file is copied individually as an APFS clone when the volume supports it, and as a regular byte copy otherwise. Directories are never cloned wholesale; every file is still checked against the rules below.

Only files that pass both checks are copied:

1. Git already treats the file as ignored, using the repository's normal ignore rules.
2. The file matches `.worktreeinclude` with a positive final match.

Tracked files are never copied from your dirty working tree. Ordinary untracked files are excluded by default even when they match `.worktreeinclude`. To copy selected non-ignored untracked files for a particular `manage_worktree create`, pass `copy_worktree_include_untracked_files=true`; the same pattern, path, and no-overwrite safeguards apply. Use this only for deliberate, trusted local data. Automatic Agent Mode worktree creation keeps the ignored-only default.

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
- unignored untracked files, unless explicitly opted in for that creation
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
