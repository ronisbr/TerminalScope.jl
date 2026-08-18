using Documenter
using TerminalScope

# Disable the remote source links when building outside a git checkout.
remotes_kwargs =
    isdir(joinpath(@__DIR__, "..", ".git")) ? NamedTuple() : (remotes = nothing,)

makedocs(;
    remotes_kwargs...,
    modules = [TerminalScope],
    format = Documenter.HTML(;
        prettyurls = !("local" in ARGS),
        canonical = "https://ronisbr.github.io/TerminalScope.jl/stable/",
    ),
    sitename = "Terminal Scope",
    authors = "Ronan Arraes Jardim Chagas",
    checkdocs = :exports,
    pages = [
        "Home" => "index.md",
        "Runtime Profile" => "man/runtime_profile.md",
        "Allocation Profile" => "man/allocation_profile.md",
        "Inference Profile" => "man/inference_profile.md",
        "Invalidations" => "man/invalidations.md",
        "Type Inspector" => "man/type_inspector.md",
        "Navigation and Themes" => "man/navigation.md",
        "Library" => "lib/library.md",
    ],
)

deploydocs(; repo = "github.com/ronisbr/TerminalScope.jl.git", target = "build")
