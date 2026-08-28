# Guidance for agents working on MRITestData.jl

MRITestData.jl provides easy **query and download** access to free, open-access MRI
k-space datasets (mridata.org and OCMR) and loads them into MRI reconstruction
packages. It exists to feed *real* scanner data into reconstruction code that would
otherwise only be tested on synthetic phantoms.

## Commit Rules

- **Commit Message Formatting**: Follow the "Conventional Commits" format with the structure `type(scope): subject` and a detailed description (including performance numbers or context) separated by a blank line. For simple commits affecting only a couple lines, a detailed description is optional. Always append co-author line referencing yourself.
- **Committing Changes**: ONLY commit code upon explicit instruction from the user.

## Skills (`.agents/skills/`)

Vendor-neutral skills. **Load the matching skill** from `.agents/skills/` that matches the task and open only the
reference file it points you to.

| Skill | Use when |
|---|---|
| `julia-perf` | Diagnosing slow code, reducing allocations, fixing type instabilities. |
| `julia-bench` | Writing/running benchmarks, comparing revisions, benchmark CI. |
| `julia-jet` | Running JET inference/type analysis on the package. |
| `julia-package-dev` | Environments, dependencies, extensions, multi-package workspace. |
| `julia-docs` | Documenter.jl site, docstrings, doctests, citations. |

These cover the generic patterns (type stability, `@inbounds`, column-major
loops, `$`-interpolation in benchmarks, test-only deps in `test/Project.toml`,
the `[workspace] projects = ["test"]` layout, never editing `Manifest.toml`,
`JULIA_PKG_SERVER_REGISTRY_PREFERENCE=eager`, etc.). Don't duplicate them here.

## Architecture (read this first)

- **Catalog** (`src/catalog/`): `DatasetEntry`/`DatasetHandle`, `list_datasets`,
  `dataset`. Entries come from a **self-updating index** (`index_cache.jl`):
  - OCMR — the authoritative CSV at `ocmr.s3.amazonaws.com/ocmr_data_attributes.csv`.
  - mridata.org — scraped from `mridata.org/list` (no JSON API exists).
  - The index is cached in the Scratch space, refreshed after `INDEX_TTL_DAYS`
    (default 30) or via `refresh_index`. On any network failure it falls back to the
    committed files in `data/` (`ocmr_attributes.csv`, `mridata_index.toml`). The
    committed mridata TOML is a **curated overlay**: a successful scrape supplies the
    bulk metadata, then the committed TOML is merged on top per-field (curated values
    win, e.g. hand-filled `approx_size_bytes`). It is used **verbatim only** when the
    live scrape fails entirely (`_catalog_entries(::MridataOrg)`).
- **Download/cache** (`src/download/`): `download_dataset` → Scratch cache, with
  `.part`→atomic-rename, SHA-256 sidecars, and a `ProgressMeter` bar (opt out with
  `progress=false`). `_download_with_progress` is the shared primitive. CMRxRecon2024
  range-extracts `.mat` files from a split **ZIP** via a per-file offset map
  (`cmrxrecon2024_fetch.jl`). CMRxRecon-300 ships split **`.tar.gz`** (one gzip stream,
  not per-file seekable), so `cmrxrecon300_fetch.jl` uses a **zran** checkpoint index
  (`src/util/zran.jl`: libz `ccall` wrappers + 32 KiB dictionary + `inflatePrime` bit
  offset) to resume decompression mid-stream and pull one member with HTTP range
  requests. Both index artifacts are built offline by maintainer scripts (`scripts/`)
  and committed to `data/`; CMRxRecon-300's maps are read directly (it has no upstream to
  refresh — see the static-index trait below).
- **Static vs live indexes** (`index_cache.jl`): `_is_static_index(source)` marks the
  sources whose catalog ships with the package (CMRxRecon2024, CMRxRecon-300, USC Speech,
  M4Raw, fastMRI). For those `ensure_index` returns `_bundled_index_path(source)` directly
  — nothing is fetched, cached, or aged out, and `refresh_index` is a no-op that still
  reports the path. Only OCMR and mridata.org define `_index_source_url`/`_fetch_index`.
  A new map-backed source therefore needs only `_bundled_index_path`, `_is_static_index`,
  its row→entry parser, and a `_catalog_entries` that calls `_cached_index_entries` (which
  memoises parsed entries per `(path, mtime, size)`). Sources that cannot serve an id
  absent from their map leave `_can_synthesize` at its `false` default; `dataset` then
  raises one shared error instead of a per-source one.
- **Load** (`src/load/`): `load_raw` returns an `MRIBase.RawAcquisitionData` for any
  source (ISMRMRD path or entry/handle). `load_mat` exposes the raw CMRxRecon `.mat`
  arrays. Both CMRxRecon sources are converted to cached Cartesian ISMRMRD by
  `cmrxrecon_ismrmrd.jl` (`_cmrxrecon_to_ismrmrd`); CMRxRecon-300 is fully sampled, so it
  reuses that converter with an all-true mask (k-space var `Recon_ks`). The package deliberately does **not** build `AcquisitionData` or expose an
  `acq_spec`/reconstruction API — reconstruction is left to the caller (build an
  `AcquisitionData` from the raw data and hand it to MRIReco.jl; see `docs/src/usage.md`).
- **Browse** (`src/browse.jl`): standalone Julia App (`mridata-browser`) built on
  Tachikoma.jl's `PagedDataTable` for interactive browse/filter/search/download. The
  app's `julia_flags` (Project.toml `[apps.mridata-browser]`) minimise launch compile
  time. CMRxRecon downloads prompt for a Synapse token if none is set.

## Commands

- **Instantiate**: `julia --project=. -e 'using Pkg; Pkg.instantiate()'`
- **Run tests** (offline; default): `julia --project=test test/runtests.jl`
- **Run a subset** (by tag or exact name):
  `julia --project=test test/runtests.jl ":quality"`
  `julia --project=test test/runtests.jl "OCMR: refresh index + download + load"`
- **Run network tests** (live downloads): `MRITESTDATA_NETWORK_TESTS=true julia --project=test test/runtests.jl`
- **Format with Runic** (required before finishing):
  `runic --inplace .`

## Tests use the TestItems framework

- `test/runtests.jl` uses `TestItemRunner.@run_package_tests` with a tag filter.
- Each test is an `@testitem "…" tags=[…] begin … end`; shared fixtures live in a
  `@testmodule Fixtures begin … end` referenced via `setup=[Fixtures]`.
- **Subset filter** (ARGS): pass one comma-separated string of tags (`:tag`) and/or
  exact test names; this overrides the default gating, so `:network` is included if
  explicitly named.
- **Tag scheme** (mind these when adding tests):
  - default (no special tag): offline unit tests — catalog, cache, load, Browse, Aqua, JET.
  - `:quality` — Aqua + JET static analysis.
  - `:network` — **opt-in** live downloads (mridata.org / OCMR / Synapse); only run when
    `MRITESTDATA_NETWORK_TESTS=true` or explicitly named in the ARGS filter. CMRxRecon
    network tests need a Synapse token (`set_synapse_token!` or `SYNAPSE_AUTH_TOKEN`).
- Aqua and JET tests must stay **offline** (use `offline=true` on catalog calls).
- Never commit binary `.h5` fixtures — tests synthesize tiny ISMRMRD files on the fly.

### Opt-in network tests (live downloads)

```sh
MRITESTDATA_NETWORK_TESTS=true \
  /scratch/c_mrrecon/julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia \
  --project=test test/runtests.jl
```

Or use the ARGS filter to run only the network tests:

```sh
/scratch/c_mrrecon/julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia \
  --project=test test/runtests.jl ":network"
```

CMRxRecon network tests additionally need a Synapse token — set it once with
`MRITestData.set_synapse_token!(token)` or export `SYNAPSE_AUTH_TOKEN`.

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
- mridata.org URLs use `http://` (port 80).
- OCMR files with cardiac ECG headers: `load_raw` strips `<waveformInformation>`
  from the cached HDF5 in-place before MRIFiles reads it (workaround for a MRIFiles bug
  where `<waveformName>` is parsed as `Float64` instead of `String`).
- Update docstrings and `docs/` when changing public API; `checkdocs=:public` is on.
