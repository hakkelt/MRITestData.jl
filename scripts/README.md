# CMRxRecon2024 Maintainer Scripts

These scripts regenerate the committed/runtime data files under `data/` that the
package reads to fetch CMRxRecon2024 files. You only need them when adding new dataset
versions or when the upstream Synapse archives change.

The **training** archive (`ChallengeData.zip`) and the **after-competition** archive
(`ChallengeData_AfterCompetition.zip`) are handled **identically**: each is one giant
ZIP split into 4 GiB fragments hosted as individual Synapse file entities, and every
script takes the same options for both — only the Synapse parent folder, the
fragment-name prefix, and the output path differ.

| Archive | Synapse parent folder | Fragment prefix | Fragments |
| --- | --- | --- | --- |
| training | `syn57588679` | `ChallengeData.zip-part-` | 210 (`-000`…`-209`) |
| after-competition | `syn63935434` | `ChallengeData_AfterCompetition.zip-part-` | 92 (`-00`…`-91`) |

## Synapse token

Every script that hits Synapse resolves a Personal Access Token (PAT) from, in order:
a `--token <PAT>` flag, the `SYNAPSE_AUTH_TOKEN` environment variable, or the
`synapse_token` preference in the project's gitignored `LocalPreferences.toml`
(written by `MRITestData.set_synapse_token!(token)`). Storing it once with
`set_synapse_token!` means you never pass the PAT on the command line.

**Never commit a PAT.** `LocalPreferences.toml` is gitignored; keep it that way.

---

## Workflow overview

```
list_cmrxrecon2024_parts.jl       → data/cmrxrecon2024_parts.toml
                                  → data/cmrxrecon2024_aftercompetition_parts.toml
download_cmrxrecon2024_fragments.jl  (optional: bulk-download fragments to disk)
generate_cmrxrecon2024_map.jl     → data/cmrxrecon2024_map.csv  (needs fragments on disk)
annotate_cmrxrecon2024_map.jl     → re-annotate an existing map without re-parsing
extract_cmrxrecon2024_filemeta.jl    (optional: record .mat variable shapes)
```

`synapse_common.jl` holds the shared Synapse REST helpers (token resolution, fragment
listing, pre-signed URLs) used by the listing and download scripts.

`zipdir_common.jl` holds the Zip64-aware central-directory reader shared by the three
offset-map generators (`generate_cmrxrecon2024_map.jl`, `generate_m4raw_map.jl`,
`generate_usc_speech_map.jl`). Each generator supplies only a *reader* — anything with a
`total` field and a `read_global(reader, offset, n)` method — and gets
`parse_central_directory`, `local_header_size` and `member_span` on top of it. Add a new
ZIP-backed source by writing its reader, not another directory walker.

The two `*_parts.toml` entity-ID maps are required at runtime by
`download_dataset(CMRXRECON2024, …)`. The training map is committed; regenerate either
when Synapse entity IDs change.

---

## 1. `list_cmrxrecon2024_parts.jl` — Synapse fragment entity-ID maps

```sh
# training
julia --project=. scripts/list_cmrxrecon2024_parts.jl syn57588679

# after-competition
julia --project=. scripts/list_cmrxrecon2024_parts.jl syn63935434 \
    --prefix ChallengeData_AfterCompetition.zip-part- \
    --out data/cmrxrecon2024_aftercompetition_parts.toml
```

Options: `--prefix`, `--out`, `--chunk-size` (default 4 GiB), `--token`.

---

## 2. `download_cmrxrecon2024_fragments.jl` — bulk-download fragments

Downloads every fragment of one archive (concurrently) and, with `--cat`, concatenates
them into a unified ZIP. Needs disk space (~840 GiB training, ~380 GiB after-competition).

```sh
# training fragments, 6 concurrent downloads, resumable
julia --project=. scripts/download_cmrxrecon2024_fragments.jl syn57588679 \
    --out /data/cmrxrecon2024 --jobs 6 --skip-existing

# after-competition fragments, then concatenate into one zip
julia --project=. scripts/download_cmrxrecon2024_fragments.jl syn63935434 \
    --prefix ChallengeData_AfterCompetition.zip-part- \
    --out /data/cmrxrecon2024 --jobs 6 --skip-existing
```

Options: `--prefix`, `--out`, `--cat <filename>`, `--jobs <n>` (default 4),
`--limit <n>` (download only the first n fragments — handy for smoke tests),
`--skip-existing`, `--token`. Each fragment's byte count is verified against Synapse.

---

## 3. `generate_cmrxrecon2024_map.jl` — generate the offset map

Parses the ZIP central directory of the fragments on disk and writes
`data/cmrxrecon2024_map.csv` (per-file fragment + byte coordinates, plus annotated
metadata). Point it at **one directory holding both archives' fragments**; the
after-competition rows are appended automatically when those fragments are present.

```sh
julia --project=. scripts/generate_cmrxrecon2024_map.jl /data/cmrxrecon2024
```

Pass an explicit output path as a second argument to write elsewhere (e.g. for testing).
Each `.mat` row is tagged with an `archive` column (`training` / `aftercompetition`)
that selects the entity-ID map at download time. Mask files and withdrawn/abnormal
files are dropped.

After regenerating, refresh the in-memory catalog:
```julia
using MRITestData; MRITestData.refresh_index(CMRXRECON2024)
```

---

## 4. `annotate_cmrxrecon2024_map.jl` — re-annotate without reparsing

Adds/replaces the derived metadata columns (modality, subject, acquisition parameters)
on an existing map CSV — useful when annotation logic changes without re-parsing the
archives.

```sh
# path-derived columns only
julia --project=. scripts/annotate_cmrxrecon2024_map.jl

# with acquisition parameters from extracted *_info.csv files
julia --project=. scripts/annotate_cmrxrecon2024_map.jl --info-dir /path/to/info_csvs
```

To extract the embedded info CSVs from an archive's fragments:
```julia
include("scripts/generate_cmrxrecon2024_map.jl")
fr = FragmentReader("/data/cmrxrecon2024", AFTERCOMP_PREFIX)  # or TRAINING_PREFIX
extract_info_csvs(fr, parse_central_directory(fr), "/tmp/info_csvs")
```

---

## 5. `extract_cmrxrecon2024_filemeta.jl` — record `.mat` shapes (optional)

Reads `.mat` headers (no payload) from a local extract and records k-space variable
names + array shapes. The catalog works without it.

```sh
julia --project=. scripts/extract_cmrxrecon2024_filemeta.jl /path/to/mat/files/ \
    [data/cmrxrecon2024_filemeta.csv]
```

---

## Full regeneration from scratch

```sh
# 1. Entity-ID maps for both archives
julia --project=. scripts/list_cmrxrecon2024_parts.jl syn57588679
julia --project=. scripts/list_cmrxrecon2024_parts.jl syn63935434 \
    --prefix ChallengeData_AfterCompetition.zip-part- \
    --out data/cmrxrecon2024_aftercompetition_parts.toml

# 2. Download all fragments of both archives into one directory
julia --project=. scripts/download_cmrxrecon2024_fragments.jl syn57588679 \
    --out /data/cmrxrecon2024 --jobs 6 --skip-existing
julia --project=. scripts/download_cmrxrecon2024_fragments.jl syn63935434 \
    --prefix ChallengeData_AfterCompetition.zip-part- \
    --out /data/cmrxrecon2024 --jobs 6 --skip-existing

# 3. Regenerate the offset map (both archives, from the same directory)
julia --project=. scripts/generate_cmrxrecon2024_map.jl /data/cmrxrecon2024

# 4. Commit the updated data files
git add data/cmrxrecon2024_map.csv \
        data/cmrxrecon2024_parts.toml \
        data/cmrxrecon2024_aftercompetition_parts.toml
git commit -m "Regenerate CMRxRecon2024 offset map and parts"
```

---

# CMRxRecon-300 Maintainer Scripts

CMRxRecon-300 ([`syn52965326`](https://www.synapse.org/Synapse:syn52965326), CC-BY) is
distributed as `.tar.gz` archives split into raw 16 GiB fragments. A `.tar.gz` is one
continuous gzip stream, so — unlike the CMRxRecon2024 ZIP — individual members cannot be
range-extracted directly. Instead a single maintainer pass builds a **zran** (zlib
random-access) checkpoint index that lets the runtime resume decompression mid-stream and
pull one `.mat` with HTTP range requests.

| Archive | Fragments | ≈ Size |
| --- | --- | --- |
| `DemoData.tar.gz` | 1 (unsplit) | 1.8 GB (single subject — committed test fixture) |
| `TrainingSet.tar.gz` | 17 (`-part-00`…`-16`) | 260 GB |
| `ValidationSet.tar.gz` | 8 (`-part-00`…`-07`) | 122 GB |
| `TestSet.tar.gz` | 13 (`-part-00`…`-12`) | 199 GB |

## `index_cmrxrecon300.jl` — build the random-access artifacts

One streaming pass over an archive records every `.mat` member's uncompressed payload
offset + size and captures **one zran checkpoint placed just before each member**, writing
three files to `data/`:

- `cmrxrecon300_<set>_parts.toml` — fragment-name → Synapse entity-ID map
- `cmrxrecon300_<set>_map.csv` — `path,set,subject,modality,matfile,data_offset,size`
- `cmrxrecon300_<set>_index.bin.gz` — gzip-compressed zran checkpoint index (one per file)

```sh
# DemoData (small; the committed network-test fixture)
julia --project=. scripts/index_cmrxrecon300.jl DemoData

# Full sets (each downloads the whole archive once)
julia --project=. scripts/index_cmrxrecon300.jl TrainingSet
julia --project=. scripts/index_cmrxrecon300.jl ValidationSet
julia --project=. scripts/index_cmrxrecon300.jl TestSet
```

Because checkpoints are placed per file (at the DEFLATE block boundary just before each
`.mat`), a single-file fetch streams only that file plus a fraction of a block, and the
index holds ~one 32 KiB window per file (≈ a few MB per set). The token is resolved exactly
as for the CMRxRecon2024 scripts (`--token`, `$SYNAPSE_AUTH_TOKEN`, or the stored
`synapse_token` preference); a free Synapse account suffices (no challenge registration).

---

# USC Speech Maintainer Scripts

The USC SPAN 75-speaker dataset ([figshare 13725546](https://doi.org/10.6084/m9.figshare.13725546),
CC-BY) is delivered as a single ~570 GB `dataset.zip`. Because it is a ZIP (not a single
gzip stream like CMRxRecon-300), individual `.h5` members **can** be range-extracted
directly — the runtime only needs each member's byte span, local-header length and
compression method, which one maintainer pass over the ZIP central directory records.

## `generate_usc_speech_map.jl` — generate the offset map

Reads the archive's **ZIP64** central directory over HTTP range requests (no full download)
and, for every `*/2drt/raw/*_raw.h5` member, writes one row to `data/usc_speech_map.csv`:

```
path,start_off,end_off,lfh_size,compressed_size,uncompressed_size,compression,file_id,subject,modality,stimulus,repetition
```

```sh
# Full corpus (dataset.zip, figshare file id 26378810 — the default)
julia --project=. scripts/generate_usc_speech_map.jl

# Small per-subject archive (example_for_sub001.zip, file id 26375235) — cheap to index,
# useful for a real, end-to-end-working sample map
julia --project=. scripts/generate_usc_speech_map.jl --file-id 26375235 --out data/usc_speech_map.csv
```

No authentication is needed (public CC-BY). figshare's `ndownloader` 302-redirects to a
short-lived presigned S3 URL; the script resolves it and re-resolves on a 403 (expiry).
`dataset.zip` is >4 GB, so ZIP64 central-directory handling is mandatory. The `--file-id`
value is written verbatim into every row, so the runtime fetches each member from the same
archive the map was built against.

---

# M4Raw Maintainer Scripts

The M4Raw low-field brain dataset ([Zenodo 8056074](https://doi.org/10.5281/zenodo.8056074),
CC-BY) is delivered as several multi-GB ZIPs (multicoil train/val/test + GRE; the
metrics-only `motion` archive is not indexed). Like USC Speech (and unlike CMRxRecon-300),
each ZIP member can be range-extracted directly — the runtime only needs each member's byte
span, local-header length and compression method, which one maintainer pass over each ZIP
central directory records.

## `generate_m4raw_map.jl` — generate the offset map

Reads each archive's **ZIP64** central directory over HTTP range requests (no full download)
and, for every `.h5` member, writes one row to `data/m4raw_map.csv`:

```
path,start_off,end_off,lfh_size,compressed_size,uncompressed_size,compression,archive,study,contrast,repetition,set
```

```sh
# All four indexed archives (the default: multicoil train/val/test + GRE)
julia --project=. scripts/generate_m4raw_map.jl

# A subset (repeat --archive to pick more than one)
julia --project=. scripts/generate_m4raw_map.jl --archive M4RawV1.5_multicoil_val.zip
```

No authentication is needed (public CC-BY). Zenodo serves the file directly from `/content`
(no redirect) and honours byte ranges, but **rate-limits to ~133 requests/minute** (sending
`Retry-After` on a 429); the script paces its requests (~0.55 s apart) and backs off on a
429. The archives are >4 GB, so ZIP64 central-directory handling is mandatory. The `archive`
ZIP name is written into every row, so the runtime fetches each member from the right Zenodo
archive (`https://zenodo.org/api/records/8056074/files/<archive>/content`). Indexing the full
training set (~1k members) therefore takes several minutes.

---

# fastMRI Maintainer Scripts

fastMRI ([fastmri.med.nyu.edu](https://fastmri.med.nyu.edu), NYU/Facebook AI Research) provides
knee, brain, prostate, and breast MRI k-space datasets. Access requires completing an online
form; the response email contains time-limited AWS S3 pre-signed URLs (90-day expiry).

Two archive formats are used:

| Format | Anatomies | Extraction strategy |
| --- | --- | --- |
| `.tar.xz` | knee, brain | xz block-level HTTP range requests |
| `.tar.gz` | prostate, breast | zran checkpoint + HTTP range requests |

The per-member offset maps and (for `.tar.gz`) zran checkpoint indices are stored in
`data/fastmri_map.csv` and `data/fastmri_zran/` and must be regenerated whenever new
archives are added. Both maps are static (no upstream index to scrape); the runtime reads
them from the committed files.

## Credential setup

Register credentials **once** by pasting the full fastMRI response email (or just its
curl-command block) into Julia:

```julia
using MRITestData
MRITestData.set_fastmri_urls!("<content of the email>")
MRITestData.fastmri_url_expires()   # check expiry date
```

This writes all signed URLs into the gitignored `LocalPreferences.toml`. The 114 URLs in
the response email cover all four anatomies across all splits. Credentials expire after 90
days; re-run `set_fastmri_urls!` with a fresh email to refresh them.

---

## 1. `index_fastmri.jl` — knee and brain (`.tar.xz`)

Parses each archive's xz stream index (two tiny range requests), walks all xz blocks, and
for each `.h5` tar member records the block byte range and intra-block data offset. Appends
rows to `data/fastmri_map.csv`.

```sh
# Index all knee and brain archives (credentials must be stored first)
julia --project=. scripts/index_fastmri.jl \
    knee_singlecoil_train.tar.xz \
    knee_singlecoil_val.tar.xz \
    knee_singlecoil_test_v2.tar.xz \
    knee_singlecoil_test_full.tar.xz \
    knee_multicoil_train.tar.xz \
    knee_multicoil_val.tar.xz \
    knee_multicoil_test.tar.xz \
    knee_multicoil_test_full.tar.xz \
    brain_multicoil_train.tar.xz \
    brain_multicoil_val.tar.xz \
    brain_multicoil_test.tar.xz \
    brain_multicoil_test_full_batch_1.tar.xz \
    brain_multicoil_test_full_batch_2.tar.xz

# Or index a single archive
julia --project=. scripts/index_fastmri.jl knee_singlecoil_val.tar.xz
```

Options:
- `--fresh` — overwrite `data/fastmri_map.csv` (header only) before starting; default
  is to append
- `--download-dir DIR` — directory for downloaded archives (default:
  `/scratch/c_mrrecon/fastmri_dl`); each archive is deleted after indexing

Each archive is downloaded, fully parsed, and deleted before moving to the next.
Re-running is safe: the script skips re-downloading archives already present on disk
(curl `-C -` resumes partial downloads).

---

## 2. `index_fastmri_gz.jl` — prostate and breast (`.tar.gz`)

Unlike the xz archives, `.tar.gz` is a single continuous DEFLATE stream with no
block-level index. This script does a **one-time streaming pass** over each archive to
simultaneously:

1. Parse the tar stream to find every `.h5` member's uncompressed payload offset and size.
2. Capture one **zran checkpoint** (32 KiB dictionary + DEFLATE bit offset) at the block
   boundary just before each member's payload. This lets the runtime seek mid-stream and
   re-inflate only the bytes it needs.

Per-archive checkpoint indices are written to `data/fastmri_zran/<archive_stem>.bin.gz`;
member metadata is appended to `data/fastmri_map.csv` (same schema as the xz entries, with
`coils` holding the sequence type for prostate archives: `DIFF` or `T2`).

```sh
# Index prostate T2 archives (16 archives, ~34 GB each)
julia --project=. scripts/index_fastmri_gz.jl \
    --download-dir /scratch/fastmri_dl/t2 \
    --output /tmp/prostate_t2.csv \
    fastMRI_prostate_T2_IDS_001_020.tar.gz \
    fastMRI_prostate_T2_IDS_021_040.tar.gz
    # ... remaining archives

# Index prostate DIFF archives (30 archives, ~10 GB each)
julia --project=. scripts/index_fastmri_gz.jl \
    --download-dir /scratch/fastmri_dl/diff \
    --output /tmp/prostate_diff.csv \
    fastMRI_prostate_DIFF_IDS_001_011.tar.gz \
    # ...

# Index breast archives (30 archives, ~20 GB each)
julia --project=. scripts/index_fastmri_gz.jl \
    --download-dir /scratch/fastmri_dl/breast \
    --output /tmp/breast.csv \
    fastMRI_breast_IDS_001_011.tar.gz \
    # ...
```

Options:
- `--fresh` — write a fresh CSV header before starting (default: append)
- `--download-dir DIR` — where to store downloaded archives (each is deleted after
  indexing; default: `/scratch/c_mrrecon/fastmri_dl`)
- `--output PATH` — output CSV path (default: `data/fastmri_map.csv`); use separate
  output paths when running multiple jobs in parallel to avoid concurrent-append
  corruption

**Parallel execution** (recommended — each job group is independent):

```sh
julia --project=. scripts/index_fastmri_gz.jl \
    --download-dir /scratch/fastmri_dl/t2 --output /tmp/t2.csv \
    fastMRI_prostate_T2_IDS_*.tar.gz &

julia --project=. scripts/index_fastmri_gz.jl \
    --download-dir /scratch/fastmri_dl/diff --output /tmp/diff.csv \
    fastMRI_prostate_DIFF_IDS_*.tar.gz &

julia --project=. scripts/index_fastmri_gz.jl \
    --download-dir /scratch/fastmri_dl/breast --output /tmp/breast.csv \
    fastMRI_breast_IDS_*.tar.gz &

wait

# Merge output CSVs (skip headers from the per-job files)
{ head -1 /tmp/t2.csv; tail -n +2 /tmp/t2.csv /tmp/diff.csv /tmp/breast.csv; } \
    >> data/fastmri_map.csv
```

The per-archive zran indices (`data/fastmri_zran/*.bin.gz`) are written directly by each
job and require no merging — one file per archive, each independent.

---

## Full regeneration from scratch

```sh
# 1. Store credentials (once per 90-day cycle)
julia --project=. -e '
    using MRITestData
    MRITestData.set_fastmri_urls!("<content of the email>")
'

# 2. Clear the existing map and re-index xz archives (knee + brain)
julia --project=. scripts/index_fastmri.jl --fresh \
    knee_singlecoil_{train,val,test_v2,test_full}.tar.xz \
    knee_multicoil_{train,val,test,test_full}.tar.xz \
    brain_multicoil_{train,val,test,test_full_batch_1,test_full_batch_2}.tar.xz

# 3. Index gz archives in parallel (prostate + breast)
julia --project=. scripts/index_fastmri_gz.jl \
    --download-dir /scratch/fastmri_dl/t2 --output /tmp/t2.csv \
    fastMRI_prostate_T2_IDS_*.tar.gz &

julia --project=. scripts/index_fastmri_gz.jl \
    --download-dir /scratch/fastmri_dl/diff --output /tmp/diff.csv \
    fastMRI_prostate_DIFF_IDS_*.tar.gz &

julia --project=. scripts/index_fastmri_gz.jl \
    --download-dir /scratch/fastmri_dl/breast --output /tmp/breast.csv \
    fastMRI_breast_IDS_*.tar.gz &

wait
{ tail -n +2 /tmp/t2.csv /tmp/diff.csv /tmp/breast.csv; } >> data/fastmri_map.csv
```

After regenerating, reload the catalog in a running Julia session:
```julia
MRITestData.refresh_index(FASTMRI)
```
