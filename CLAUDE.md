# Guidance for Claude working on MRITestData.jl

MRITestData.jl provides easy **query and download** access to free, open-access MRI
k-space datasets (mridata.org and OCMR) and loads them into MRI reconstruction
packages. It exists to feed *real* scanner data into reconstruction code that would
otherwise only be tested on synthetic phantoms.

## Architecture (read this first)

- **Catalog** (`src/catalog/`): `DatasetEntry`/`DatasetHandle`, `list_datasets`,
  `dataset`. Entries come from a **self-updating index** (`index_cache.jl`):
  - OCMR — the authoritative CSV at `ocmr.s3.amazonaws.com/ocmr_data_attributes.csv`.
  - mridata.org — scraped from `mridata.org/list` (no JSON API exists).
  - The index is cached in the Scratch space, refreshed after `INDEX_TTL_DAYS`
    (default 30) or via `refresh_index`. On any network failure it falls back to the
    committed files in `data/` (`ocmr_attributes.csv`, `mridata_index.toml`). The
    committed mridata TOML is a **fallback only** — a successful scrape is used
    verbatim, not overlaid.
- **Download/cache** (`src/download/`): `download_dataset` → Scratch cache, with
  `.part`→atomic-rename, SHA-256 sidecars, and a `ProgressMeter` bar (opt out with
  `progress=false`). `_download_with_progress` is the shared primitive.
- **Load** (`src/load/`): `load_acq`/`load_raw` (MRIBase) and `acq_spec` (a
  source-agnostic NamedTuple describing the acquisition layout).
- **Extensions** (`ext/`): `MRITestDataMRIRecoExt` adds `recon(::AcquisitionData;…)`
  over MRIReco — a **weakdep**, so the package never hard-depends on a
  reconstruction package.
- **Browse** (`src/Browse.jl`): standalone Julia App (`mridata-browse`) built on
  Tachikoma.jl's `PagedDataTable` for interactive browse/filter/search/download.

## Commands

- **Instantiate**: `julia --project=. -e 'using Pkg; Pkg.instantiate()'`
- **Run tests** (offline; default): `julia --project=test test/runtests.jl`
- **Run a subset** (by tag or exact name):
  `julia --project=test test/runtests.jl ":quality,:mrireco"`
  `julia --project=test test/runtests.jl "OCMR: refresh index + download + reconstruct"`
- **Run network tests** (live downloads): `MRITESTDATA_NETWORK_TESTS=true julia --project=test test/runtests.jl`
- **Format with Runic** (required before finishing):
  `julia --project=@runic --startup-file=no -e 'using Runic; exit(Runic.main(ARGS))' -- --inplace src/ ext/ test/`

## Tests use the TestItems framework

- `test/runtests.jl` uses `TestItemRunner.@run_package_tests` with a tag filter.
- Each test is an `@testitem "…" tags=[…] begin … end`; shared fixtures live in a
  `@testmodule Fixtures begin … end` referenced via `setup=[Fixtures]`.
- **Subset filter** (ARGS): pass one comma-separated string of tags (`:tag`) and/or
  exact test names; this overrides the default gating, so `:network` is included if
  explicitly named.
- **Tag scheme** (mind these when adding tests):
  - default (no special tag): offline unit tests — catalog, cache, load, Browse, Aqua, JET.
  - `:mrireco` — reconstruction via the MRIReco extension (offline, synthetic fixtures).
  - `:quality` — Aqua + JET static analysis.
  - `:network` — **opt-in** live downloads; only run when `MRITESTDATA_NETWORK_TESTS=true`
    or explicitly named in the ARGS filter.
- Aqua and JET tests must stay **offline** (use `offline=true` on catalog calls).
- Never commit binary `.h5` fixtures — tests synthesize tiny ISMRMRD files on the fly.

## Legal note (important)

This package's MIT license covers **its code only**. Downloaded **data is governed by
each provider's own license/terms** (mridata.org per-dataset terms; OCMR's data-use
terms + required citation of the OCMR paper). When touching docs or the README, keep
the licensing/attribution section accurate — see `docs/src/legal.md`. The package
facilitates access; it grants no rights to the data.

## Conventions

- Julia naming: `lower_snake_case` functions, `CamelCase` types. Type-stable code.
- Comment only when the code isn't self-evident.
- Keep network failure non-fatal where a fallback exists (`@warn`, don't throw).
- mridata.org URLs use `http://` (port 80) — outbound HTTPS (443) is blocked on this HPC.
- OCMR files with cardiac ECG headers: `load_raw`/`load_acq` strip `<waveformInformation>`
  from the cached HDF5 in-place before MRIFiles reads it (workaround for a MRIFiles bug
  where `<waveformName>` is parsed as `Float64` instead of `String`).
- Update docstrings and `docs/` when changing public API; `checkdocs=:public` is on.
