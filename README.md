# The RelationalAI Testing Kit for Rel

Provides a framework for defining and running tests for Rel projects. Tests can be defined
in 2 ways:

1. in Rel files using folder structure and file naming conventions, or
2. in Julia files using [ReTestItems](https://github.com/JuliaTesting/ReTestItems.jl) tests

`RAIRelTest` can be used from the command line (using the `rai_rel_test` command) or from
the `REPL` (start it using `rai_rel_test repl`).

For Rel tests, it provides functions to execute tests for the whole repository
(`test_packages`), for a single package (`test_package`), a single suite within a package
(`run_suite`) and a single test within a suite (`run_test`). It also provides other
supporting functions, such as `run_script`, `install_package`, `prepare_package` and
`prepare_suite`.

Julia tests can be executed by package or file.
