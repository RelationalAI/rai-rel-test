
import RAI
import RAITest
using Dates
using RAITest: RAITestSet
using Test
using ReTestItems

"""
    test_packages(
        package_dirs::Vector{T},
        db_prefix::Union{AbstractString,Nothing}=nothing;
        skip_suites::Bool=false,
        skip_testitems::Bool=false,
        pool_size::Int=1,
        config::Union{Config,Nothing}=nothing,
    ) where {T<:AbstractString}

Run all tests in these packages.

Search for tests in the directories identified by the names in `package_dirs`. For each
package, a database will be created, the package will be installed, and the tests will be
executed. The `db_prefix` argument is used as a prefix for the name of the created database.
If it is nothing, the package name is used as a prefix.

By default we search for both Rel as well as Julia tests, but the skip flags can be used to
control that.

If a testing engine pool is required by any package, it will be started prior to the
execution of tests, and it will be stopped before returning. A pool is required either if
`config` does not set an engine or if any package has Julia tests (those cannot use an
explicit engine).
"""
function test_packages(
    package_dirs::Vector{T},
    db_prefix::Union{AbstractString,Nothing}=nothing;
    skip_suites::Bool=false,
    skip_testitems::Bool=false,
    pool_size::Int=1,
    config::Union{Config,Nothing}=nothing,
) where {T<:AbstractString}

    # load default if needed
    config = or_else(() -> load_config(), config)

    if isnothing(config.engine)
        @info "Starting pool of $pool_size testing engine(s)..."
        start_pool(config, pool_size)
    end

    try
        @testset verbose = true begin
            for package_dir in map(canonical, package_dirs)
                if !isdir(package_dir)
                    @warn "Package dir is not a directory: '$package_dir'"
                    continue
                end
                package = pkg_name(package_dir)

                @info "Running tests for package '$package'..."
                db = gen_safe_name(something(db_prefix, package))

                # TODO - we may want to move to with_deps = true when pkg is always installed
                try
                    prepare_package(package_dir, db, false; config=config)

                    @testset verbose = true "$package" begin
                        !skip_suites && run_package_suites(
                            package_dir,
                            db,
                            config=config,
                            skip_prepare=true,
                        )
                        !skip_testitems &&
                            has_julia_files(package_dir) &&
                            run_package_testitems(
                                package_dir,
                                db,
                                config=config,
                                skip_prepare=true,
                            )
                    end
                finally
                    # cleanup the db created by prepare_package
                    delete_db(db, config)
                end
            end
        end
    finally
        if isnothing(config.engine)
            @info "Stopping pool of testing engines..."
            stop_pool()
        end
    end
    return
end

"""
    test_package(
        package_dir::AbstractString,
        db_prefix::Union{AbstractString,Nothing}=nothing;
        skip_suites::Bool=false,
        skip_testitems::Bool=false,
        pool_size::Int=1,
        config::Union{Config,Nothing}=nothing,
    )

Run all tests in this package.

This is the same as `test_packages` but with a single package. It will run both Rel as well
as Julia tests (unless skipped).
"""
function test_package(
    package_dir::AbstractString,
    db_prefix::Union{AbstractString,Nothing}=nothing;
    skip_suites::Bool=false,
    skip_testitems::Bool=false,
    pool_size::Int=1,
    config::Union{Config,Nothing}=nothing,
)
    return test_packages(
        [package_dir],
        db_prefix,
        skip_suites=skip_suites,
        skip_testitems=skip_testitems,
        pool_size=pool_size,
        config=config,
    )
end

"""
    run_package_suites(
        package_dir::AbstractString,
        database::Union{AbstractString,Nothing}=nothing;
        config::Union{Config,Nothing}=nothing,
        skip_prepare::Bool=false,
    )

Run all the julia ReTestItems-based tests in this package_dir.

If `database` is set, it is used as the name of the database to use as a prototype,
otherwise we generate a database name based on the package name.

If `skip_prepare` is set, assume that `database` is already prepared. Otherwise, create a
database with this `database` name and install this `package`. Finally, run every Julia
test found in the package's `test` directory.
"""
function run_package_testitems(
    package_dir::AbstractString,
    database::Union{AbstractString,Nothing}=nothing;
    config::Union{Config,Nothing}=nothing,
    skip_prepare::Bool=false,
)
    package = pkg_name(package_dir)

    db = something(database, gen_safe_name(package))

    # TODO - we may want to move to with_deps = true when pkg is always installed
    !skip_prepare && prepare_package(package_dir, db, false; config=config)

    progress(package, "Running Julia package tests...")

    # make sure RAITest is properly configured
    RAITest.set_context!(get_some_context(or_else(() -> load_config(), config)))
    RAITest.set_clone_db!(db)
    !isnothing(config.engine) && RAITest.set_test_engine!(config.engine)

    try
        @testset RAITestSet "$package Julia tests" begin
            ReTestItems.runtests(joinpath(package_dir, "test"))
        end
    finally
        RAITest.set_clone_db!(nothing)
        RAITest.set_test_engine!(nothing)
        # cleanup the db created by prepare_package
        !skip_prepare && delete_db(db, config)
    end
end

"""
    run_package_suites(
        package_dir::AbstractString,
        database::Union{AbstractString,Nothing}=nothing;
        config::Union{Config,Nothing}=nothing,
        skip_prepare::Bool=false,
    )

Run all Rel test suites in this package.

If `database` is set, it is used as the name of the database to use be created for running
tests, otherwise we generate a database name based on the package name.

If `skip_prepare` is set, assume that `database` is already prepared. Otherwise, create a
database with this `database` name and install this `package`. Finally, run every Rel
suite found in the package's `test` directory.
"""
function run_package_suites(
    package_dir::AbstractString,
    database::Union{AbstractString,Nothing}=nothing;
    config::Union{Config,Nothing}=nothing,
    skip_prepare::Bool=false,
)
    if skip_prepare && isnothing(database)
        @error("Cannot skip package preparation without a database.")
        return
    end

    package = pkg_name(package_dir)
    progress(package, "Running Rel package tests...")

    suites = find_test_dirs(package_dir)
    if isempty(suites)
        progress(package, "No Rel test suites found under '$package' directory.")
        return
    end

    db = something(database, gen_safe_name(package))
    try
        # load default if needed
        config = or_else(() -> load_config(), config)

        # TODO - we may want to move to with_deps = true when pkg is always installed
        !skip_prepare && prepare_package(package_dir, db, false; config=config)

        progress(package, "Found $(length(suites)) suites: $suites")

        @testset verbose = true "$package Rel tests" begin
            cache = Dict{String,Vector{RAITest.Step}}()

            for suite in suites
                run_suite(suite, db; config=config)
            end
        end
    finally
        # cleanup the db created by prepare_package
        !skip_prepare && delete_db(db, config)
    end
    return
end

"""
    run_suite(
        suite_dir::AbstractString,
        prototype::AbstractString,
        database::AbstractString;
        config::Union{Config,Nothing}=nothing,
    )

Run all tests found in this suite_dir.

The `prototype` database must already contain the package (it can be created with
`prepare_package`).

If `database` is set, it is used as the name of the database to use be created for running
tests, otherwise we generate a database name based on the package name.

If `skip_prepare` is set, assume that `prototype` is already prepared for the suite, i.e.
`before-suite.rel` does not exist for the suite or was already executed in the prototype. In
this case, `database` is ignored and we simply execute all suite tests based on the
prototype.

If `skip_prepare` is not set, the `database` is created, but only the suite has a
`before-suite.rel` file, otherwise the `prototype` database will be used as a prototype
for tests.
"""
function run_suite(
    suite_dir::AbstractString,
    prototype::AbstractString,
    database::Union{AbstractString,Nothing}=nothing;
    config::Union{Config,Nothing}=nothing,
    skip_prepare::Bool=false,
)
    if skip_prepare && !isnothing(database)
        @warn("Ignoring `database` as it is incompatible with `skip_prepare`.")
    end

    suite = suite_name(suite_dir)
    test_files = find_test_files(suite_dir)
    if isempty(test_files)
        progress(suite, "No test files found under folder '$suite_dir'.")
        return
    end

    # load default if needed
    config = or_else(() -> load_config(), config)

    if skip_prepare
        db = prototype
    else
        # make sure we have a database name
        database = something(database, gen_safe_name(prototype))
        db = prepare_suite(suite_dir, prototype, database; config=config)
    end

    try
        @testset verbose = true "$suite" begin
            cache = Dict{String,Vector{RAITest.Step}}()

            for test_file in test_files
                run_test(joinpath(suite_dir, test_file), db; config=config, cache=cache)
            end
        end
    finally
        # cleanup the db created by prepare_suite
        if !skip_prepare && db == database
            progress(suite, "Deleting suite database '$database'...")
            delete_db(database, config)
        end
    end
    return
end

"""
    run_test(
        test_file::AbstractString,
        prototype::AbstractString;
        with_before_suite::Bool=false,
        config::Union{Config,Nothing}=nothing,
        cache=Dict{String,Vector{RAITest.Step}}(),
    )

Run a single test case on a clone of this `prototype`.

By default, this assumes `prepare_suite` was executed on the prototype database. If
`with_before_suite` is true, the `before-suite.rel` file for the test's suite is executed
as part of the test. This allows the execution of full tests, without having to prepare the
database for the suite.

The `cache` can be used to look up the parsed sources of `before-test.rel` and
`validate-test.rel` scripts, which can be reused across tests of the same suite.
"""
function run_test(
    test_file::AbstractString,
    prototype::AbstractString;
    with_before_suite::Bool=false,
    config::Union{Config,Nothing}=nothing,
    cache=Dict{String,Vector{RAITest.Step}}(),
)
    test = test_name(test_file)
    directory = dirname(test_file)
    test_steps = parse_steps(test_file)
    if isempty(test_steps)
        warn(test, "Test script '$test_file' is empty.")
        return
    end

    progress(test, "Running test with $(length(test_steps)) steps...")

    # load default if needed
    config = or_else(() -> load_config(), config)

    # make sure RAITest uses that config's context
    RAITest.set_context!(get_some_context(config))

    with_engine(config) do engine
        # not using the macro because we don't want to attach a location
        return RAITest.test_rel(
            name=string(test),
            steps=[
                if with_before_suite
                    get_steps(directory, "before-suite.rel", cache)
                else
                    RAITest.Step[]
                end
                get_steps(directory, "before-test.rel", cache)
                test_steps
                get_steps(directory, "validate-test.rel", cache)
            ],
            clone_db=prototype,
            engine=engine,
        )
    end
    return
end

"""
    install_package(
        package_dir::AbstractString,
        database::AbstractString,
        with_deps::Bool=false;
        config::Union{Config,Nothing}=nothing,
    )

Install the package found in this `package_dir` directory in this `database`.

If `with_deps` is true, the code to install the package will also emit package manager
instructions to install the package's dependencies. This assumes that the package manager is
already installed in the database.
"""
function install_package(
    package_dir::AbstractString,
    database::AbstractString,
    with_deps::Bool=false;
    config::Union{Config,Nothing}=nothing,
)
    package = pkg_name(package_dir)
    progress(package, "Installing package sources on '$(database)'...")

    # load default if needed
    config = or_else(() -> load_config(), config)

    # load metadata
    rel_package = load_rel_package(package_dir)

    if !haskey(rel_package, "models")
        progress(package, "Package does not have models to install.")
        return true
    end

    # generate code based on the metadata description of the package
    code, inputs = generate_install_package_code(package_dir, rel_package, with_deps)

    # install the code and inputs in the database
    return with_engine(config) do engine
        return execute_transaction(code, database, engine, config; inputs=inputs)
    end
end

"""
    prepare_package(
        package_dir::AbstractString,
        database::AbstractString,
        with_deps::Bool=false;
        config::Union{Config,Nothing}=nothing,
    )

Prepare a `database` to run tests in this `package_dir`.

Create a new database with this name, then install the package sources, and execute the
`before-package.rel` script for the package, if it exists.
"""
function prepare_package(
    package_dir::AbstractString,
    database::AbstractString,
    with_deps::Bool=false;
    config::Union{Config,Nothing}=nothing,
)

    # load default if needed
    config = or_else(() -> load_config(), config)

    # create the database
    create_db(database, config)

    # install the package sources
    !install_package(package_dir, database, with_deps; config=config) &&
        error("Installation of package in '$package_dir' failed.")

    # potentially run its before-package.rel script
    blocks = parse_source_file(package_dir, joinpath("test", "before-package.rel"))
    if !isempty(blocks)
        ctx = "$(pkg_name(package_dir))/before-package"
        progress(ctx, "Processing 'before-package.rel'...")
        with_engine(config) do engine
            return !execute_blocks(ctx, blocks, database, engine, config) &&
                   error("Processing of 'before-package.rel' failed.")
        end
    end
    return
end

"""
    prepare_suite(
        suite_dir::AbstractString,
        prototype::AbstractString,
        database::Union{AbstractString,Nothing}=nothing;
        config::Union{Config,Nothing}=nothing,
    )

Prepare a `database` to run tests in this `suite_dir`.

Assumes `prepare_package` was executed on the `prototype` database.

If `database` is nothing, a name for the database is generated based on the `prototype`.

If the suite has a `before-suite.rel`, the `prototype` will be cloned into `database` and the
script will be executed in `database`. Otherwise, `prototype` can be used right away.

The function returns the name of the database to be used as a prototype for the suite: the
`database` if there's a `before-suite.rel` or the `prototype` otherwise.
"""
function prepare_suite(
    suite_dir::AbstractString,
    prototype::AbstractString,
    database::Union{AbstractString,Nothing}=nothing;
    config::Union{Config,Nothing}=nothing,
)
    # only need to prepare the suite if there's a before-suite.rel file
    blocks = parse_source_file(suite_dir, "before-suite.rel")

    # no need to clone, so use the prototype database
    # this is actually required because we can't clone a database that never had a txn,
    # so if we just clone prototype into database, database itself won't be able to be
    # cloned by test cases
    isempty(blocks) && return prototype

    db = something(database, gen_safe_name(prototype))
    suite = suite_name(suite_dir)
    progress(suite, "Cloning '$prototype' into '$(db)'...")

    # load default if needed
    config = or_else(() -> load_config(), config)

    # clone the prototype db into target db
    clone_db(prototype, db, config)

    progress(suite, "Processing 'before-suite.rel'...")
    with_engine(config) do engine
        return !execute_blocks("$suite/before-suite", blocks, db, engine, config) &&
            error("Processing of 'before-suite.rel' failed.")
    end

    # tell caller to use the database clone
    return db
end

"""
    run_script(
        script_file::AbstractString,
        database::AbstractString;
        config::Union{Config,Nothing}=nothing,
    )

Run the blocks in this `script_file` on this `database`.

The script file will be parsed in CodeBlocks, and each block will be executed as its own
transaction.
"""
function run_script(
    script_file::AbstractString,
    database::AbstractString;
    config::Union{Config,Nothing}=nothing,
)
    if !isfile(script_file)
        @warn "'$script_file' is not a file."
        return false
    end

    # load default if needed
    config = or_else(() -> load_config(), config)

    with_engine(config) do engine
        return execute_blocks(
            unix_basename(script_file),
            parse_code_blocks(script_file),
            database,
            engine,
            config,
        )
    end
end

"""
    start_pool(config::Union{Config,Nothing}=nothing, size::Int=1)

Start a testing engine pool with this size.

This may take a while because it will provision `size` engines. Make sure to call
`stop_pool()` to unprovision the engines.
"""
function start_pool(config::Union{Config,Nothing}=nothing, size::Int=1)
    # load default if needed
    config = or_else(() -> load_config(), config)

    RAITest.set_engine_creater!(function (name::String)
        # Default is to use an XS engine
        RAI.create_engine(config.context, name; size="S")
        return RAITest._wait_till_provisioned(name, 600)
    end)
    return RAITest.resize_test_engine_pool!(size, id -> gen_safe_name("RAIRelTest"))
end

"""
    stop_pool()

Stop the testing engine pool, unprovisioning the engines.
"""
function stop_pool()
    return RAITest.destroy_test_engines!()
end
