# Bundled Prompt Experiment Python notices

Prompt Experiment packages CPython 3.11.16 from the `python-build-standalone` 20260901 full distributions. Exact target archives, sizes, and SHA-256 digests are pinned in `Vendor/PromptExperimentPython/manifest.json`.

The packaging tool copies the distribution's authoritative `PYTHON.json` and complete `python/licenses/` tree into every architecture target at `Contents/Resources/BundledRuntimes/PromptExperimentPython/<arch>/`. The copied inventory includes the CPython license and the notices selected by `PYTHON.json`'s top-level `license_path` and per-extension `license_paths` metadata. Keeping that generated upstream inventory beside the executable runtime avoids maintaining a divergent handwritten subset here.
