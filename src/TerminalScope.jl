## Description #############################################################################
#
# TerminalScope.jl: interactive terminal UI to diagnose Julia code — runtime profiles,
# type inference profiles, type instabilities, and method invalidations.
#
############################################################################################

module TerminalScope

using FlameGraphs
using Profile
using Tachikoma

import InteractiveUtils
import JuliaSyntaxHighlighting
import Logging
import PrecompileTools
import Preferences
import SnoopCompileCore
import StyledStrings
import TypedSyntax

using Base.StackTraces: StackFrame

Tachikoma.@tachikoma_app

export @scope, scope_profile, scope_inference, scope_allocs, scope_invalidations,
    scope_descend

include("theme.jl")
include("tree.jl")
include("format.jl")
include("detail.jl")
include("inspect.jl")
include("app.jl")
include("render.jl")

## Lazy Backends ###########################################################################

"""
    _CTHULHU_ID

Package identifier of Cthulhu, used to load it on demand.
"""
const _CTHULHU_ID =
    Base.PkgId(Base.UUID("f68482b8-f384-11e8-15f7-abe071a5a75f"), "Cthulhu")

"""
    _SNOOPCOMPILE_ID

Package identifier of SnoopCompile, used to load it on demand.
"""
const _SNOOPCOMPILE_ID =
    Base.PkgId(Base.UUID("aa65fe97-06da-5843-b5b1-d5d13cad87d2"), "SnoopCompile")

"""
    _load_backend(pkg::Base.PkgId, ext::Symbol; quiet::Bool = false) -> Bool

Load the dependency `pkg` so that the extension `ext` activates, returning whether the
extension is available afterwards. The load is skipped when the extension is already
active. `quiet` suppresses the loading message and any load-time output, used when a
Tachikoma application controls the terminal.

Cthulhu and SnoopCompile are loaded this way, on first use, because loading them
invalidates compiled code of unrelated packages; sessions that only use the profilers
never pay that cost.
"""
function _load_backend(pkg::Base.PkgId, ext::Symbol; quiet::Bool = false)
    (Base.get_extension(@__MODULE__, ext) !== nothing) && return true

    try
        if quiet
            redirect_stdout(devnull) do
                redirect_stderr(devnull) do
                    Base.require(pkg)
                end
            end
        else
            _scope_info("Loading $(pkg.name) (one-time initialization of this feature)...")
            Base.require(pkg)
        end
    catch
        return false
    end

    return Base.get_extension(@__MODULE__, ext) !== nothing
end

"""
    _ensure_inspector(; quiet::Bool = false) -> Bool

Load Cthulhu on demand and return whether the inspector backend is available.
"""
_ensure_inspector(; quiet::Bool = false) =
    _load_backend(_CTHULHU_ID, :TerminalScopeCthulhuExt; quiet = quiet)

"""
    _ensure_snoopcompile(; quiet::Bool = false) -> Bool

Load SnoopCompile on demand and return whether the invalidation backend is available.
"""
_ensure_snoopcompile(; quiet::Bool = false) =
    _load_backend(_SNOOPCOMPILE_ID, :TerminalScopeSnoopCompileExt; quiet = quiet)

"""
    _invalidation_trees(invs) -> Vector

Organize the raw invalidation data `invs` into `SnoopCompile.MethodInvalidations` trees.
The method is provided by the `TerminalScopeSnoopCompileExt` extension.
"""
function _invalidation_trees end

"""
    _invalidation_forest(invs) -> AbstractVector

Return the invalidation trees for `invs`: the input itself when it already is a
collection of trees (`SnoopCompile.MethodInvalidations`), and the result of
`SnoopCompile.invalidation_trees` otherwise (the raw `SnoopCompileCore.InvalidationLists`
returned by `SnoopCompileCore.@snoop_invalidations`).
"""
function _invalidation_forest(@nospecialize(invs))
    (invs isa AbstractVector) && return invs
    return Base.invokelatest(_invalidation_trees, invs)
end

include("api.jl")
include("precompile.jl")

end # module TerminalScope
