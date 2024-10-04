
module CLI

using RAIRelTest
using ArgParse

"""
Execute the command line interface with arguments passed from the command line.
"""
main() = cli(ARGS)

"""
Execute the command line interface with these arguments.
"""
cli(args::AbstractString) = cli(split(args))

"""
Execute the command line interface with these arguments.
"""
function cli(args::Vector{T}) where {T<:AbstractString}
    parsed_args = parse_arguments(args)
    @debug "Parsed arguments" parsed_args

    # load the config, given a profile
    config = RAIRelTest.load_config(filter(kv -> !isnothing(kv[2]), parsed_args))
    @debug "Configuration" config

    command = parsed_args[:_COMMAND_]

    try
        if command == :test_package
            RAIRelTest.test_packages(
                parsed_args[:test_package][:package],
                parsed_args[:test_package][:database],
                skip_suites=parsed_args[:test_package][:skip_suites],
                skip_testitems=parsed_args[:test_package][:skip_testitems],
                pool_size=parsed_args[:pool_size],
                engine_size=parsed_args[:engine_size],
                raicode_commit=parsed_args[:raicode_commit],
                config=config,
                changes=parsed_args[:test_package][:changes]
            )
        elseif command == :run_suite
            RAIRelTest.run_suite(
                parsed_args[:run_suite][:suite],
                parsed_args[:run_suite][:prototype],
                config=config,
            )
        elseif command == :run_test
            RAIRelTest.run_test(
                parsed_args[:run_test][:script],
                parsed_args[:run_test][:prototype],
                config=config,
            )
        elseif command == :install_package
            RAIRelTest.install_package(
                parsed_args[:install_package][:package],
                parsed_args[:install_package][:database],
                parsed_args[:install_package][:with_deps],
                config=config,
            )
        elseif command == :prepare_package
            RAIRelTest.prepare_package(
                parsed_args[:prepare_package][:package],
                parsed_args[:prepare_package][:database],
                false, # parsed_args[:prepare_package][:with_deps],
                config=config,
            )
        elseif command == :prepare_suite
            target = something(
                parsed_args[:prepare_suite][:database],
                "$(parsed_args[:prepare_suite][:prototype])-$(RAIRelTest.unix_basename(parsed_args[:prepare_suite][:suite]))",
            )
            RAIRelTest.prepare_suite(
                parsed_args[:prepare_suite][:suite],
                parsed_args[:prepare_suite][:prototype],
                target,
                config=config,
            )
        elseif command == :run_script
            result = RAIRelTest.run_script(
                parsed_args[:run_script][:script],
                parsed_args[:run_script][:database],
                config=config,
            )
        elseif command == :repl
            @warn "repl command is implemented elsewhere."
            return 1
        end

        return 0
    catch e
        if e isa ErrorException
            @error e.msg
        else
            @error e
        end
        rethrow()
    end
end

function parse_arguments(args::Vector{T}) where {T<:AbstractString}
    s = ArgParse.ArgParseSettings(
        prog="rel_pkg_test",
        version=RAIRelTest.VERSION,
        add_version=true,
        add_help=true,
    )

    ArgParse.@add_arg_table! s begin
        "--engine", "-e"
        help = "The name of the engine to use for Rel tests (defaults to RAI_ENGINE or using a pool of engines)."
        arg_type = String
        "--pool_size"
        help = "The number of engines to create to run the tests (defaults to 1)."
        default = 1
        arg_type = Int
        "--engine_size"
        help = "The size of engines to create if a pool is used (defaults to S)."
        default = "S"
        arg_type = String
        "--raicode_commit"
        help = "The commit SHA of a RAICode build to be used when creating pool engines."
        arg_type = String
        "--profile"
        help = "The .rai/config profile to use when accessing engines and databases (defaults to 'default')."
        arg_type = String
        default = "default"
        "test_package"
        action = :command
        help =
            "Run all test suites for the packages. This will create a database, " *
            "prepare the package and then run all test suites for the package."
        "run_suite"
        action = :command
        help =
            "Run a single Rel test suite. This will 'prepare_suite' and then run all tests " *
            "in the suite directory. Assumes 'prepare_package' created the prototype " *
            "database."
        "run_test"
        action = :command
        help =
            "Run a single Rel test script. This will clone the database, run the " *
            "'before-test.rel' script, run the test script, and then run the " *
            "'validate-test.rel' script."
        "install_package"
        action = :command
        help =
            "Install or re-install the prototypes of a package in a database. The models " *
            "listed in 'rel-package.json' will be loaded and any previously loaded " *
            "models in the package namespace will be removed."
        "prepare_package"
        action = :command
        help =
            "Prepare a database for running package tests. This will create a " *
            "database, install the package, and run the 'post-install.rel' script."
        "prepare_suite"
        action = :command
        help =
            "Prepare a database for running a test suite. This will clone the " *
            "prototype database and run the 'before-test.rel' script in the clone. " *
            "Assumes 'prepare_package' created the prototype database."
        "run_script"
        action = :command
        help = "Split a Rel script into sections and run as transactions on a database."
        "repl"
        action = :command
        help = "Enter the Julia REPL with the RAIRelTest project configured."
    end

    ArgParse.@add_arg_table! s["test_package"] begin
        "package"
        nargs = '*'
        help = "The directory of the package whose tests are to be run."
        arg_type = String
        required = true
        "--database", "-d"
        help = "The basename of the database that will be created for the tests. Defaults to a generated name."
        arg_type = String
        "--skip_suites"
        help = "Skip the execution of rel-based test cases (rel_pkg_test tests)."
        action = :store_true
        "--skip_testitems"
        help = "Skip the execution of julia-based test cases (ReTestItem tests)."
        action = :store_true
        "--changes"
        help = "List of files in the package which changed, to select only affected tests."
        nargs = '*'
        arg_type = String
    end

    ArgParse.@add_arg_table! s["run_suite"] begin
        "suite"
        help = "The directory with the test suite to run."
        arg_type = String
        required = true
        "prototype"
        help =
            "The name of a database to be cloned when running the suite tests. This should contain " *
            "the results of prepare_package."
        arg_type = String
        required = true
    end

    ArgParse.@add_arg_table! s["run_test"] begin
        "script"
        help = "The path to the test script to run."
        arg_type = String
        required = true
        "prototype"
        help = "The name of the database to be cloned when running tests."
        arg_type = String
        required = true
    end

    ArgParse.@add_arg_table! s["install_package"] begin
        "package"
        help = "The directory with the Rel package to install."
        arg_type = String
        required = true
        "database"
        help = "The database where the package will be installed."
        arg_type = String
        required = true
        "--with_deps"
        help = "Also install the package dependencies (assumes package manager is already installed)."
        action = :store_true
    end

    ArgParse.@add_arg_table! s["prepare_package"] begin
        "package"
        help = "The directory with the Rel package to install."
        arg_type = String
        required = true
        "database"
        help = "The name of the database to be created, where the package will be prepared."
        arg_type = String
        required = true
    end

    ArgParse.@add_arg_table! s["prepare_suite"] begin
        "suite"
        help = "The directory with the test suite to prepare for running."
        arg_type = String
        required = true
        "prototype"
        help = "The name of the database to be cloned. Assumes it was created with 'prepare_package'."
        arg_type = String
        required = true
        "--database", "-d"
        help =
            "The name of the database to be created, where the suite will be prepared. By default, " *
            "append the suite basename to the prototype database."
        arg_type = String
    end

    ArgParse.@add_arg_table! s["run_script"] begin
        "script"
        help = "The path to the Rel script to run."
        arg_type = String
        required = true
        "database"
        help = "The name of the database to where to run the script."
        required = true
    end

    return ArgParse.parse_args(args, s, as_symbols=true)
end

export main, cli

end # module
