## Description #############################################################################
#
# Tests related to the formatting helpers.
#
############################################################################################

@testset "Formatting" begin
    @test TS.format_count(0) == "0"
    @test TS.format_count(999) == "999"
    @test TS.format_count(1234) == "1,234"
    @test TS.format_count(1234567) == "1,234,567"

    @test TS.format_pct(57.34) == "57.3%"
    @test TS.format_pct(0.0) == "0.0%"
    @test TS.format_pct(0.04) == "<0.1%"
    @test TS.format_pct(100.0) == "100.0%"

    @test TS.format_seconds(0.0) == "0.0 ns"
    @test TS.format_seconds(4.2e-7) == "420.0 ns"
    @test TS.format_seconds(3.4e-4) == "340.0 µs"
    @test TS.format_seconds(0.0012) == "1.2 ms"
    @test TS.format_seconds(12.34) == "12.34 s"
    @test TS.format_seconds(65.0) == "1 min 5.0 s"

    @test length(TS.bar_string(50.0, 8)) == 8
    @test TS.bar_string(100.0, 4) == "████"
    @test TS.bar_string(0.0, 4) == "    "

    root = TS.build_tree(fixture_graph())
    @test TS.node_name(root) == "all samples"
    @test TS.node_location(root) == ""
    f = root.children[1]
    @test TS.node_name(f) == "f"
    @test endswith(TS.node_location(f), ":10")
    @test TS.node_package(f) == "TerminalScope.jl"
    @test TS.node_package(root) === nothing

    # Package resolution of source files.
    @test TS.file_package(@__FILE__) == "TerminalScope.jl"
    @test TS.file_package(pathof(Profile)) == "Profile.jl"
    @test TS.file_package("this_file_does_not_exist.jl") === nothing
    @test TS.file_package("") === nothing

    int_jl = Base.find_source_file("int.jl")
    ((int_jl !== nothing) && isfile(int_jl)) && @test TS.file_package("int.jl") == "Base"
end
