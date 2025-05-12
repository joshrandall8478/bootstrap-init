# All arguments will be passed as positional arguments.
set positional-arguments := true
# Use Nushell for all shells
set shell := ['nu', '--no-config-file', '--commands']
# The export setting causes all just variables to be exported as environment variables. Defaults to false.
set export := true

# Cheat Sheet: https://cheatography.com/linux-china/cheat-sheets/justfile/
# @ => suppress printing commands to standard error.
# set fallback => Look in parent directories for a Justfile with the recipe.
# justfile() => Path of the current Justfile.
# justfile_directory() => Parent directory of the current Justfile.
# invocation_directory() => Directory where just was run.
# invocation_directory_native() => Directory where just was run without any transformations.

# These variables are used because Nu cannot 'use' a dynamic path; it has to be static.
# Note: Exported environment variables are not see in env().
# https://github.com/casey/just/issues/2713
GLOBAL_JUST_DIR := justfile_directory()
GLOBAL_HELPERS := justfile_directory() / "helpers.nu"
DOCKER_HELPERS := justfile_directory() / "docker-helpers.nu"

## These are environment variables for the tasks.

# Default age directory and filename to use for the keys.
export AGE_DIR_NAME := '.age'
export AGE_FILE_NAME := 'keys.txt'

# JUST_DIR is the directory of the current Justfile
export JUST_DIR := justfile_directory()
# JUST_CURRENT_DIR it the invocation directory where the just command was run.
export JUST_INVOCATION_DIR := invocation_directory_native()


# default recipe to display help information
# just list will fallback to the parent justfile and list recipes only in the parent justfile.
# just --list returns only recipes in this justfile.
default:
	@just --list


# list the just recipes
list:
	@just --list


# Get the directory this Justfile is in.
justfile-dir-get:
	#!/usr/bin/env nu
	'{{ justfile_directory() }}'


# Require a command to be available
[private]
require-command command:
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	exit (command exists "{{ command }}")


# Generate encryption keys for age in the specified directory. Default dir: .
age-genkeys dir=".": (require-command "age-keygen")
	#!/usr/bin/env nu
	use std log

	let dir = "{{ dir }}"
	use '{{ join(justfile_directory(), "helpers.nu") }}' *
	# Check if $dir is an absolute path.
	if ($dir | path expand) == $dir {
		# $dir is an absolute path.
		log info $"Generating encryption keys in: ($dir)"
		age-genkeys ($dir | path join $env.AGE_DIR_NAME)
	} else {
		# $dir is a relative path from the current (invocation) directory.
		log info $"Generating encryption keys in: ($env.JUST_INVOCATION_DIR | path join $dir | path join $env.AGE_DIR_NAME | path expand)"
		let age_dir = ($env.JUST_INVOCATION_DIR | path join $dir | path join $env.AGE_DIR_NAME | path expand)
		age-genkeys $age_dir
	}


# This is not needed since the keys are now managed in ~/.config/sops/ago/keys.txt
# Get the SOPS_AGE_KEY_FILE environment variable.
#sops-get-key-file:
#	#!/usr/bin/env nu
#	use std log
#	# nu does not allow dynamic imports for 'use', 'source', etc. This means we have to rely on just to provide
#	# the location of the helpers.nu file.
#	use '{{ join(justfile_directory(), "helpers.nu") }}' *
#
#	cd $env.JUST_INVOCATION_DIR
#	let age_keys = (find-dir $env.AGE_DIR_NAME | path join $env.AGE_FILE_NAME)
#	if not ($age_keys | path exists) {
#		log warning $"Could not find .age keys: '($age_keys)'"
#		return
#	}
#	$age_keys


# Do NOT include 'prefix=' on the command line.
# Right: sops-encrypt-file name
# Wrong: sops-encrypt-file prefix=name
# Use sops to encrypt an example file so that the encrypted file can be edited.
sops-encrypt-file prefix='cfg-docker': (require-command "sops")
	#!/usr/bin/env nu
	use std log

	cd "{{ invocation_directory_native() }}"
	let ext = (glob {{ prefix }}.example.*
		| path basename
		| split column '.'
		| transpose
		| last 1
		| get column1.0)
	let encrypted_file = $"{{ prefix }}.sops.($ext)"
	let example_file = $"{{ prefix }}.example.($ext)"
	if not ($example_file | path exists) {
		print $"Example file does not exist: '($example_file)'"
		return
	}
	if ($encrypted_file | path exists) {
		print $"Encrypted config file already exists: '($encrypted_file)'"
		return
	}
	^sops --encrypt $example_file | save $encrypted_file
	log info $"Created encrypted file '($encrypted_file)' from example file '($example_file)'"


# Start the application server
app-start: (require-command "sops") (require-command "gomplate") (require-command "docker compose version")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	app start


# Stop the application server
app-stop: (require-command "sops") (require-command "gomplate") (require-command "docker compose version")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	app stop


# Restart the application server
app-restart:
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	app stop
	app start


# Start all applications
app-start-all:
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	app start all


# Stop all applications
app-stop-all:
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	app stop all


# Restart all applications
app-restart-all:
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	app restart all


# Parameters:
#   image_name: Name of the Docker image to build.
#   env: (default=prod) prod or dev environment.
# Build the application image for Docker
app-build-helper image_name env="prod": (require-command "sops") (require-command "gomplate") (require-command "docker buildx version")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	app build helper --image_name '{{ image_name }}' --environment '{{ env }}'


# Parameters:
#   image_name: Name of the Docker image to build.
#   env: (default=prod) prod or dev environment.
# Update (create) the application config
app-build-smartctl-exporter image_name="smartctl-exporter-noroot" env="prod": (require-command "sops") (require-command "gomplate")
	#!/usr/bin/env nu
	use std log

	# FIXME: The image name in cfg-docker.sops.yml should be used instead of the default parameter in the command.
	let image_name = '{{ image_name }}'
	let environment = '{{ env }}'
	log info $"Building the ($image_name) application..."
	cd "{{ invocation_directory_native() }}"
	^just app-build-helper $image_name $environment


# Get the application config
app-config: (require-command "sops")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	pwd | app config get


# Get the application (docker) config
app-config-get: (require-command "sops")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	pwd | app config get


# Update (create) the application config
app-config-update: (require-command "sops")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	pwd | app config update


# Update (create) the Prometheus config (alert-rules and service-discovery)
app-config-update-prometheus: (require-command "sops")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	pwd | app config update prometheus


# Parameters:
#   app_config: Path to the application config in the current directory.
#   save_file: (default=stdout) Full path to save the generated config file.
# Helper command for updating the application configuration
app-config-update-helper app_config save_file="-": (require-command "sops") (require-command "gomplate")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	app config update helper --app_config '{{ app_config }}' --save_file '{{ save_file }}'


# Parameters:
#   app_config: Path to the application config in the current directory.
#   save_file: (default=stdout) Full path to save the generated config file.
# Helper command for getting the application configuration
app-config-helper app_config save_file="-": (require-command "sops") (require-command "gomplate")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	app config helper --app_config '{{ app_config }}' --save_file '{{ save_file }}'


# Dump the Docker config. Used for troubleshooting.
docker-config-get: (require-command "sops") (require-command "gomplate") (require-command "docker compose version")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	docker config get


# Get the Docker resources specified in default (../resources.yml) and local (resources.yml) files.
resources-get:
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	resources get


# List the Docker resources specified in resources.yml
resources-list: (require-command "docker compose version")
	#!/usr/bin/env nu
	# Import the global and docker helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	resources list


# Create the Docker resources using resources.yml
resources-create: (require-command "docker compose version")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	resources create


# Remove the Docker resources using resources.yml
resources-remove: (require-command "docker compose version")
	#!/usr/bin/env nu
	# Import the global helpers.
	use '{{ GLOBAL_HELPERS }}' *
	cd "{{ invocation_directory_native() }}"
	resources remove
