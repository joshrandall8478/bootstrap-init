# This file is a collection of Nu functions used in the Justfile.
# Find the directory name in the parent directories.
export def find-dir [name: string]: [nothing -> string, nothing -> nothing] {
	use std log
	if ($name | is-empty) {
		log error $"find-dir: '($name)' is not defined"
		return ""
	}
	mut dir = $env.PWD
	mut parent_dir = ($dir | path dirname)
	mut count = 0
	# Maximum number of iterations (directories) before exiting.
	let max_count = 20

	while ($parent_dir != $dir) {
		if ($dir | path join $name | path exists) {
			return ($dir | path join $name)
		}
		$dir = $parent_dir
		$parent_dir = ($parent_dir | path dirname)
		$count += 1
		if ($count > $max_count) {
			log warning $"find-dir: Maximum number of iterations reached"
			return ""
		}
	}
	if ($parent_dir == $dir) {
		# Did not find the directory
		# Uncomment this for debugging purposes only
		#log info $"find-dir: Did not find '($name)' directory before reaching the root of the drive."
		return ""
	} else {
		# This is an error condition and should not be reached.
		log error $"find-dir: Did not find '($name)' directory in loop, and did not reach root of drive."
		return ""
	}
}


# Generate age keys in the given directory.
export def age-genkeys [
		age_dir: string = '.age' # directory to store the age keys
]: [nothing -> nothing, nothing -> string] {
	use std log
	let age_dir = $age_dir | path expand
	let age_keys = $age_dir | path join 'keys.txt'

	if ($age_dir | path exists) {
		# The .age directory should not exist
		log warning $"age-genkeys: .age directory already exists: '($age_dir)'"
	} else {
		mkdir $age_dir
	}
	if ($age_keys | path exists) {
		log warning $"age-genkeys: age keys already exist: '($age_keys)'"
		return
	}
	# TODO: age-keygen does not append to files.
	^age-keygen --output $age_keys
}


# Check if a command is available.
export def 'command exists' [
	command: string				# Command to check
]: nothing -> int {
	let command = ($command | default "")
	# Note: The return code is used as the exit code in the "require-command" recipe.
	mut exit_code = 0
	if ($command | str contains " ") {
		# Command has arguments. Run the command and check the exit code
		#do { $command } | complete
		do { $command }
		if ($env.LAST_EXIT_CODE != 0) {
			print $"'($command)' did not exit cleanly. Please verify '($command)' is available."
			$exit_code = 1
		}
	} else {
		if (which $command | is-empty) {
			print $"'($command)' executable not found. Please install '($command)' and try again."
			$exit_code = 1
		}
	}
	return $exit_code
}


# Merge the secrets, variables and plain files to create the final config file.
# Input: File prefix for the configuration to merge.
export def 'config merge' []: string -> any {
	use std log
	let prefix = $in
	if ($prefix | is-empty) {
		log error $"test merge: 'prefix' is not defined"
		return
	}

	let plain = (open (glob $"($prefix)-plain.*" | first))
	let variables = (open (glob $"($prefix)-variables.*" | first))
	# SOPS does not encrypt files with comments only and produces an empty file.
	let secrets = (
		glob $"($prefix)-secrets.*"
		| first
		| each {|it|
			if (ls $it | get size | first | into int) > 0 {
				sops --decrypt (glob $"($prefix)-secrets.*" | first) | from yaml
			}
		}
	)
	# The template comes first, then the variables, then the secrets
	# The strategy might change in the future.
	mut config = $plain
	if ($variables | is-not-empty) {
		log debug $"No variables found for '($prefix)'"
		$config = ($config | merge deep --strategy append $variables)
	}
	if ($secrets | is-not-empty) {
		log debug $"No secrets found for '($prefix)'"
		$config = ($config | merge deep --strategy append $secrets)
	}
	$config
}


# Start the application
export def 'app start' []: nothing -> any {
	use std log
	let prefix = "compose"
	$prefix | config merge | to yaml | docker compose --file - up --detach
}


# Stop the application
export def 'app stop' []: nothing -> any {
	use std log
	let prefix = "compose"
	$prefix | config merge | to yaml | docker compose --file - down
}


# Start all applications
export def 'app start all' []: nothing -> nothing {
	use std log

	let resource_file = "resources.yml"
	if not ($resource_file | path exists) {
		log warning $"Resource file '($resource_file)' does not exist"
	}
	let resources = open $resource_file

	$resources.apps | each {|it|
		if not ($it | path exists) {
			log warning $"Path '($resource_file)' does not exist"
			continue
		}
		cd $it
		app start
		$it
	}
}


# Stop all applications
export def 'app stop all' []: nothing -> nothing {
	use std log

	let resource_file = "resources.yml"
	if not ($resource_file | path exists) {
		log warning $"Resource file '($resource_file)' does not exist"
	}
	let resources = open $resource_file

	$resources.apps | each {|it|
		if not ($it | path exists) {
			log warning $"Path '($resource_file)' does not exist"
			continue
		}
		cd $it
		app stop
		$it
	}
}


# Restart all applications
export def 'app restart all' []: nothing -> nothing {
	use std log

	let resource_file = "resources.yml"
	if not ($resource_file | path exists) {
		log warning $"Resource file '($resource_file)' does not exist"
	}
	let resources = open $resource_file

	$resources.apps | each {|it|
		if not ($it | path exists) {
			log warning $"Path '($resource_file)' does not exist"
			continue
		}
		cd $it
		app stop
		app start
		$it
	}
}


# Build the application image for Docker
export def 'app build helper' [
	--environment: string			# (default=prod) prod or dev environment
	--image_name: string			# Name of the Docker image to build.
]: string -> nothing {
	use std log
	let input = $in
	let resources = ($input | resources get)

	let config = ($resources.app_name | config merge)
	let config_dir = ($resources.volumes | where name =~ "config" | get opts.device.0)
	let config_file = ($config_dir | path join $"($resources.app_name).yml")

	let environment = ($environment | default 'prod')
	let image_name = (
		if ($environment == 'dev') {
			[$config.app.image_name, $environment] | str join '-'
		} else {
			$config.app.image_name
		}
	)

	# $ENVIRONMENT is used in the Dockerfile
	$env.ENVIRONMENT = $environment
	^docker buildx ...[
		build
		--progress=plain
		--file -
		--tag $image_name
		--network host
		.
	]

}


# Update (create) the application config for Alertmanager.
export def 'app config update alertmanager' [
	--app_config: string			# Path to the application config in the current directory.
	--save_file: string				# (default=stdout) Full path to save the generated config file
]: nothing -> nothing {
	##
	## Alertmanager
	##
	use std log
	let defaults = (if ("../resources.yml" | path exists) { open "../resources.yml"})
	let resources = (if ("resources.yml" | path exists) { open "resources.yml"})

	# Use the directory name as the config directory name.
	let name = (pwd | path basename)
	let config_dir = (
		$defaults.default.base.dir
		| path join ($resources.volumes | where name =~ $name | get opts.device.0)
	)
	log info $"Updating the ($name) config..."
	app config update helper --app_config $"($name).yml"
		| save --force ($config_dir | path join $"($name).yml")
	# Nushell does not have umask to set default file permissions
	# https://github.com/nushell/nushell/issues/12256
	# https://github.com/nushell/nushell/issues/11884
	^chmod a+r,o-w ($config_dir | path join $"($name).yml")
}


# Update (create) the alert rules and service discovery files for Prometheus.
export def 'app config update prometheus' [
	--app_config: string			# Path to the application config in the current directory.
	--save_file: string				# (default=stdout) Full path to save the generated config file
]: nothing -> any {
	##
	## Prometheus
	##
	use std log
	let input = $in
	let resources = ($input | resources get)
	let config = ($resources.app_name | config merge)
	let config = ($resources.app_name | config merge)
	let config_dir = ($resources.volumes | where name =~ "config" | get opts.device.0)
	let config_file = ($config_dir | path join $"($resources.app_name).yml")

	log info "Updating the alert rules..."
	# FiXME: This does not delete files that were deleted in the source dir.
	let alert_rules_dir = ($config_dir | path join 'alert-rules')
	glob alert-rules/*.yml | each {|it|
		let filename = ($it | path basename)
		log info $"Updating the ($filename) alert rule..."
		cp $it $alert_rules_dir
		^chmod a+r,o-w ($alert_rules_dir | path join $filename)
	}

	log info $"Updating the service discovery files..."
	# FiXME: This does not delete files that were deleted in the source dir.
	let service_discovery_dir = ($config_dir | path join 'service-discovery')
	glob service-discovery/*.yml | each {|it|
		let filename = ($it | path basename)
		log info $"Updating the ($filename) service discovery config..."
		cp $it $service_discovery_dir
		^chmod a+r,o-w ($service_discovery_dir | path join $filename)
	}
}


# Update the application configuration.
export def 'app config update' []: string -> string {
	use std log
	let input = $in
	let resources = ($input | resources get)

	let config = ($resources.app_name | config merge)
	let config_dir = ($resources.volumes | where name =~ "config" | get opts.device.0)
	let config_file = ($config_dir | path join $"($resources.app_name).yml")
	log debug $"config_dir: ($config_dir)"
	log debug $"config_file: ($config_file)"

	$config | to yaml | ^sudo tee $config_file | ignore
	# Nushell does not have umask to set default file permissions
	# https://github.com/nushell/nushell/issues/12256
	# https://github.com/nushell/nushell/issues/11884
	# Fix permissions on the file
	^sudo chmod a+r,go-wx $config_file
	log info $"Updated config file: '($config_file)'"
}


# Helper command for updating the application configuration
export def 'app config update helper' [
	--app_config: string			# Path to the application config in the current directory.
	--save_file: string				# (default=stdout) Full path to save the generated config file
]: nothing -> nothing {
	use std log
	let save_file = ($save_file | default '-')
	let app_cfg = ($app_config | default '')
	let cfg = 'cfg-app.sops.yml'
	if not ($cfg | path exists) {
		log error $"Encrypted file '($cfg)' does not exist"
		return
	}
	if not ($app_cfg | path exists) {
		log error $"Application config '($app_cfg)' does not exist"
		return
	}
	if $save_file == '-' {
		# Write output to stdout
		log info $"Generating app config '($app_cfg)' and saving to stdout"
		^sops --decrypt $cfg
			| ^gomplate --datasource cfg=stdin:///cfg.yml --left-delim '<<' --right-delim '>>' --file $app_cfg
	} else {
		# Save to file
		log info $"Generating app config '($app_cfg)' and saving to '($save_file)'"
		^sops --decrypt $cfg
			| ^gomplate --datasource cfg=stdin:///cfg.yml --left-delim '<<' --right-delim '>>' --file $app_cfg
			| save --force $save_file
		# Nushell does not have umask to set default file permissions
		# https://github.com/nushell/nushell/issues/12256
		# https://github.com/nushell/nushell/issues/11884
		^chmod a+r,o-w $save_file
	}
}


# Get the application config
export def 'app config get' []: string -> any {
	use std log
	let input = $in
	let resources = ($input | resources get)

	let config = ($resources.app_name | config merge)
	log info $"Resources name: ($resources.app_name)"
	$config
	# let config_dir = ($resources.volumes | where name =~ "config" | get opts.device.0)
	# let config_file = ($config_dir | path join $"($resources.app_name).yml")
	# log info $"config_dir: ($config_dir)"
	# log info $"config_file: ($config_file)"
}


# Helper command for getting the application configuration
export def 'app config helper' [
	--app_config: string			# Path to the application config in the current directory.
	--save_file: string				# (default=stdout) Full path to save the generated config file
]: nothing -> nothing {
	use std log
	let save_file = ($save_file | default '-')
	let app_cfg = ($app_config | default '')
	let cfg = 'cfg-app.sops.yml'
	if not ($cfg | path exists) {
		log error $"Encrypted file '($cfg)' does not exist"
		return
	}
	if not ($app_cfg | path exists) {
		log error $"Application config '($app_cfg)' does not exist"
		return
	}
	# Write output to stdout
	log info $"Getting application config '($app_cfg)'"
	^sops --decrypt $cfg
		| ^gomplate --datasource cfg=stdin:///cfg.yml --left-delim '<<' --right-delim '>>' --file $app_cfg

}


# Dump the Docker config. Used for troubleshooting.
export def 'docker config get' []: nothing -> nothing {
	use std log
	# let input = $in
	# let resources = ($input | resources get)

	let config = ("compose" | config merge)
	log info $"Resources name: 'compose'"
	$config
}


# Get the application resources.
export def 'resources get' []: [
	nothing -> any
	any -> any
] {
	use std log
	# Application resources are in the current directory.
	# Server resources are in the parent directory.
	# Input is the full directory name.
	let input = $in
	let base_path = (if ($input | is-not-empty) { $input | path expand} else { pwd })
	# The directory name is the config directory name.
	let name = ($base_path | path basename)
	let defaults_file = ([$base_path, ".."] | path join "resources.yml")
	let resources_file = ($base_path | path join "resources.yml")
	let defaults = (if ($defaults_file | path exists) { open $defaults_file})
	let resources = (if ($resources_file | path exists) { open $resources_file})

	let volumes = (
		$resources.volumes? | each {|it|
			if ($it | is-not-empty) {
				let path = ([$defaults.default.base.dir, $name] | path join $it.opts.device)
				{
					name: $it.name
					driver: $defaults.default.volumes.driver
					opts: ($defaults.default.volumes.opts | insert device $path)
				}
			}
		}
	)
	let networks = (
		$resources.networks? | each {|it|
			if ($it | is-not-empty) {
				{
					name: $it.name
					driver: $defaults.default.networks.driver
				}
			}
		}
	)
	{
		app_name: $name
		volumes: $volumes
		networks: $networks
	}
}


# List the Docker resources specified in resources.yml
export def 'resources list' []: nothing -> nothing {
	use docker-helpers.nu *
	# TODO: Use "resources get" instead of passing in strings for arguments.
	resources process
}


# Create the Docker resources using resources.yml
export def 'resources create' []: nothing -> nothing {
	use docker-helpers.nu *
	# Use "resources process" as input directly.
	docker-helpers create
}


# Remove the Docker resources using resources.yml
export def 'resources remove' []: nothing -> nothing {
	use docker-helpers.nu *
	# TODO: Use "resources get" instead of passing in strings for arguments.
	docker-helpers remove
}