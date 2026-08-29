using Documenter
using Documenter.Remotes: GitHub
using MRITestData

# Explicit remote so docs build even when no git remote is configured locally.
const REPO = GitHub("hakkelt", "MRITestData.jl")

makedocs(
    sitename = "MRITestData.jl",
    format = Documenter.HTML(
        prettyurls = get(ENV, "CI", nothing) == "true",
        repolink = "https://github.com/hakkelt/MRITestData.jl",
    ),
    pages = [
        "Home" => "index.md",
        "Concepts & data model" => "concepts.md",
        "Tutorial" => "tutorial.md",
        "Usage" => "usage.md",
        "Dataset contents" => "datasets.md",
        "Taxonomy" => "taxonomy.md",
        "FAQ & troubleshooting" => "faq.md",
        "Internals & maintainer notes" => "internals.md",
        "Glossary" => "glossary.md",
        "Licensing & legal" => "legal.md",
        "API Reference" => "api.md",
    ],
    modules = [MRITestData],
    repo = REPO,
    remotes = nothing,
    checkdocs = :public,
)

deploydocs(
    repo = "github.com/hakkelt/MRITestData.jl.git",
    push_preview = false,
)
