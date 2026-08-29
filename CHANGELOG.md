# Changelog

All notable changes to MRITestData.jl are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); this project uses
[semantic versioning](https://semver.org/).

## [Unreleased]

### Added

- fastMRI source (`FASTMRI`): knee, brain, prostate and breast multi-coil k-space,
  form-gated signed URLs registered with `set_fastmri_urls!`, `.tar.xz` block-level and
  `.tar.gz` zran range-extraction.
- Documentation: `Concepts & data model`, `Tutorial`, `Glossary`, `FAQ & troubleshooting`
  and `Internals & maintainer notes` pages; undersampled (CG-SENSE) reconstruction
  example and reconstruction-method references; animated illustration of the terminal
  browser.
- `CITATION.bib`.

### Changed

- Documentation restructured: archive-fetching mechanics and maintainer scripts moved
  from `Usage` to `Internals & maintainer notes`; per-source contents consolidated in
  `Dataset contents` (no longer duplicated on the home page).

## [0.1.0]

- Initial development version: `MRIDATA`, `OCMR_SOURCE`, `CMRXRECON2024`, `CMRXRECON300`,
  `USC_SPEECH`, `M4RAW` sources; self-updating catalog; Scratch-backed download cache;
  `load_raw` → `MRIBase.RawAcquisitionData`; `mridata-browser` terminal app.
