

@testitem "naming" begin
    using RAIRelTest

    @testset "unix_basename" begin
        using RAIRelTest: unix_basename

        @test unix_basename("foo/bar/baz/") == "baz"
        @test unix_basename("foo/bar/baz") == "baz"
        @test unix_basename("foo/") == "foo"
        @test unix_basename("foo") == "foo"

        @test unix_basename("/foo/bar/baz/") == "baz"
        @test unix_basename("/foo/bar/baz") == "baz"
        @test unix_basename("/foo/") == "foo"
        @test unix_basename("/foo") == "foo"
    end

    @testset "pkg_name" begin
        using RAIRelTest: pkg_name

        @test pkg_name("pkg") == "pkg"
        @test pkg_name("../pkg") == "pkg"
        @test pkg_name("../pkg/") == "pkg"
        @test pkg_name("../../pkg/foo") == "foo"

        @test pkg_name("pkg-rel") == "pkg"
        @test pkg_name("../pkg-rel") == "pkg"
        @test pkg_name("../pkg-rel/") == "pkg"
        @test pkg_name("../../pkg/foo-rel") == "foo"
    end

    @testset "suite_name" begin
        using RAIRelTest: suite_name

        # any directory can be a suite
        @test suite_name("pkg") == "pkg"
        @test suite_name("../pkg") == "pkg"
        @test suite_name("../pkg/") == "pkg"
        @test suite_name("../../pkg/foo") == "foo"

        # if under /test/, remove the prefix
        @test suite_name("pkg/test/foo") == "foo"
        @test suite_name("pkg/test/foo/bar/baz") == "foo/bar/baz"
        @test suite_name("../pkg/test/foo") == "foo"
        @test suite_name("../pkg/test/foo/") == "foo"
        @test suite_name("../../pkg//test/foo") == "foo"
        @test suite_name("../../pkg//test/foo/bar") == "foo/bar"
        @test suite_name("../../pkg//test/foo/bar/baz") == "foo/bar/baz"
    end

    @testset "test_name" begin
        using RAIRelTest: test_name

        # any file can be a test (but really, it should end in .rel)
        @test test_name("pkg") == "pkg"
        @test test_name("../pkg") == "pkg"
        @test test_name("../pkg/") == "pkg"
        @test test_name("../../pkg/foo") == "foo"

        # if .rel, remove the ending
        @test test_name("pkg/test/foo.rel") == "foo"
        @test test_name("pkg/test/foo/bar/baz.rel") == "foo/bar/baz"
        @test test_name("../pkg/test/foo.rel") == "foo"
        @test test_name("../../pkg//test/foo.rel") == "foo"
        @test test_name("../../pkg//test/foo/bar.rel") == "foo/bar"
        @test test_name("../../pkg//test/foo/bar/baz.rel") == "foo/bar/baz"
    end
end


@testitem "test finding" begin
    using RAIRelTest

    @testset "compute_test_selectors" begin
        using RAIRelTest: TestSelector, compute_test_selectors

        # changes that force running the whole suite
        @test compute_test_selectors(["test/post-install.rel"]) == Set()
        @test compute_test_selectors(["test/before-package.rel"]) == Set()

        # changes to model cause the whole suite to run
        @test compute_test_selectors(["model/std/common.rel"]) == Set([TestSelector("std/common")])

        # changes to tests cause only those tests to run
        @test compute_test_selectors(["test/std/common/test-jaro_distance.rel"]) ==
            Set([TestSelector("std/common", ["test-jaro_distance.rel"])])
        @test compute_test_selectors(["test/std/common/test-jaro_winkler_distance.rel"]) ==
            Set([TestSelector("std/common", ["test-jaro_winkler_distance.rel"])])

        # mix of model and test changes
        @test compute_test_selectors([
            "model/std/pkg.rel",
            "test/std/common/test-jaro_distance.rel",
            "test/std/common/test-jaro_winkler_distance.rel"
        ]) == Set([
            TestSelector("std/pkg"),
            TestSelector("std/common",
                ["test-jaro_distance.rel", "test-jaro_winkler_distance.rel"])
        ])

        # change to model subsumes the individual tests
        @test compute_test_selectors([
            "model/std/common.rel",
            "test/std/common/test-jaro_distance.rel",
            "test/std/common/test-jaro_winkler_distance.rel"
        ]) == Set([TestSelector("std/common")])

        # mix of model and test changes with subsumption
        @test compute_test_selectors([
            "model/std/pkg.rel",
            "model/std/common.rel",
            "test/std/common/test-jaro_distance.rel",
            "test/std/common/test-jaro_winkler_distance.rel"
        ]) == Set([
            TestSelector("std/pkg"),
            TestSelector("std/common")
        ])

        # changes to multiple models
        @test compute_test_selectors([
            "model/graphlib-basics.rel",
            "model/graphlib-centrality.rel",
        ]) == Set([
            TestSelector("graphlib-basics")
            TestSelector("graphlib-centrality")
        ])
    end
end



@testitem "code blocks" begin
    using RAIRelTest

    @testset "parse_code_blocks" begin
        using RAIRelTest: parse_code_blocks, CodeBlock

        code = """
// some comments
// %%
def output { 1 }

// %% read
def output { 2 }

// %% write, abort, errors

def output { 3 }

// %% read, warnings, name="foo"
def output { 4 }
// %% name="bar", load="query.rel", write
// %% name="baz", read, write
def output { 6 }
"""
        blocks = parse_code_blocks(".", "my_code", split(code, "\n"))

        @test length(blocks) == 6

        @test blocks[1] == CodeBlock(
            "my_code", """
// some comments
def output { 1 }

""",
            nothing, false, false, false, false
        )
        @test blocks[2] == CodeBlock(
            "my_code", """
def output { 2 }

""",
            nothing, false, false, false, false
        )
        @test blocks[3] == CodeBlock(
            "my_code", """

def output { 3 }

""",
            nothing, true, false, true, true
        )
        @test blocks[4] == CodeBlock(
            "my_code", """
def output { 4 }
""",
            "foo", false, true, false, false
        )
        @test blocks[5] == CodeBlock(
            "my_code", """
def output { 5 }
""",
            "bar", true, false, false, false
        )
        @test blocks[6] == CodeBlock(
            "my_code", """
def output { 6 }""",
            "baz", true, false, false, false
        )

    end
end
