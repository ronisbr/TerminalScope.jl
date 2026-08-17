## Description #############################################################################
#
# Interactive smoke test: profile the allocations of a synthetic workload and open the
# viewer.
#
# Run with:
#
#   julia --project=. examples/demo_allocs.jl
#
############################################################################################

using TerminalScope

"""
    churn(n::Int) -> Vector{String}

Allocate many small objects (strings and small vectors) to populate the count-oriented
side of the allocation profile.
"""
function churn(n::Int)
    out = String[]

    for i in 1:n
        push!(out, string("item ", i))
        _ = [i, i + 1, i + 2]
    end

    return out
end

"""
    bulk(n::Int) -> Float64

Allocate a few large matrices to populate the byte-oriented side of the allocation
profile.
"""
function bulk(n::Int)
    s = 0.0

    for _ in 1:n
        s += sum(rand(512, 512))
    end

    return s
end

"""
    workload() -> Nothing

Run both allocation patterns so the viewer shows a mixed profile.
"""
function workload()
    churn(5_000)
    bulk(20)
    return nothing
end

# `@scope allocs` runs the workload once before profiling (warm-up), so the profile shows
# the steady-state allocations with exact counts.
@scope allocs workload()
