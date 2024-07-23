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


# Basic Usage

## Requirements

1. RAI's `.rai/config` has a profile with credentials to use a cloud account.

## Recommended Setup

It is recommended that you create an engine in the account configured above, which `rai-rel-test` will use. If this is not configured, `rai-rel-test` will create a pool of engines on-demand. That is useful for running on CI, but may be too slow for interactive usage.

You can configure the engine name by setting the `RAI_ENGINE` env var, or you can configure a session value (see next section).

```
    export RAI_ENGINE=my_engine
```

## Using the REPL

Start the REPL:

```
    ./rai_rel_test repl
```

If `RAI_ENGINE` was not set up, you can configure the engine for this session in the REPL:

```
    julia> set_session_engine!("my_engine")
```

Tip: you can also set which profile from `.rai/config` to use in the session with `set_session_context!("another_profile")`.

Run all tests for a package. The argument is the path to the directory where the package is located.

```
    julia> test_package("../my_package")
```
