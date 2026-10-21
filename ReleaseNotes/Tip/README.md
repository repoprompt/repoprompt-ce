# Tip release-note fragments

Add a JSON file in this directory in the PR introducing a user-visible change:

```json
{
  "schemaVersion": 1,
  "title": "Context Builder keeps selections after workspace reload",
  "notes": ["Selections survive reopening the workspace."],
  "breaksDowngrade": false,
  "breaksDowngradeReason": null
}
```

Titles are 1–90 Unicode graphemes; notes contain at most three nonempty strings
of at most 200 graphemes. Text is plain text, NFC-normalized, stripped of control
and bidi-override characters, and whitespace-collapsed. Do not include links,
Markdown or HTML. JSON fragments and this README are the only allowed files.

Set `breaksDowngrade` to `true` and include a nonempty reason (at most 200
graphemes) whenever a change makes data or update preferences unsafe for older
builds to read. This includes incompatible persistence migrations and changes
to passive-update semantics. A known barrier cannot be acknowledged away.
Absence of a barrier does **not** promise backward compatibility.

Fragments are selected only when first added within the first-parent release
range. They are never consumed or deleted by release tooling; editing an old
fragment does not create new release notes. Add a new file instead. Commit
subjects (or merge PR titles) supply fallback notes. Display truncation never
truncates the safety scan.

Validate locally with:

```sh
python3 -B Scripts/tip_history.py lint-fragments --root .
python3 -B Scripts/test_tip_history.py
```

The history contracts are being implemented separately from publication. No
catalog is published until admission, seed provenance, retention and signing
validation are in place; these fragments do not change the existing appcast.
