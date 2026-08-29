# Internals & maintainer notes

Nothing on this page is needed to *use* the package — [`load_raw`](@ref) hides all of
it. It documents how archive-backed sources are fetched without downloading the whole
archive, and the maintainer scripts that build the committed index artifacts.

## Internals: random-access extraction

Only `MRIDATA` and `OCMR_SOURCE` are whole-file downloads. Every other source is a small
file inside a very large upstream archive, and the package pulls **only that file's
bytes** with HTTP range requests. Three strategies, by archive format:

### ZIP central directory (USC Speech, M4Raw)

A ZIP stores a central directory listing every member's byte offset, compressed size and
compression method. The package reads that directory once (committed as
`data/usc_speech_map.csv` / `data/m4raw_map.csv`), then issues a single HTTP `Range`
request for the target member, strips its local file header, and inflates it if the
member is DEFLATE-compressed.

- USC Speech: figshare's `ndownloader` 302-redirects to a short-lived presigned S3 URL
  that supports ranges; the URL is resolved just before the range GET and re-resolved
  once on a 403 (expiry).
- M4Raw: Zenodo serves ranges directly.

### Split ZIP with a per-file offset map (CMRxRecon2024)

The CMRxRecon2024 training and after-competition archives are each one giant ZIP split
into 4 GiB Synapse file entities. `cmrxrecon2024_fetch.jl` maps each `.mat` member to
its `(fragment, offset, length)` using the committed `data/cmrxrecon2024_map.csv`, then
range-reads across fragment boundaries as needed.

### zran checkpoint index for gzip streams (CMRxRecon-300, fastMRI `.tar.gz`)

A `.tar.gz` is a single continuous gzip stream and is **not** randomly seekable. The
package ships a precomputed **zran** (zlib random-access) index: while streaming the
archive once, a checkpoint is captured at the DEFLATE block boundary just before each
member — a 32 KiB dictionary snapshot plus the sub-byte bit offset. `src/util/zran.jl`
(`libz` `ccall` wrappers + `inflatePrime` for the bit offset) then seeds a raw-inflate
decoder from the nearest checkpoint and decompresses only forward to the member.

- CMRxRecon-300: checkpoints in `data/cmrxrecon300_zran/`, member maps
  `data/cmrxrecon300_<set>_map.csv`.
- fastMRI prostate/breast: checkpoints in `data/fastmri_zran/<archive_stem>.bin.gz`,
  members appended to `data/fastmri_map.csv`.

### xz block-level ranges (fastMRI `.tar.xz`)

An `.xz` file is a sequence of independently-compressed blocks. `scripts/index_fastmri.jl`
walks every block (fetched by range request), decompresses it in isolation and scans the
embedded tar members, recording one row per `.h5` file in `data/fastmri_map.csv`. The
runtime range-reads and decompresses just the block(s) spanning the requested member.

## The `.mat` → ISMRMRD conversion

`CMRXRECON2024`, `CMRXRECON300`, `M4RAW` and `FASTMRI` are not ISMRMRD. On first load
`_cmrxrecon_to_ismrmrd` (`src/load/cmrxrecon_ismrmrd.jl`) builds a valid Cartesian
ISMRMRD file and caches it next to the raw download:

- one profile per phase-encode line, temporal/parametric frames → ISMRMRD contrasts;
- CMRxRecon-300 and fastMRI (non-fully-sampled) read the true acquired-line pattern from
  the k-space zero-fill and mark the acquisition undersampled; the ACS lines are written
  into the same file flagged `ACQ_IS_PARALLEL_CALIBRATION`;
- M4Raw and fully-sampled fastMRI use an all-true mask;
- CMRxRecon ships no FOV — a placeholder (matrix size in mm) is written while the
  encoding/recon matrix reflects the true dimensions.

`MRITestData.load_mat` returns the raw MATLAB arrays (`Dict`) for the CMRxRecon sources
if you want to bypass the conversion.

## Static vs live indexes

`_is_static_index(source)` marks the sources whose catalog ships with the package
(CMRxRecon2024, CMRxRecon-300, USC Speech, M4Raw, fastMRI). For those `ensure_index`
returns the bundled path directly — nothing is fetched, cached or aged out, and
`refresh_index` is a no-op that still reports the path. Only `OCMR` and `MridataOrg`
define `_index_source_url` / `_fetch_index`:

- OCMR — the authoritative `ocmr_data_attributes.csv` from OCMR's S3 bucket.
- mridata.org — scraped from `mridata.org/list` (no JSON API exists). The committed
  `data/mridata_index.toml` is a curated overlay merged per-field on top of a successful
  scrape (curated values win), and used verbatim only when the scrape fails entirely.

A new map-backed source needs only `_bundled_index_path`, `_is_static_index`, its
row→entry parser, and a `_catalog_entries` that calls `_cached_index_entries`.

## Maintainer scripts

The committed index artifacts under `data/` are built offline by the scripts in
[`scripts/`](https://github.com/hakkelt/MRITestData.jl/blob/master/scripts/README.md).
They are needed only when adding a dataset version or when an upstream archive changes.

| Script | Produces | Needs |
|---|---|---|
| `list_cmrxrecon2024_parts.jl` | `data/cmrxrecon2024*_parts.toml` | Synapse token |
| `generate_cmrxrecon2024_map.jl` | `data/cmrxrecon2024_map.csv` | archive fragments on disk |
| `index_cmrxrecon300.jl` | `data/cmrxrecon300_*_map.csv` + zran checkpoints | Synapse token |
| `generate_usc_speech_map.jl` | `data/usc_speech_map.csv` | figshare access |
| `generate_m4raw_map.jl` | `data/m4raw_map.csv` | — |
| `index_fastmri.jl` | `data/fastmri_map.csv` (xz: knee, brain) | valid fastMRI signed URLs |
| `index_fastmri_gz.jl` | `data/fastmri_map.csv` + `data/fastmri_zran/` (gz: prostate, breast) | valid fastMRI signed URLs |

Each script's positional arguments are stored archive keys, local paths, or signed URLs;
see [`scripts/README.md`](https://github.com/hakkelt/MRITestData.jl/blob/master/scripts/README.md)
for the full archive lists and the parallel-execution recipe.

## Documentation assets

- `docs/generate_recon_images.jl` renders the coil-combined magnitude images in
  [Reconstruction with MRIReco](@ref). They are committed rather than built live because
  reconstruction needs MRIReco plus multi-GB real downloads (and a Synapse token).
- `docs/src/assets/browser-demo.svg` is a hand-authored animated illustration of the
  terminal browser (the real TUI cannot be captured in CI). Update it if the column set
  in `src/browse.jl` changes.
