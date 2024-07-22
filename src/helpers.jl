
using Random: MersenneTwister
using UUIDs
using JSON3

import RAI
import RAITest
using Test

#
# Naming and logging
#

"""
Generate a safe name for a database by appending a random value to the basename
"""
function gen_safe_name(basename::String)
    return "$(basename)-$(last(string(UUIDs.uuid4(MersenneTwister())), 12))"
end

"""
Emit @info with this message in this context.
"""
function progress(ctx::AbstractString, msg::AbstractString)
    @info "$(Dates.now()) [$ctx] $msg"
end

"""
Emit @warn with this message in this context.
"""
function warn(ctx::AbstractString, msg::AbstractString)
    @warn "$(Dates.now()) [$ctx] $msg"
end

"""
Return the basename of this path, according to unix's basename semantics.

The main difference is that a trailing separator is ignored in unix, so
basename("foo/bar/baz/") is "" whereas unix_basename is "baz".
"""
function unix_basename(path::AbstractString)
    return last(splitpath(path))
end

"""
Try to resolve the path, and then make sure trailing separator is removed from it.
"""
function canonical(path::AbstractString)
    try
        # attempt to resolve the path to the filesystem
        path = realpath(path)
    catch
        # ignore and use the incoming string anyway
    end
    return joinpath(splitpath(path))
end

"""
Assuming the convention that packages live in directories called \$(pkgname)-rel, this
extracts the package name from a directory name, which can include a prefix.
"""
function pkg_name(directory::AbstractString)
    basename = unix_basename(directory)
    endswith(basename, "-rel") && return unix_basename(basename)[1:end-4]
    return basename
end

"""
Get the name of the suite in this directory.

If there is a `/test/` directory, the suite name is the path after that, otherwise return
the canonical directory name.
"""
function suite_name(directory::AbstractString)
    parts = split(directory, "/test/")
    length(parts) > 1 && return canonical(last(parts))
    return unix_basename(directory)
end

"""
Get the name of the test in this rel file.

This is name of the suite + / + the filename.
"""
function test_name(file::AbstractString)
    endswith(file, ".rel") && return suite_name(file)[1:end-4]
    return suite_name(file)
end

#
# Database Handling (process the result from the sdk properly).
#

"""
Create an empty database using a random name based on this basename.
"""
function create_random_db(basename::AbstractString, config::Config)
    name = gen_safe_name(basename)
    try
        result = RAI.create_database(config.context, name)
        if result["database"]["state"] == "CREATED"
            return result["database"]["name"]
        end
        error("Failed to create database $name: $result")
    catch e
        if e isa RAI.HTTPError && e.status_code == 409
            error("Database $name already exists")
        else
            rethrow()
        end
    end
end

"""
Create a database with this name.
"""
function create_db(database::AbstractString, config::Config)
    try
        result = RAI.create_database(config.context, database)
        if result["database"]["state"] == "CREATED"
            return result["database"]["name"]
        end
        error("Failed to create database $(config.database): $result")
    catch e
        if e isa RAI.HTTPError && e.status_code == 409
            error("Database $(config.database) already exists")
        else
            rethrow()
        end
    end
end

"""
Clone the database db and return the name of the new database
"""
function clone_db(source::AbstractString, target::AbstractString, config::Config)
    try
        result = RAI.create_database(config.context, target, source=source)
        @debug result
        if result["database"]["state"] == "CREATED"
            return result["database"]["name"]
        end
        error("Failed to clone database $source to $target", result)
    catch e
        @error "Failed to clone database $source to $target"
        if e isa RAI.HTTPError && e.status_code == 409
            error("Database $target already exists")
        elseif e isa RAI.HTTPError && e.status_code == 404
            error("Database $source does not exist")
        end
        rethrow(e)
    end
end

"""
Delete the database with this name.
"""
function delete_db(database::AbstractString, config::Config)
    try
        RAI.delete_database(config.context, database)
    catch e
        @error "Could not delete database '$(database)':", e
    end
end

#
# Package metadata
#

"""
Load the `rel-package.json` file in the directory identified by this `package_dir`; return
the resulting parsed JSON.
"""
function load_rel_package(package_dir::AbstractString)
    metadata_file = "$package_dir/rel-package.json"
    if !isfile(metadata_file)
        error("Package metadata file '$metadata_file' does not exist.")
    end

    return JSON3.read(metadata_file)
end

"""
Generate Rel code to install this package.

The `rel_package` argument is the structure extracted from JSON with `load_rel_package`.

If `with_deps` is true, the generated code will contain package manager instructions to
install the packages this package depends on. Therefore, this assumes the package manager is
already installed in the database prior to running this code.
"""
function generate_install_package_code(
    package_dir::AbstractString,
    rel_package,
    with_deps::Bool=false,
)
    # generate code and inputs
    code = IOBuffer()
    inputs = Dict{String,String}()

    for model in rel_package["models"]
        !haskey(model, "name") &&
            error("Invalid 'models' entry: field 'name' is mandatory.")
        name = model["name"]
        input = "_input_" * replace(name, "/" => "_") * "_"

        model_file = joinpath(
            package_dir,
            (haskey(model, "file") ? model["file"] : joinpath("model", name * ".rel")),
        )
        !isfile(model_file) && error("Cannot find model file $model_file.")

        inputs[input] = read(model_file, String)
        print(
            code,
            """
    def insert[:rel, :catalog, :model] {("$name", $(input))}
    def delete[:rel, :catalog, :model] {("$name", ::rel[:catalog, :model, "$name"])}
""",
        )
    end

    if with_deps
        descriptors = Vector{String}()
        for dep in rel_package["dependencies"]
            !haskey(dep, "range") &&
                error("Invalid 'dependencies' entry: field 'range' is mandatory.")
            !haskey(dep, "package") &&
                error("Invalid 'dependencies' entry: field 'package' is mandatory.")
            !haskey(dep["package"], "name") &&
                error("Invalid 'dependencies/package' entry: field 'name' is mandatory.")
            !haskey(dep["package"], "uuid") &&
                error("Invalid 'dependencies/package' entry: field 'uuid' is mandatory.")

            # TODO: change to using `package/uuid` when that is supported by project::add_package
            push!(descriptors, "\"$(dep["package"]["name"])@$(dep["range"])\"")
        end
        if !isempty(descriptors)
            print(
                code,
                """
        def dependencies { ::std::pkg::project::add_package[{$(join(descriptors, ";"))}] }
        def insert { dependencies[:insert] }
        def delete { dependencies[:delete] }
    """,
            )
        end
    end

    return (String(take!(code)), inputs)
end

#
# Managing test scripts
#

"""
A code block is a section of a file that represents code to execute as a standalone
transaction, and includes expectations regarding the results.
"""
struct CodeBlock
    basename::AbstractString
    code::AbstractString
    write::Bool
    expect_warnings::Bool
    expect_errors::Bool
    expect_abort::Bool
end

"""
    parse_source_file(directory::AbstractString, filename::AbstractString) -> Vector{CodeBlock}

Parse the file in this path, returning the resulting blocks. If the file does not exist,
returns an empty vector.
"""
function parse_source_file(directory::AbstractString, filename::AbstractString)
    path = joinpath(directory, filename)
    isfile(path) && return parse_code_blocks(path)
    return []
end

"""
    parse_code_blocks(source_file::AbstractString) -> Vector{CodeBlock}

Translate a file of Rel queries into a series of code blocks suitable for direct execution.
"""
function parse_code_blocks(source_file::AbstractString)
    blocks = CodeBlock[]
    if !isfile(source_file)
        return blocks
    end

    name = (unix_basename(source_file))[1:end-4]
    lines = readlines(source_file)
    src = ""
    write = false
    expect_warnings = false
    expect_errors = false
    expect_abort = false
    for line in lines
        if startswith(line, "// %%")
            if !isempty(src) && !all_comments(src)
                block = CodeBlock(
                    name,
                    src,
                    write,
                    expect_warnings,
                    expect_errors,
                    expect_abort,
                )
                push!(blocks, block)
                src = ""
            end
            # reset flags
            write = contains(line, "write")
            expect_warnings = contains(line, "warnings")
            expect_errors = contains(line, "errors")
            expect_abort = contains(line, "abort")
            continue
        end
        src *= line
        src *= "\n"
    end
    src = strip(src)
    if !isempty(src) && !all_comments(src)
        block = CodeBlock(
            name,
            string(src),
            write,
            expect_warnings,
            expect_errors,
            expect_abort,
        )
        push!(blocks, block)
    end

    return blocks
end

# Check if all lines in a string are comments or empty.
function all_comments(line::AbstractString)
    return all(line -> (startswith(line, "//") || isempty(line)), split(line, "\n"))
end

"""
Get the steps for the file with this `filename` in this `directory`, taking it from the
cache if it's there. If not in the cache, parse the file and store in the cache before
returning.
"""
function get_steps(
    directory::AbstractString,
    filename::AbstractString,
    cache::Dict{String,Vector{RAITest.Step}},
)
    path = joinpath(directory, filename)
    haskey(cache, path) && return cache[path]
    steps = parse_steps(path)
    cache[path] = steps
    return steps
end

"""
    parse_steps(source_path::AbstractString) -> Vector{RAITest.Step}

Parse the `source_path` as `CodeBlock`s and then translate into `RAITest.Step`s.
"""
function parse_steps(source_path::AbstractString)
    return code_blocks_to_steps(parse_code_blocks(source_path))
end

# Translate from `CodeBlock`s and into `RAITest.Step`s.
function code_blocks_to_steps(blocks::Vector{CodeBlock})
    counter = 1
    steps = RAITest.Step[]
    for block in blocks
        name = block.basename * (length(blocks) > 1 ? "-$counter" : "")
        step = RAITest.Step(;
            query=block.code,
            name,
            readonly=!block.write,
            allow_unexpected=if block.expect_errors
                :errors
            elseif block.expect_warnings
                :warning
            else
                :none
            end,
            expect_abort=block.expect_abort,
        )
        push!(steps, step)
        counter += 1
    end
    return steps
end

#
# Executing transactions
#

"""
Execute a transaction with this code and optional inputs, and process the response for any
errors.
"""
function execute_transaction(
    code::AbstractString,
    database::AbstractString,
    engine::AbstractString,
    config::Config;
    inputs=nothing,
    readonly=false,
)
    readtimeout = 1800
    rsp = RAI.exec(config.context, database, engine, code; inputs, readtimeout)

    aborted = rsp.transaction.state == "ABORTED"
    if aborted
        for row in rsp.results
            if contains(row[1], ":code")
                @warn "Error code: $(row[2][end])"
            elseif contains(row[1], ":message")
                @warn "Error message: $(row[2][end])"
            end
        end
        error("Failed to execute transaction.")
    end
    errored = any(p -> p.type != "IntegrityConstraintViolation" && p.is_error, rsp.problems)
    if errored
        error("Failed to execute transaction: $(rsp.problems)")
    end

    return true
end

"""
Execute a series of transactions, one for each code block in `blocks`.

The `ctx` is only used for logging progress.
"""
function execute_blocks(
    ctx::AbstractString,
    blocks::Vector{CodeBlock},
    database::AbstractString,
    engine::AbstractString,
    config::Config,
)
    count = length(blocks)
    if count == 0
        @warn "Nothing to execute."
        return true
    end

    progress(ctx, "Executing $count transaction(s)...")

    result = true
    i = 1
    for block in blocks
        progress(ctx, "Executing transaction $i/$count...")
        result = execute_block(ctx, block, database, engine, config)
        if !result
            break
        end
        i += 1
    end
    return result
end

"""
Execute a transaction for this `block`.

The `ctx` is only used for logging progress.
"""
function execute_block(
    ctx::AbstractString,
    block::CodeBlock,
    database::AbstractString,
    engine::AbstractString,
    config::Config,
)
    readonly = !block.write
    readtimeout = 1800
    rsp = RAI.exec(config.context, database, engine, block.code; readonly, readtimeout)

    # TODO - perhaps support displaying the output, if any

    # Only error for error-level problems
    errored = any(p -> p.type != "IntegrityConstraintViolation" && p.is_error, rsp.problems)
    aborted = rsp.transaction.state == "ABORTED"
    if (!block.expect_errors && errored) || (!block.expect_abort && aborted)
        source = block.code
        state = rsp.transaction.state
        # TODO - this will need updating when the deprecation turns into removal
        problems = rsp.problems
        @info ctx "Executed script" state source problems
    end
    if !block.expect_abort && aborted
        for row in rsp.results
            if contains(row[1], ":code")
                warn(ctx, "Error code: $(row[2][end])")
            elseif contains(row[1], ":message")
                warn(ctx, "Error message: $(row[2][end])")
            end
        end
    end
    @test block.expect_abort == aborted
    if !block.expect_errors
        # This will need updating when the deprecation turns into removal
        @test block.expect_errors == errored
    end
    return !((!block.expect_errors && errored) || (!block.expect_abort && aborted))
end

#
# Test engine pool
#

"""
Execute function f ensuring there is an engine.

If the config has an engine configured, it will be used. Otherwise, we try to acquire one
from the test engine pool, execute the function and release the engine afterwards.
"""
function with_engine(f::Function, config::Config)
    engine = config.engine
    if isnothing(engine)
        try
            engine = RAITest.get_test_engine()
        catch e
            if e isa ErrorException
                @error "Exception while attempting to get a test engine. Starting an engine " *
                       "pool with start_pool() or configuring an engine may solve the problem."
            end
            rethrow()
        end
        try
            return f(engine)
        finally
            RAITest.release_test_engine(engine)
        end
    else
        return f(engine)
    end
end

"""
Start a testing engine pool, then execute function f() and then stop the pool.
"""
function with_pool(f::Function, config::Config)
    start_pool(config)
    try
        return f()
    finally
        stop_pool()
    end
end

#
# Filesystem functions
#

"""
Find all directories under `base_dirs` that have Rel test suites.
"""
function find_test_dirs(base_dirs::Vector{T}) where {T<:AbstractString}
    test_dirs = Set{String}()
    for base_dir in base_dirs
        union!(test_dirs, find_test_dirs(base_dir))
    end
    return sort!([test_dirs...])
end

"""
Find all directories under `base_dir` that have Rel test suites.
"""
function find_test_dirs(base_dir::AbstractString=".")
    isfile(base_dir) && return find_test_dirs(dirname(base_dir))
    test_dirs = Set{String}()
    for (root, _, files) in walkdir(base_dir)
        for file in files
            if startswith(file, "test-") && endswith(file, ".rel")
                push!(test_dirs, root)
            end
        end
    end

    return sort!([test_dirs...])
end

# Find the nearest directory containing test-*.rel files
# Search dirname(path) if no tests are found
function find_nearest_test_dirs(path::AbstractString)
    !ispath(path) && return Set{String}()
    isfile(path) && return find_nearest_test_dirs(dirname(path))

    test_dirs = find_test_dirs(path)
    if isempty(test_dirs)
        return find_nearest_test_dirs(dirname(path))
    end
    return test_dirs
end

function find_nearest_test_dirs(paths::Vector{T}) where {T<:AbstractString}
    test_dirs = Set{String}()
    for path in paths
        union!(test_dirs, find_nearest_test_dirs(path))
    end
    return sort!([test_dirs...])
end

"""
Find all files in this `directory` that are Rel test files.
"""
function find_test_files(directory::AbstractString)
    return filter(x -> startswith(x, "test-") && endswith(x, ".rel"), readdir(directory))
end

"""
True if at least one package has at least one julia file
"""
function has_julia_files(directories::Vector{T}) where {T<:AbstractString}
    return any(dir -> has_julia_files(dir), directories)
end

"""
True if the directory has at least one julia file
"""
function has_julia_files(directory::AbstractString)
    for (_, _, files) in walkdir(directory, topdown=false)
        any(x -> endswith(x, ".jl"), files) && return true
    end
    return false
end
