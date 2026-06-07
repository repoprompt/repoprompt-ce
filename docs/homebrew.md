# Homebrew Distribution

RepoPrompt CE is distributed through the dedicated Homebrew tap
[`repoprompt/homebrew-repoprompt-ce`](https://github.com/repoprompt/homebrew-repoprompt-ce).

Users install the public app with:

```bash
brew tap repoprompt/repoprompt-ce
brew install --cask repoprompt-ce
```

This installs `/Applications/RepoPrompt CE.app`.

## Artifact Contract

The cask consumes the promoted, public updater ZIP from
[`repoprompt/repoprompt-ce-updates`](https://github.com/repoprompt/repoprompt-ce-updates).
It must point at an immutable tag-specific URL:

```text
https://github.com/repoprompt/repoprompt-ce-updates/releases/download/<tag>/RepoPrompt-<version>-<build>.zip
```

The cask version encodes both release values:

```ruby
version "<MARKETING_VERSION>,<BUILD_NUMBER>"
```

The cask `sha256` must match the ZIP entry in the updater release's
`SHA256SUMS`. Do not point cask downloads at `latest/download`; the moving
`latest/download/appcast.xml` URL is only for livecheck and Sparkle feed
discovery.

## Boundaries

- The Homebrew tap is cask-only for v1.
- The tap does not build, sign, notarize, staple, or Sparkle-sign artifacts.
- The tap does not need Developer ID, notarization, or Sparkle private-key
  secrets.
- Source release workflows in this repository remain unchanged for v1 tap
  distribution.
- `repoprompt-mcp` is app-coupled and remains embedded in `RepoPrompt CE.app`;
  do not add a standalone Homebrew formula for it in v1.
- The closed-source Homebrew cask is `repo-prompt`. RepoPrompt CE uses the
  distinct `repoprompt-ce` cask token and bundle identifier
  `com.pvncher.repoprompt.ce`.

## Maintainer Checks

After promoting a release, verify the tap before announcing Homebrew
availability for that version:

1. Confirm the promoted updater release contains exactly the expected ZIP,
   `appcast.xml`, and `SHA256SUMS`.
2. Confirm `Casks/repoprompt-ce.rb` points at the promoted tag-specific updater
   ZIP.
3. Confirm the cask version is `<MARKETING_VERSION>,<BUILD_NUMBER>`.
4. Confirm the cask `sha256` matches the promoted ZIP entry in updater
   `SHA256SUMS`.
5. Run a clean install smoke:

   ```bash
   brew tap repoprompt/repoprompt-ce
   brew install --cask repoprompt-ce
   ```

6. Confirm the installed bundle is `/Applications/RepoPrompt CE.app`.

If the tap lags a promoted release, update only the tap repository. Do not
rerun or modify the source repository's protected release workflows to repair a
tap-only drift.
