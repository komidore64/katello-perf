#!/usr/bin/env bash
# vim: noet

# $ ./perfhammer.sh # will prompt you for server's hostname and katello admin password
# $ server=katello24.server.example.com password=super-secret-unguessable-password ./perfhammer.sh


# scale( value, percent )
#
# Scale the given value by a percentage. For example, "Give me 20% of 100" would
# be ``scale 100 20``.
#
# value - The integer to be scaled.
# percent - An integer representative of the percent you wish to scale
#           ``value`` by. This value should be greater than zero.
#
function scale {
	local value=$1
	local percent=$2

	echo "${percent} * ${value} / 100" | bc
}

# counts()
#
# Setup variables describing the number of each type of objects to be created.
# This takes the ${scale} variable into account as well as accounting for any
# overriden values passed in via environment variables.
#
# no arguments
#
function counts {
	local index
	local var_name

	for index in ${!defaults[*]}; do
		var_name="${index}_count"
		[ -z ${!var_name+x} ] && declare -g ${var_name}=$( scale ${defaults[${index}]} ${scale} )
	done
}

# setup-hammer-configs()
#
# Create Hammer CLI config files in the current directory containing this script
# to prevent perfhammer from contaminating or interfering with a current
# installation of Hammer.
#
# no arguments
#
function setup-hammer-configs {
	local module

	[ -d ${perfhammer}/hammer-cfg ] && return # skip this if the configs are already set up

	mkdir -p ${perfhammer}/hammer-cfg/cli.modules.d
	cat > ${perfhammer}/hammer-cfg/cli_config.yml <<-END_CLI_CONFIG_YML
		:ui:
		  :interactive: true
		  :per_page: 9999
		  :history_file: '${perfhammer}/hammer-cfg/history'
		:watch_plain: false
		:reload_cache: true
		:log_dir: '${perfhammer}/hammer-cfg/log'
		:log_level: 'debug'
	END_CLI_CONFIG_YML

	for module in foreman foreman_bootdisk foreman_docker foreman_tasks katello; do
		cat > ${perfhammer}/hammer-cfg/cli.modules.d/${module}.yml <<-END_MODULE_CONFIG
			:${module}:
			  :enable_module: true
		END_MODULE_CONFIG
	done
}

# ensure-ssh-connectivity()
#
# Ensures that this script can connect via SSH to the machine where the Katello
# server is running.  This adds an entry to your ~/.ssh/known_hosts file to
# prevent a RSA fingerprint prompt from occuring during a perfhammer run. The
# entry is only added once.
#
# no arguments
#
function ensure-ssh-connectivity {
	local known_hosts
	local shost
	local i

	shost="$( ssh-keyscan -H ${server} )"
	mapfile -t known_hosts < ~/.ssh/known_hosts
	for i in $( seq 0 $(( ${known_hosts[*]} - 1 )) ); do
		[ "${shost}" = "${known_hosts[${i}]}" ] && return
	done
	echo ${shost} > ~/.ssh/known_hosts
}

# ensure-rvm-gemset()
#
# Ensures that this script's environment is running under a proper RVM gemset
# that has the correct version of hammer-cli-katello installed for communicating
# with a Katello 2.4 server.
#
# no arguments
#
function ensure-rvm-gemset {
	if ! which rvm &>/dev/null; then
		echo "Y U NO USE RVM?"
		exit 1
	fi
	if [ "$( rvm current )" != "ruby-2.2.1@katello-perf" ]; then
		rvm_is_not_a_shell_function=0 rvm use ruby-2.2.1@katello-perf
	fi

	if ! gem contents hammer_cli_katello &>/dev/null; then
		gem install hammer_cli_katello --version 0.0.19
	fi
}

# verbosity()
#
# Outputs the proper verbose and debug flags for Hammer CLI to consume if the
# ${verbose} environment variable is set to ``true``.
#
# no arguments
#
function verbosity {
	local addl_opts=""
	[ ${verbose} == "true" ] && addl_opts="--verbose --debug"
	echo ${addl_opts}
}

# perfhammer( *hammer_args )
#
# A wrapper for Hammer CLI to be called from perfhammer.sh. This adds the proper
# options like username, password, server hostname, and Hammer configs to any
# calls being made via Hammer CLI.
#
# *hammer_args - Commands, sub-commands, and options passed straight through to
#                Hammer CLI.
#
function perfhammer {
	local hammer_args=$@

	hammer $( verbosity ) \
		--username ${username} \
		--password ${password} \
		--server https://${server} \
		--config ${perfhammer}/hammer-cfg \
		${hammer_args}
}

# organizations()
#
# Creates ${organization_count} number of organizations on the Katello 2.4 server
# specified in ${server}. This stores the names of all created organizations in
# the array ${organization_names}.
#
# no arguments
#
function organizations {
	local i
	local name

	for i in $( seq 1 ${organization_count} ); do
		name="perf-org-${i}"
		organization_names+=("${name}")
		perfhammer organization create --name ${name}
	done
}

# lifecycle-environments()
#
# Creates ${lifecycle_environment_count} number of lifecycle environments on the
# Katello 2.4 server specified in ${server}. This stores the names of all
# created lifecycle environments in the array ${lifecycle_environment_names}.
#
# no arguments
#
function lifecycle-environments {
	local i
	local name

	for i in $( seq 1 ${lifecycle_environment_count} ); do
		name="perf-lifecycle-env-${i}"
		lifecycle_environment_names+=("${name}")
		perfhammer lifecycle-environment create \
			--organization ${organization_names[0]} \
			--name ${name} \
			--prior Library
	done
}

# content-views()
#
# Creates ${content_view_count} number of content views on the Katello 2.4
# server specified in ${server}. This stores the names of all created content
# views in the array ${content_view_names}.
#
# no arguments
#
function content-views {
	local i
	local name

	for i in $( seq 1 ${content_view_count} ); do
		name="perf-content-view-${i}"
		content_view_names+=("${name}")
		perfhammer content-view create \
			--organization ${organization_names[0]} \
			--name ${name}
	done
}

# products()
#
# Creates ${product_count} number of products on the Katello 2.4 server
# specified in ${server}. This stores the names of all created products in the
# array ${product_names}.
#
# no arguments
#
function products {
	local i
	local name

	for i in $( seq 1 ${product_count} ); do
		name="perf-product-${i}"
		product_names+=("${name}")
		perfhammer product create \
			--organization ${organization_names[0]} \
			--name ${name}
	done
}

# prepare-repos()
#
# Creates ${repo_count} number of RPM repositories on the Katello 2.4 server's
# filesystem specified in ${server}. This stores the names of all created
# repositories in the array ${repo_names}.
#
# no arguments
#
function prepare-repos {
	local i
	local name
	local repo_name

	for i in $( seq 1 ${repo_count} ); do
		name="perf-repo-${i}"
		repo_names+=("${name}")
		repo_urls+=("http://${server}/pub/fakerepos/${name}/")
	done

	ssh root@${server} <<-END_ROOT_SSH
		mkdir -p ${pubdir}/fakerepos
		cd
		wget https://inecas.fedorapeople.org/fakerepos/zoo3.tar.gz
		tar xvzf zoo3.tar.gz
		for i in ${repo_names[*]}; do
			mkdir -p ${pubdir}/fakerepos/\${i}
			cp -r zoo3/* ${pubdir}/fakerepos/\${i}/
		done
		exit
	END_ROOT_SSH
}

# repos()
#
# Creates ${repo_count} number of repositories for every product on the Katello
# 2.4 server specified in ${server}.
#
# no arguments
#
function repos {
	local product
	local i
	local name
	local url

	for product in ${product_names[*]}; do
		for i in $( seq 0 $(( ${#repo_names[*]} - 1 )) ); do
			name="${repo_names[${i}]}"
			url="${repo_urls[${i}]}"
			perfhammer repository create \
				--organization ${organization_names[0]} \
				--product ${product} \
				--name ${name} \
				--url ${url} \
				--content-type yum \
				--publish-via-http true
		done
	done
}

# sync-repos()
#
# Synchronizes all created repositories in the Katello 2.4 server specified in
# ${server}.
#
# no arguments
#
function sync-repos {
	local product
	local i
	local repo_name

	for product in ${product_names[*]}; do
		for i in $( seq 0 $(( ${#repo_names[*]} - 1 )) ); do
			repo_name="${repo_names[${i}]}"
			perfhammer repository synchronize \
				--organization ${organization_names[0]} \
				--product ${product} \
				--name ${repo_name}
		done
	done
}

# main()
#
# This is the main function that prepares the environment for perfhammer.sh's
# operation calling all the above methods.
#
# no arguments
#
function main {
	set -x
	set -e

	readonly perfhammer="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
	readonly pubdir="/var/www/html/pub"

	readonly -A defaults=(
		[organization]=100
		[lifecycle_environment]=100
		[content_view]=100
		[product]=100
		[repo]=10
		[host]=1000
	)

	# Scale defaults to 100, as in 100%.
	declare -g scale username verbose
	scale=${scale:-100}
	username=${username:-admin}
	verbose=${verbose:-false}
	[ -z ${password+x} ] && read -r -p "katello password: " password
	[ -z ${server+x} ] && read -r -p "katello server url: " server

	declare -g organization_names=()
	declare -g lifecycle_environment_names=()
	declare -g content_view_names=()
	declare -g product_names=()
	declare -g repo_names=()
	declare -g repo_urls=()
	declare -g host_names=()

	setup-hammer-configs
	ensure-ssh-connectivity
	ensure-rvm-gemset
	counts
	organizations
	lifecycle-environments
	content-views
	products
	prepare-repos
	repos
	sync-repos
}

# big green "GO" button!
main
