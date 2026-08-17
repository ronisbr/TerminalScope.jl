## Description #############################################################################
#
# SnoopCompile-backed organization of raw invalidation data. This extension activates
# when the user loads SnoopCompile, keeping its load-time invalidations out of sessions
# that only use the profilers.
#
############################################################################################

module TerminalScopeSnoopCompileExt

using SnoopCompile
using TerminalScope

const SnoopCompileCore = TerminalScope.SnoopCompileCore

"""
    TerminalScope._invalidation_trees(invs::SnoopCompileCore.InvalidationLists) -> Vector

Organize the raw invalidation data `invs` into the trees returned by
`SnoopCompile.invalidation_trees`.
"""
TerminalScope._invalidation_trees(invs::SnoopCompileCore.InvalidationLists) =
    SnoopCompile.invalidation_trees(invs)

end # module TerminalScopeSnoopCompileExt
