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
