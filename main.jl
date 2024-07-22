#!/usr/bin/env julia

# Assume that the current working directory is the root of the project
using Pkg
Pkg.activate(@__DIR__)

# Ensure ReTestItems is loaded in the top-level scope
Pkg.instantiate()
using ReTestItems

# Set the prefix for @test_rel databases, if it's not in ENV
get!(ENV, "TEST_REL_DB_NAME", "RAIRelTest")

# Load the CLI module and process the command line arguments
using RAIRelTest: CLI
CLI.main()
