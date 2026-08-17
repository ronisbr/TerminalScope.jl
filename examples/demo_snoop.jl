## Description #############################################################################
#
# Interactive smoke test: profile type inference of a fresh workload and open the viewer.
#
# Inference only happens the first time code is compiled, so run this in a fresh session:
#
#   julia --project=. examples/demo_snoop.jl
#
############################################################################################

using TerminalScope

"""
    mixed_pipeline(v::Vector{Float64}) -> Float64

Run a workload combining broadcasting, sorting, and string handling, so that many method
instances must be inferred on the first call.
"""
function mixed_pipeline(v::Vector{Float64})
    w = sort(abs.(v) .+ 1.0; rev = true)
    s = sum(x -> sin(x) * sqrt(x), w)
    return s + length(join(string.(round.(w[1:10]; digits = 2)), ", "))
end

@scope inference mixed_pipeline(randn(10_000))
