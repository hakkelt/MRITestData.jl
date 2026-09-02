# Changelog

All notable changes to MRITestData.jl are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[semantic versioning](https://semver.org/).

## [Unreleased]

### Added

- fastMRI source (`FASTMRI`): knee, brain, prostate and breast multi-coil k-space,
  form-gated signed URLs registered with `set_fastmri_urls!`, `.tar.xz` block-level and
  `.tar.gz` zran range-extraction.
- Configurable download location: `set_download_path!(dir)` / `set_download_path!(:cache)`,
  `get_download_path`, `unset_download_path!`. The choice is persisted in
  `LocalPreferences.toml`. **Breaking:** downloads (`download_dataset`, `copy_dataset`,
  entry-based `load_raw`) now throw until a path is configured; `set_download_path!(:cache)`
  restores the previous Scratch-cache behaviour.
- `download_dataset(x; path = dir)` downloads into `dir` for a one-off destination,
  bypassing the configured-path requirement.
- The terminal browser persists its column selection (`c`) across launches in
  `LocalPreferences.toml`.
- Documentation: `Concepts & data model`, `Tutorial`, `Glossary`, `FAQ & troubleshooting`
  and `Internals & maintainer notes` pages; undersampled (CG-SENSE) reconstruction
  example and reconstruction-method references; a screen recording (GIF) of the
  terminal browser (also demonstrating paging, the details pane and the query language).
- `CITATION.bib`.

### Changed

- Documentation restructured: archive-fetching mechanics and maintainer scripts moved
  from `Usage` to `Internals & maintainer notes`; per-source contents consolidated in
  `Dataset contents` (no longer duplicated on the home page).
- mridata.org catalog is fully scraped from `mridata.org/list`; the committed
  `data/mridata_index.toml` is only an offline fallback, no longer described as a
  "curated seed"/"overlay", and the manual "Adding datasets" workflow is dropped from the
  docs.
- `RawAcquisitionData` documentation links now point at the MRIReco.jl raw-data page;
  `MRIBase` is no longer referenced in the README/docs. The OCMR ECG-header workaround
  is no longer called out in user-facing docs (the code still applies it).

## [0.1.0]

- Initial development version: `MRIDATA`, `OCMR_SOURCE`, `CMRXRECON2024`, `CMRXRECON300`,
  `USC_SPEECH`, `M4RAW` sources; self-updating catalog; Scratch-backed download cache;
  `load_raw` → `RawAcquisitionData`; `mridata-browser` terminal app.
