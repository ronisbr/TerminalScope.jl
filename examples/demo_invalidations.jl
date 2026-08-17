## Description #############################################################################
#
# Interactive smoke test: trigger method invalidations and open the viewer.
#
# Run with:
#
#   julia --project=. examples/demo_invalidations.jl
#
############################################################################################

using TerminalScope

"""
    loose_length(x) -> Int

Return a length-like value through an abstractly-typed method, so that compiled callers
are invalidated when a more specific method is added later.
"""
loose_length(x) = 1

"""
    consumer_a(v::Vector{Int}) -> Int

Call [`loose_length`](@ref) so its specialization gets a backedge from this method.
"""
consumer_a(v::Vector{Int}) = loose_length(v) + 1

"""
    consumer_b(v::Vector{Int}) -> Int

Call [`consumer_a`](@ref) to create a deeper invalidation chain.
"""
consumer_b(v::Vector{Int}) = consumer_a(v) * 2

# Compile the chain against the loose method.
consumer_b([1, 2, 3])

# Recording starts here: inserting a more specific method invalidates the chain.
@scope invalidations @eval loose_length(v::Vector{Int}) = length(v)
