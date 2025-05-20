################################################################################
# This file is a collection of Nu functions called from the Justfile. The
# justfile is a wrapper around these functions.


################################################################################
# General functions
################################################################################


# Get a list of parent directories.
export def "test path parents" []: [nothing -> list<path>, path -> list<path>] {
	# Source: https://discord.com/channels/601130461678272522/601130461678272524/1373308546430799923
	# This function is for learning how reduce works. It was provided by someone on Discord
	# and it provides a list of directories as it traverses up the tree.
	let pattern = "resources*"
	$in
	| default $env.PWD
	| path split
	| reduce -f [] {|element, acc|
		print $"element: '($element)'; accumulator: '($acc)'"
		$acc
		| try { first }
		| default ""
		| path join $element
		| append $acc
	}
	# | each {|it|
	# 	glob --depth 1 ($it | path join $pattern)
	# }
	# | flatten
}

# glob up: Recurse up the directory tree to find the named patterns.
export def 'glup' [
	pattern: string		# Glob pattern to find.
	--kind: string		# "dir", "file", or "symlink"; Default: "" which means all
]: [
	path -> list<path>,
	nothing -> list<path>,
] {
	# Input is expected to be a directory path.
	$in
	| default $env.PWD
	| path split
	| reduce -f [] {|element, acc|
		# use std log
		# log debug $"element: '($element)'; accumulator: '($acc)'"
		$acc
		| try { first }
		| default ""
		| path join $element
		| append $acc
	}
	| each {|it|
		match $kind {
			"dir" => {glob --depth 1 --no-file --no-symlink ($it | path join $pattern)}
			"file" => {glob --depth 1 --no-dir --no-symlink ($it | path join $pattern)}
			"symlink" => {glob --depth 1 --no-file --no-dir ($it | path join $pattern)}
			_ => {glob --depth 1 ($it | path join $pattern)}
		}
	}
	| flatten
}

# Generate age keys in the given directory.
export def age-genkeys [
		age_dir: string = '.age' # directory to store the age keys
]: [nothing -> nothing, nothing -> string] {
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


################################################################################
# Docker functions
################################################################################

# Convert docker commands to json output.
def 'docker-json' [
	...args: string		# Docker arguments
]: [nothing -> any] {
	use std log
	log debug $"Executing command: 'docker (echo ...$args | str join ' ') --format json'"
	^docker ...$args --format json
		| lines
		| each {|it| $it | from json}
}

# Get a docker resource
def 'docker-json get' [
	--type (-t): string		# Resource type
	name?: string			# Resource name
]: [any -> any, nothing -> any] {
	let input = $in
	mut name = $name
	if not ($input | is-empty) {
		$name = $input
	}
	docker-json $type ls | where Name =~ $name
}


# Merge a default volume with an override volume to create a new volume
def 'volume merge' [
	override: any					# Merge override values
]: [any -> any] {
	let default = $in
	mut override = $override
	$override.opts = ($default.opts | merge $override.opts)
	$default | merge $override
}


# Merge a default network with an override network to create a new network
def 'network merge' [
	override: any					# Merge override values
]: [any -> any] {
	let default = $in
	let override = $override
	$default | merge $override
}


# Create multiple docker networks
def 'networks create' [
	default: any					# Default network properties to use
]: [any -> any] {
	use std log
	let $input = $in
	if ($input | get --ignore-errors networks | length) == 0 {
		log info $"Network list is empty"
		return {}
	}

	$input | get --ignore-errors networks | each {|it|
		if (docker-json network ls | where Name =~ $it.name | is-not-empty) {
			log info $"Network already exists: ($it.name)"
			return {type: network, action: none, name: $it.name}
		}

		log info $"Creating network: ($it.name)"
		$default | network merge $it | each {|network|
			let n = (^docker network create --driver $network.driver $network.name | str trim)
			{type: network, action: created, name: $n}
		}
	}
}


# Create multiple docker volumes
def 'volumes create' [
	default: any					# Default volume properties to use
	--base_dir: string				# Base data directory to prepend to relative paths
]: [any -> any] {
	use std log

	let $input = $in
	let base_dir = ($base_dir | path expand)
	if not ($base_dir | path exists) {
		log error $"Base path does not exist: '($base_dir)'"
		return {}
	}
	if ($input | get --ignore-errors volumes | length) == 0 {
		log info $"Volume list is empty"
		return {}
	}

	$input | get --ignore-errors volumes | each {|it|
		if (docker-json volume ls | where Name =~ $it.name | is-not-empty) {
			log info $"Volume already exists: ($it.name)"
			return {type: volume, action: none, name: $it.name}
		}

		log info $"Creating volume: ($it.name)"
		mut volume = ($default | volume merge $it)
		if not ($volume.opts.device | str starts-with '/') {
			# Device is relative to default.base.dir
			$volume.opts.device = ($base_dir | path join $volume.opts.device)
		}
		let $opts = ($volume.opts | items {|key, value| ["--opt" $"($key)=($value)"]} | flatten)
		let v = (^docker volume create --driver $volume.driver ...$opts $volume.name | str trim)
		{type: volume, action: created, name: $v}
	}
}


# Create a docker network
def 'network create' [
	name: string					# Network name
	--driver: string = 'bridge'		# Network driver
] {
	let name = $name
	let driver = $driver
	^docker network create --driver $driver $name | ignore
}


# Remove a docker network
def 'network remove' [
	name: string						# Network Name
]: [any -> nothing, nothing -> nothing] {
	let input = $in
	mut name = $name
	if not ($input | is-empty) {
		$name = $input.Name
	}
	^docker network rm $name | ignore
}


# Create a docker volume
def 'volume create' [
	name: string					# volume name
	--device: string				# Device location
	--options: any					# Volume options
	--driver: string = 'local'		# Volume driver
] {
	use std log
	let name = $name
	let device = $device
	let driver = $driver
	let options = $options
	# TODO: Incorporate the options and driver into the command line.
	log debug $"Executing command: 'docker volume create --driver ($driver) --opt type=none --opt o=bind --opt \"device=($device)\" ($name)"
	^docker volume create --driver $driver --opt type=none --opt o=bind --opt $"device=($device)" $name | ignore
}


# Remove a docker volume
def 'volume remove' [
	name: string						# Volume Name
]: [any -> nothing, nothing -> nothing] {
	let input = $in
	mut name = $name
	if not ($input | is-empty) {
		$name = $input.Name
	}
	^docker volume rm $name | ignore
}


################################################################################
# Config and app functions
################################################################################

# Merge the secrets, variables and plain files to create the final config file.
# Input: File prefix for the configuration to merge.
export def 'config merge' [
	app_name?: string		# Application name
]: string -> any {
	use std log

	# Prefix: One of the following:
	#    - "compose" which generates the Docker compose file.
	#    - The application name for the configuration file. For example: prometheus
	# app_name: The application name for the template. This is different for the compose "prefix".
	# Templates are in $env.TEMPLATE_DIR/app_name/prefix.yml format.
	let prefix = $in
	log info $"config merge| prefix: '($prefix)'"

	# SOPS does not encrypt files with comments only and produces an empty file.
	let secrets = (
		try {
			glob --no-dir --depth 1 $"($prefix)-secrets.*"
			| first
			| open --raw
			# TODO: Implement file type detection
			| sops --input-type yaml --output-type yaml --decrypt /dev/stdin
			| from yaml
		} catch {
			{}
		}
	)
	# log info $"config merge| secrets: ($secrets)"

	# Load the resources.
	let resources = ($env.PWD | resources get)

	# app_name is the application name for the template.
	let app_name = ($resources.app.name)

	# Merge the config files into a single config file. Since the strategy is "append",
	# keys should not overlap.
	#   1) The template should be the same for all servers.
	#   2) The plain file is server specific configurations but no variables.
	#   3) The variables file contains all the variables but not secrets.
	#   4) The secrets file contains the secrets.
	# There are times when a server may need a different "template". That's the purpose of the plain file.
	[
		(glob --no-dir --depth 1 ([$env.TEMPLATE_DIR, $app_name] | path join $"($prefix).*"))
		(glob --no-dir --depth 1 $"($prefix)-plain.*")
		(glob --no-dir --depth 1 $"($prefix)-variables.*")
	]
	| flatten
	| filter { path exists }
	| reduce -f {} {|element, acc|
		use std log
		log info $"element: '($element)'; accumulator: '($acc)'"
		$acc
		| merge deep --strategy append (open $element)
	}
	| merge deep --strategy append $secrets
}


# Start the application
export def 'app start' []: nothing -> any {
	let prefix = "compose"
	let app_name: string = (pwd | path basename)
	# ! For debugging purposes only
	# $prefix | config merge --app_name $app_name | to yaml | cat
	$prefix | config merge $app_name | to yaml | docker compose --file - up --detach
}


# Stop the application
export def 'app stop' []: nothing -> any {
	let prefix = "compose"
	let app_name: string = (pwd | path basename)
	$prefix | config merge $app_name | to yaml | docker compose --file - down
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
		log info $"Starting application: '($it)'"
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
	let input = $in
	let resources = ($input | default $env.PWD | resources get)

	let config = ($resources.app.name | config merge)
	let config_dir = ($resources.volumes | where name =~ "config" | get opts.device.0)
	let config_file = ($config_dir | path join $"($resources.app.name).yml")

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
	let resources = ($in | default $env.PWD | resources get)
	let config = ($resources.app.name | config merge)
	let config_dir = ($resources.volumes | where name =~ "config" | get opts.device.0)
	let config_file = ($config_dir | path join $"($resources.app.name).yml")

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
	let resources = ($in | default $env.PWD | resources get)

	let config = ($resources.app.name | config merge)
	let config_dir = ($resources.volumes | where name =~ "config" | get opts.device.0)
	let config_file = ($config_dir | path join $"($resources.app.name).yml")
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
export def 'app config get' []: [
	nothing -> record<any>,
	string -> record<any>,
] {
	use std log
	let resources = ($in | default ($env.PWD | path basename) | resources get)
	# log info $"app config get| resources: ($resources)"
	# print $resources | table --width 200
	log info $"app config get| resources.app.name: ($resources.app.name)"
	$resources.app.name | config merge $resources.app.name
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
	let resources = ($in | default $env.PWD | resources get)
	let config = ("compose" | config merge $resources.app.name)
	log info $"Resources name: 'compose'"
	$config
}

# Get a list of parent directories.
export def "test resources get" []: [nothing -> list<path>, path -> list<path>] {
	# Source: https://discord.com/channels/601130461678272522/601130461678272524/1373308546430799923
	# This function is for learning how reduce works. It was provided by someone on Discord
	# and it provides a list of directories as it traverses up the tree.
	let pattern = "resources*"
	$in
	| default $env.PWD
	| path split
	| reduce -f [] {|element, acc|
		print $"element: '($element)'; accumulator: '($acc)'"
		$acc
		| try { first }
		| default ""
		| path join $element
		| append $acc
	}
	# | each {|it|
	# 	glob --depth 1 ($it | path join $pattern)
	# }
	# | flatten
}


################################################################################
# Resource functions
################################################################################

# Get the details of a docker resource
def 'resource get details' [
	name?: string	# Resource name
]: [any -> any, nothing -> any] {
	# TODO: Is this used?
	use std log
	let input = $in
	mut name = $name
	if not ($input | is-empty) {
		$name = $input.ID.0
	}

	log debug $"Getting details for resource '($name)'"
	docker-json inspect $name | from json
}

# Get the application resources.
export def 'resources get' []: [
	path -> record<any>,
	nothing -> record<any>,
] {
	# This function adds an "app" key to the resource configuration record. The resource configuration
	# is based on the app, server and defaults defined in "resources.yml" files.
	use std log

	# Capture the input.
	let path = $in

	# Glup traverses up the directory tree and returns a list of files for the given pattern.
	# Reduce opens each file and appends it to a record that is eventually returned.
	let resources = (
		glup "resources.yml"
		| reverse
		| reduce -f {} {|element, acc|
			# use std log
			# log info $"resources get| element: '($element)'; accumulator: '($acc)'"
			$acc
			| merge deep --strategy append (open $element)
		}
	)

	# The application name is determined by the following:
	#   1. app_name in the resources.yml file, if it exists.
	#   2. The current working directory.
	let app_name = (
		if ("app_name" in $resources) {
			$resources.app_name
		} else {
			$path | default $env.PWD | path basename
		}
	)
	log info $"resources get| app_name: '($app_name)'"

	let volumes = (
		$resources.volumes? | each {|it|
			if ($it | is-not-empty) {
				let path = ([$resources.default.base.dir, $app_name] | path join $it.opts.device)
				{
					name: $it.name
					driver: $resources.default.volume.driver
					opts: ($resources.default.volume.opts | insert device $path)
				}
			}
		}
	)
	let networks = (
		$resources.networks? | each {|it|
			if ($it | is-not-empty) {
				{
					name: $it.name
					driver: $resources.default.network.driver
				}
			}
		}
	)

	$resources | merge {
		app: {
			name: $app_name,
			volumes: $volumes,
			networks: $volumes,
		}
	}
}

# Create the docker resources
export def 'resources create' []: [any -> any] {
	use std log
	resources process
	| each {|it|
		mut status = 'unknown'
		log info $"resources create| record: '($it)'"

		# # ? Maybe convert this to use match
		# match ($it.name | docker-json get --type $it.type) {
		# 	"network" => {

		# 	}
		# 	"volume" => {
				
		# 	}
		# 	_ => {
		# 		log error $"resources create| Unknown resource type: '($it.type)'"
		# 		# return
		# 	}
		# }
		if ($it.name | docker-json get --type $it.type | is-empty) {
			log info $"resources create| Creating ($it.type): '($it.name)'"

			if ($it.type == "network") {
				network create $it.name --driver $it.location
			} else if ($it.type == "volume") {
				volume create $it.name --device $it.location
			}

			if ($it.name | docker-json get --type $it.type | is-not-empty) {
				$status = 'created'	
			} else {
				$status = 'missing'
			}
			
		} else {
			log info $"resources create| ($it.type) already exists: '($it.name)'"
			$status = 'exists'
		}

		# This outputs the resource information as a record.
		{
			App: $it.app
			Type: $it.type
			Name: $it.name
			Status: $status
			Location: $it.location
		}
	}
}


# Create all Docker resources for a server.
export def 'resources create all' []: [any -> any] {
	use std log
	# The try/catch hides the actual error. Not catching it is better.
	# try {
		"resources.yml"
		| open
		| get apps
		| filter { path exists }
		| each {|app|
			cd $app
			log info $"Creating resources for app: '($app)'"
			resources create
		}
		| flatten
	# } catch {|err|
	# 	use log
	# 	log error $"Error: ($err.msg)"
	# }
}


# Remove the Docker resources for an application.
export def 'resources remove' []: [any -> any] {
	use std log
	resources process
	| each {|it|
		mut status = 'unknown'
		log info $"resources remove| record: '($it)'"

		if ($it.name | docker-json get --type $it.type | is-not-empty) {
			log info $"resources remove| Removing ($it.type): '($it.name)'"

			if ($it.Type == "network") {
				network remove $it.name
				
			} else if ($it.Type == "volume") {
				volume remove $it.name
				
			}
			if ($it.name | docker-json get --type $it.type | is-empty) {
					$status = 'removed'	
			} else {
				$status = 'exists'
			}
			
		} else {
			log info $"resources remove| ($it.type) does not exist: '($it.name)'"
			$status = 'missing'
		}

		{
			App: $it.app
			Type: $it.type
			Name: $it.name
			Status: $status
			Location: $it.location
		}
	}
}


# Remove all Docker resources for all apps in a server.
export def 'resources remove all' []: [any -> any] {
	use std log
	# The try/catch hides the actual error. Not catching it is better.
	# try {
		"resources.yml"
		| open
		| get apps
		| filter { path exists }
		| each {|app|
			cd $app
			log info $"Removing resources for app: '($app)'"
			resources remove
		}
		| flatten
	# } catch {|err|
	# 	use log
	# 	log error $"Error: ($err.msg)"
	# }
}


# Process the resource configuration and return a list of network and volume resources.
export def 'resources process' []: [
	path -> table<any>,
	nothing -> table<any>,
] {
	# This function outputs the application resource for Docker, including the status if
	# they exist in Docker.
	use std log
	let resources = ($in | default $env.PWD | resources get)

	let network_list = (
		# Extract the network resources
		if ("networks" in $resources) {
			let net_driver = $resources.default.networks.driver
			$resources.networks | each {|it|
				mut status = 'missing'
				mut location = $net_driver
				let network = ($it.name | docker-json get --type network)
				if ($network | is-empty) {
					log info $"Network does not exist: '($it.name)'"
					$status = 'missing'
				} else {
					log info $"Network exists: '($it.name)'"
					$status = 'exists'
				}
				{
					App: $resources.app.name
					Type: 'network'
					Name: $it.name
					Status: $status
					Location: $location
					Args: ['--driver', $location]
				}
			}
		}
	)

	let volume_list = (
		# Extract the volume resources
		if ("volumes" in $resources) {
			let vol_driver = $resources.default.volumes.driver
			let vol_opts = $resources.default.volumes.opts
			let base_dir  = $resources.default.base.dir
			
			$resources.volumes | each {|it|
				mut status = 'missing'
				mut location = ''
				mut driver = $vol_driver
				mut opts = $vol_opts
				
				let volume = ($it.name | docker-json get --type volume)
				if ($volume | is-empty) {
					log info $"Volume does not exist: '($it.name)'"
					$status = 'missing'
				} else {
					log info $"Volume exists: '($it.name)'"
					$status = 'exists'
				}

				if ($it.opts.device | str starts-with '/') {
					# Device is absolute path
					$location = $it.opts.device
				} else {
					# Device is relative to defaults.base.dir
					$location = ($base_dir | path join $it.opts.device)
				}

				{
					App: $resources.app.name
					Type: 'volume'
					Name: $it.name
					Status: $status
					Location: $location
					Args: ['--driver', $driver, '--opt', $opts]
				}
			}
		}
	)

	$network_list | append $volume_list
}


# List the Docker resources specified in resources.yml. This is an alias of "resources process".
export def 'resources list' []: nothing -> any {
	resources process
}
