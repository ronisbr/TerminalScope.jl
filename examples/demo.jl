## Description #############################################################################
#
# Interactive smoke test: profile a synthetic workload and open the viewer.
#
# Run with:
#
#   julia --project=. examples/demo.jl
#
############################################################################################

using TerminalScope

"""
    unstable_sum(v::Vector{Any}) -> Number

Sum the elements of `v` using a type-unstable accumulator to trigger runtime dispatch
frames in the profile.
"""
function unstable_sum(v::Vector{Any})
    s = 0
    for x in v
        s += x
    end
    return s
end

"""
    allocating_work(n::Int) -> Float64

Allocate `n` temporary matrices and reduce them, generating garbage collection events in
the profile.
"""
function allocating_work(n::Int)
    acc = 0.0
    for _ in 1:n
        m = randn(200, 200)
        acc += sum(m * m)
    end
    return acc
end

"""
    workload() -> Float64

Run a mixed workload for roughly two seconds: numeric kernels, allocations, and
type-unstable code.
"""
function workload()
    v = Any[i % 3 == 0 ? Float64(i) : i for i in 1:100_000]
    acc = 0.0

    for _ in 1:20
        acc += allocating_work(5)
        acc += unstable_sum(v)
        acc += sum(sin(i) + sqrt(abs(cos(i))) for i in 1:1_000_000)
    end

    return acc
end

# Warm up so compilation does not dominate the profile.
workload()

@scope workload()
