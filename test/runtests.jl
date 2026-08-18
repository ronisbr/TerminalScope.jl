## Description #############################################################################
#
# Tests for TerminalScope.jl.
#
############################################################################################

using Test

using FlameGraphs
using LeftChildRightSiblingTrees
using Profile
using Tachikoma
using TerminalScope

import Cthulhu
import Preferences
import SnoopCompile
import SnoopCompileCore

using Base.StackTraces: StackFrame

import Tachikoma: update!, should_quit

const TS = TerminalScope

"""
    tview(m, f) -> Nothing

Call `Tachikoma.view`, which is not exported to avoid clashing with `Base.view`.
"""
tview(m, f) = Tachikoma.view(m, f)

############################################################################################
#                                         Fixture                                          #
############################################################################################

"""
    _sf(func::Symbol, file::Symbol, line::Int; from_c::Bool = false) -> StackFrame

Create a `StackFrame` for the test fixture.
"""
function _sf(func::Symbol, file::Symbol, line::Int; from_c::Bool = false)
    return StackFrame(func, file, line, nothing, from_c, false, 0)
end

"""
    fixture_graph() -> LeftChildRightSiblingTrees.Node{FlameGraphs.NodeData}

Build a hand-crafted flame graph with a known structure:

    root (100)
    ├── f (80)
    │   ├── g (50)
    │   │   └── h (50)   [runtime dispatch]
    │   └── k (20)       [GC]
    └── m (15)
"""
function fixture_graph()
    ND = FlameGraphs.NodeData
    root = Node(ND(Base.StackTraces.UNKNOWN, 0x00, 1:100))
    f = addchild(root, ND(_sf(:f, Symbol(@__FILE__), 10), 0x00, 1:80))
    g = addchild(f, ND(_sf(:g, Symbol(@__FILE__), 20), 0x00, 1:50))
    addchild(g, ND(_sf(:h, Symbol(@__FILE__), 30), FlameGraphs.runtime_dispatch, 1:50))
    addchild(f, ND(_sf(:k, :Sys, 40; from_c = true), FlameGraphs.gc_event, 51:70))
    addchild(root, ND(_sf(:m, Symbol("missing_file.jl"), 5), 0x00, 81:95))
    return root
end

"""
    make_model() -> TS.ProfileViewer

Create a viewer model from the test fixture graph.
"""
make_model() = TS.ProfileViewer(fixture_graph())

"""
    _inspect_unstable(x) -> Union{Int, Float64}

Type-unstable helper inspected by the type-instability inspector tests.
"""
_inspect_unstable(x) = x > 0 ? 1 : 2.0

"""
    _inspect_caller(x) -> Float64

Caller of the type-unstable helper inspected by the type-instability inspector tests.
"""
function _inspect_caller(x)
    a = _inspect_unstable(x)
    return Float64(a) + 1.0
end

############################################################################################
#                                        Test Sets                                         #
############################################################################################

@testset "Tree Model" verbose = true begin
    include("./tree.jl")
end

@testset "Formatting" verbose = true begin
    include("./formatting.jl")
end

@testset "Keyboard Navigation" verbose = true begin
    include("./navigation.jl")
end

@testset "Mouse" verbose = true begin
    include("./mouse.jl")
end

@testset "Frame Search" verbose = true begin
    include("./search.jl")
end

@testset "Source Panel" verbose = true begin
    include("./source_panel.jl")
end

@testset "Runtime Profile" verbose = true begin
    include("./runtime_profile.jl")
end

@testset "Inference Profile" verbose = true begin
    include("./inference_profile.jl")
end

@testset "Rendering" verbose = true begin
    include("./rendering.jl")
end

@testset "Type Inspector" verbose = true begin
    include("./type_inspector.jl")
end

@testset "Invalidations" verbose = true begin
    include("./invalidations.jl")
end

@testset "Allocations" verbose = true begin
    include("./allocations.jl")
end

@testset "Lazy Backends" verbose = true begin
    include("./lazy_backends.jl")
end

@testset "Themes" verbose = true begin
    include("./themes.jl")
end
