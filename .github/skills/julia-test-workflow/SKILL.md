---
name: julia-test-workflow
description: 'Use for iterating on the MRITestData.jl test suite: running filtered subsets, triaging failures, and running opt-in network/MRT tests.'
argument-hint: 'Describe which tests to run or what is failing (tag, test name, or scenario)'
user-invocable: true
---

# Julia Test Workflow for MRITestData.jl

## When To Use

- Iterating on a failing test without re-running the entire suite.
- Running opt-in network tests (live downloads from OCMR / mridata.org).
- Running opt-in MriReconstructionToolbox integration tests.
- Narrowing a failure to a specific test name or tag.

## Quick Reference

Julia binary: `/scratch/c_mrrecon/julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia`

All commands run from `/project/c_mrrecon/MRITestData/`.

### Full offline suite (default)

```sh
/scratch/c_mrrecon/julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia \
  --project=test test/runtests.jl
```

### Filtered run — by tag

```sh
/scratch/c_mrrecon/julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia \
  --project=test test/runtests.jl ":quality"
```

Multiple tags / names as a single comma-separated string:

```sh
/scratch/c_mrrecon/julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia \
  --project=test test/runtests.jl ":network,:mrireco"
```

### Filtered run — by exact test name

```sh
/scratch/c_mrrecon/julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia \
  --project=test test/runtests.jl \
  "OCMR: refresh index + download + reconstruct"
```

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

### Opt-in MRT tests (MriReconstructionToolbox; fragile in merged env)

```sh
MRITESTDATA_MRT_TESTS=true \
  /scratch/c_mrrecon/julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia \
  --project=test test/runtests.jl
```

### Docs build (verify checkdocs=:public passes)

```sh
/scratch/c_mrrecon/julia/juliaup/julia-1.12.6+0.x64.linux.gnu/bin/julia \
  --project=docs docs/make.jl
```

## Tag Scheme

| Tag | Meaning | Runs by default? |
|-----|---------|-----------------|
| *(none)* | Offline unit tests: catalog, cache, load | Yes |
| `:mrireco` | MRIReco extension — offline, synthetic fixtures | Yes |
| `:quality` | Aqua + JET static analysis | Yes |
| `:network` | Live downloads from OCMR S3 / mridata.org | No (opt-in) |
| `:mrt` | MriReconstructionToolbox integration | No (opt-in) |

## Workflow

1. Identify which tag or test name covers the failure.
2. Run filtered with the ARGS filter to iterate quickly.
3. Fix the real implementation bug (never weaken tests to hide failures).
4. Re-run the full offline suite to check for regressions.
5. For network failures: confirm the host is reachable before debugging code.

## Known issues

- **mridata.org over HTTPS**: outbound port 443 is blocked on this HPC. All
  mridata.org URLs use `http://` so downloads go over port 80.
- **OCMR ECG header bug**: MRIFiles parses `<waveformName>` as `Float64`, but
  cardiac OCMR files store `"ECG"` there. `load_raw`/`load_acq` strip
  `<waveformInformation>` blocks from the cached HDF5 before MRIFiles reads it.
- **MRT tests** (`MriReconstructionToolbox`) fail to precompile in the merged dev
  environment due to `ProximalAlgorithms` version conflicts; always tag `:mrt`.

## Done Criteria

- Targeted tests pass.
- Full offline suite (73 tests) still green.
- No new JET or Aqua errors introduced.
