#!/usr/bin/env nu

# Enable debug logging
# $env.NU_LOG_LEVEL = 'DEBUG'
# This removes the ANSI sequences from the output.
# $env.NU_LOG_FORMAT = $"%DATE%|%LEVEL%|%MSG%"


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
	let name = $name
	let device = $device
	let driver = $driver
	let options = $options
	# TODO: Incorporate the options and driver into the command line.
	# log debug $"Executing command: 'docker volume create --driver ($driver) --opt type=none --opt o=bind --opt \"device=($device)\" ($name)"
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


# Get the details of a docker resource
def 'resource get details' [
	name?: string	# Resource name
]: [any -> any, nothing -> any] {
	let input = $in
	mut name = $name
	if not ($input | is-empty) {
		$name = $input.ID.0
	}

	log debug $"Getting details for resource '($name)'"
	docker-json inspect $name | from json
}


# Create the docker resources
def 'resources create' []: [any -> any] {
	let input = $in

	$input | each {|it|
		mut status = 'unknown'

		if ($it.name | docker-json get --type $it.type | is-empty) {
			# log info $"Creating ($it.type): '($it.name)'"

			if ($it.type == "network") {
				network create $it.name --driver $it.location
			} else if ($it.type == "volume") {
				volume create $it.name --device $it.location
			}
			$status = 'created'
		} else {
			# log info $"($it.type) already exists: '($it.name)'"
			$status = 'exists'
		}

		# This outputs the resource information as a record.
		{
			Type: $it.type
			Name: $it.name
			Status: $status
			Location: $it.location
		}
	}

}


# Remove the docker resources
def 'resources remove' []: [any -> any] {
	let input = $in

	$input | each {|it|
		mut status = 'unknown'

		if ($it.name | docker-json get --type $it.type | is-not-empty) {
			# log info $"Removing ($it.type): '($it.name)'"

			if ($it.Type == "network") {
				network remove $it.name
			} else if ($it.Type == "volume") {
				volume remove $it.name
			}
			$status = 'removed'
		} else {
			log info $"($it.type) does not exist: '($it.name)'"
			$status = 'missing'
		}

		{
			Type: $it.type
			Name: $it.name
			Status: $status
			Location: $it.location
		}
	}

}


# Process the resource configuration and return a list of network and volume resources.
export def 'resources process' [
	resource_filename: string = 'resources.yml'		# Resource definition filename
	defaults_filename: string = '../resources.yml'	# Default resources
]: [nothing -> any] {
	# TODO: Use "resources get" from helpers.nu instead of passing in strings.
	use std log
	if not ($resource_filename | path exists) {
		log error $"Resource file not found: ($resource_filename)"
		exit 1
	}
	let resources = (open $resource_filename)
	mut defaults = null

	if ("default" in $resources) {
		# Defaults are in the current resources file.
		log info $"Using defaults from resources: ($resource_filename)"
		$defaults = $resources.defaults
	} else if ($defaults_filename | path exists) {
		# Defaults are in the defaults file (parent directory)
		log info $"Using defaults from defaults: ($defaults_filename)"
		let tmp = (open $defaults_filename)
		if ("default" in $tmp) {
			$defaults = $tmp.default
		}
	} else {
		log warning $"No defaults: resource: '($resource_filename)' default: '($defaults_filename)'"
	}

	if ($defaults | is-empty) {
		# Defaults not found
		log error $"Defaults not found: '($defaults_filename)'"
		exit 1
	}

	let network_list = (
		# Extract the network resources
		if ("networks" in $resources) {
			let net_driver = $defaults.networks.driver
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
			let vol_driver = $defaults.volumes.driver
			let vol_opts = $defaults.volumes.opts
			let base_dir  = $defaults.base.dir
			
			$resources | get volumes | each {|it|
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


export def main [
	action: string			# Action to take: [list|create|remove]
]: [nothing -> nothing] {
	use std log
	let action = $action
	let resource_filename = 'resources.yml'
	# FIXME: This could be improved to recurse up the directory tree and merge all resource files.
	mut defaults_filename = ('..' | path join $resource_filename)
	if not ($defaults_filename | path exists) {
		$defaults_filename = ('..' | path join $defaults_filename)
	}

	# Merge the resource definitions with the defaults to create a list of resources.
	let resource_list = (resources process $resource_filename $defaults_filename)

	if $action == 'list' {
		$resource_list
	} else if $action == 'create' {
		$resource_list | resources create
	} else if $action == 'remove' {
		$resource_list | resources remove
	} else {
		docker-helper.nu --help
	}
}
