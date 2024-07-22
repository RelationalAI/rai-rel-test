

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
