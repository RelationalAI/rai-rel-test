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
    basename = unix_basename(canonical(directory))
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
function create_random_db(basename::AbstractString, config::Union{Config,Nothing}=nothing)
    config = or_else(() -> load_config(), config)
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
function create_db(database::AbstractString, config::Union{Config,Nothing}=nothing)
    config = or_else(() -> load_config(), config)
    try
        result = RAI.create_database(config.context, database)
        if result["database"]["state"] == "CREATED"
            return result["database"]["name"]
        end
        error("Failed to create database $(database): $result")
    catch e
        if e isa RAI.HTTPError && e.status_code == 409
            error("Database $(database) already exists")
        else
            rethrow()
        end
    end
end

"""
Clone the database db and return the name of the new database
"""
function clone_db(source::AbstractString, target::AbstractString, config::Union{Config,Nothing}=nothing)
    config = or_else(() -> load_config(), config)
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
function delete_db(database::AbstractString, config::Union{Config,Nothing}=nothing)
    config = or_else(() -> load_config(), config)
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
        input = "_input_" * replace(name, r"/|-" => "_") * "_"

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

"""
Generate an `RBF.LoadModel` action to install this package.
"""
function generate_rbf_load_model(package_dir::AbstractString, rel_package)
    files = Vector{String}()
    names = Vector{String}()

    for model in rel_package["models"]
        !haskey(model, "name") &&
            error("Invalid 'models' entry: field 'name' is mandatory.")
        name = model["name"]
        model_file = joinpath(
            package_dir,
            (haskey(model, "file") ? model["file"] : joinpath("model", name * ".rel")),
        )
        !isfile(model_file) && error("Cannot find model file $model_file.")

        push!(files, model_file)
        push!(names, name)
    end

    return RBF.LoadModel(
        name = "install_package",
        model_name = names,
        rel = files,
    )
end

#
# Managing test scripts
#

"""
A code block is a section of a file that represents code to execute as a standalone
transaction, and includes expectations regarding the results.
"""
struct CodeBlock
    # if name is not set, generate a step name by appending a counter to the basename
    basename::String
    code::String
    # explicitly set name for the block
    name::Union{String,Nothing}
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
    if !isfile(source_file)
        return CodeBlock[]
    end

    basename = (unix_basename(source_file))[1:end-4]
    code = readlines(source_file)

    return parse_code_blocks(dirname(source_file), basename, code)
end

"""
    parse_code_blocks(
        cwd::AbstractString,
        basename::AbstractString,
        code::Vector{T}
    ) where T <:AbstractString

Translate a string vector of Rel queries into a series of code blocks suitable for direct
execution. The basename parameter indicates the basename to use for the blocks, and the cwd
parameter represents the current working directory from where to load files if there are any
load directives.
"""
function parse_code_blocks(
        cwd::AbstractString,
        basename::AbstractString,
        code::Vector{T}
    ) where T <:AbstractString

    blocks = CodeBlock[]
    src = ""
    write = false
    expect_warnings = false
    expect_errors = false
    expect_abort = false
    name = nothing
    for line in code
        if startswith(line, "// %%")
            if !isempty(src) && !all_comments(src)
                block = CodeBlock(
                    basename,
                    src,
                    name,
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
            if contains(line, "name")
                name = match(r"name=\"(.*?)\"", line).captures[1]
            else
                name = nothing
            end
            if contains(line, "load")
                m = match(r"load=\"(.*?)\"", line)
                if !isnothing(m)
                    filename = joinpath(cwd, m.captures[1])
                    if !isfile(filename)
                        error("$(basename): 'load' directive poinst to a file that was not found: $(filename)")
                    end
                    src = read(filename, String)
                end
            end
            continue
        end
        src *= line
        src *= "\n"
    end
    src = strip(src)
    if !isempty(src) && !all_comments(src)
        block = CodeBlock(
            basename,
            string(src),
            name,
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
        name = (length(blocks) > 1 ? "$counter - " : "") * something(block.name, block.basename)
        step = RAITest.Step(;
            query = block.code,
            name,
            readonly = !block.write,
            allow_unexpected = if block.expect_errors
                :errors
            elseif block.expect_warnings
                :warning
            else
                :none
            end,
            expect_abort = block.expect_abort,
        )
        push!(steps, step)
        counter += 1
    end
    return steps
end


# Translate from `CodeBlock`s and into `RBF.Action`s.
function code_blocks_to_rbf_actions(blocks::Vector{CodeBlock})
    counter = 1
    actions = RBF.AbstractRelQuery[]
    for block in blocks
        name = block.basename * (length(blocks) > 1 ? "-$counter" : "")
        # RBF should throw an exception on abort or errors if we are not expecting them
        throw_exception = !block.expect_abort && !block.expect_errors
        action = if block.write
            RBF.WriteQuery(
                name = name,
                rel = block.code,
                throw_exception = throw_exception
            )
        else
            RBF.ReadQuery(
                name,
                rel=block.code,
                throw_exception=throw_exception
            )
        end
        push!(actions, action)
        counter += 1
    end
    return actions
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
    rsp = RAI.exec(config.context, database, engine, code; inputs, readonly, readtimeout)

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
function find_test_dirs(base_dirs::Vector{T}; filter::Union{Function,Nothing}=nothing) where {T<:AbstractString}
    test_dirs = Set{String}()
    for base_dir in base_dirs
        union!(test_dirs, find_test_dirs(base_dir, filter=filter))
    end
    return sort!([test_dirs...])
end

"""
Find all directories under `base_dir` that have Rel test suites.
"""
function find_test_dirs(base_dir::AbstractString="."; filter::Union{Function,Nothing}=nothing)
    isfile(base_dir) && return find_test_dirs(dirname(base_dir))
    test_dirs = Set{String}()
    for (root, _, files) in walkdir(base_dir)
        for file in files
            if startswith(file, "test-") && endswith(file, ".rel")
                push!(test_dirs, root)
            end
        end
    end

    !isnothing(filter) && filter!(filter, test_dirs)

    return sort!([test_dirs...])
end

"""
Given a list of changed files (e.g. from a diff between git branches), return a set of
filters (namespace names) that can be used to filter test_dirs to return only suites
affected by those file changes.

This is useful, for example, to run only the test suites that were impacted by a PR, instead
of having to run them all.
"""
function get_diff_filters(changes::Vector{T}) where {T<:AbstractString}
    filters = Set{String}()
    for match in changes
        # model/std/common.rel -> std/common
        if startswith(match, "model/") && endswith(match, ".rel")
            push!(filters, match[7:end-4])
        end
        # test/std/common/test-foo.rel -> std/common
        if startswith(match, "test/") && endswith(match, ".rel") && occursin("test-", match)
            push!(filters, match[6:findlast('/', match)-1])
        end
    end
    return filters
end

"""
Given a set of filters returned by get_diff_filters, return a function that, given a name,
will check if the name occurs in any of those filters.
"""
function make_diff_filter(filters::Set{String})
    return (test_dir -> isempty(filters) || any(filter -> occursin(filter, test_dir), filters))
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

function find_package_dir(path::AbstractString)
    !ispath(path) && return
    dir = dirname(realpath(path))
    dir == path && return
    has_rel_package_json(dir) && return dir
    return find_package_dir(dir)
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

function has_rel_package_json(directory::AbstractString)
    return ! isempty(filter(x -> x == "rel-package.json", readdir(directory)))
end

function has_rel_or_jl_name(names::Vector{T}) where {T<:AbstractString}
    any(x -> endswith(x, ".jl") || endswith(x, ".rel"), names)
end
