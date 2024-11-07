

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

    @testset "get_diff_filters" begin
        using RAIRelTest: get_diff_filters

        @test get_diff_filters(["model/std/common.rel"]) == Set(["std/common"])
        @test get_diff_filters(["test/before-package.rel"]) == Set([])
        @test get_diff_filters(["test/std/common/test-jaro_distance.rel"]) == Set(["std/common"])
        @test get_diff_filters(["test/std/common/test-jaro_winkler_distance.rel"]) == Set(["std/common"])

        # returned value is a set, so it removes duplicates
        @test length(get_diff_filters([
            "model/std/common.rel",
            "test/before-package.rel",
            "test/std/common/test-jaro_distance.rel",
            "test/std/common/test-jaro_winkler_distance.rel"
        ])) == 1
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
