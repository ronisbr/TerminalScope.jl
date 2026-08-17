## Description #############################################################################
#
# Interactive smoke test: open the type-instability inspector on an unstable call chain.
#
# Run with:
#
#   julia --project=. examples/demo_descend.jl
#
############################################################################################

using TerminalScope

"""
    unstable_pick(x::Int) -> Union{Int, Float64}

Return an `Int` or a `Float64` depending on the sign of `x`, creating a type instability.
"""
unstable_pick(x::Int) = x > 0 ? 1 : 2.0

"""
    dynamic_sum(v::Vector{Any}) -> Number

Sum the elements of `v` through an untyped container, creating runtime dispatch call
sites.
"""
function dynamic_sum(v::Vector{Any})
    s = 0

    for x in v
        s += x
    end

    return s
end

"""
    workload(x::Int) -> Float64

Combine the unstable helpers so that the inspector shows unstable and dynamic call sites
at several levels.
"""
function workload(x::Int)
    a = unstable_pick(x)
    b = a + 1
    c = dynamic_sum(Any[a, b, x])
    return Float64(c) + b
end

@scope descend workload(3)
