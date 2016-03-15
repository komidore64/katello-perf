#!/usr/bin/env bash
# vim: noet

# $ ./perfhammer.sh # will prompt you for server's hostname and katello admin password
# $ server=katello24.server.example.com password=super-secret-unguessable-password ./perfhammer.sh


# scale( value, percent )
#
# Scale the given value by a percentage. For example, "Give me 20% of 100" would
# be ``scale 100 20``.
#
# value   - The integer to be scaled.
# percent - An integer representative of the percent you wish to scale
#           ``value`` by. This value should be greater than zero.
#
function scale {
	local value=$1
	local percent=$2

	echo "${percent} * ${value} / 100" | bc
}

# benchmark( *command_line )
#
# Records the amount of time it takes for ``*command_line`` to complete. This
# uses GNU time rather than Bash's built-in time command.
#
# *command_line - Command line string to be executed in Bash.
#
function benchmark {
	local command_line=$@
	local file="${recordsdir}/${record_file:-perfhammer}.csv"

	if [ ! -w "${file}" ]; then
		mkdir -p "${recordsdir}"
		echo "usermode,kernelmode,elapsedtime,cpu%,command" > "${file}"
	fi

	/usr/bin/time \
		--output ${file} \
		--append \
		--format "%U,%S,%E,%P,%C" \
		${command_line}
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
		if [ -z ${!var_name+x} ]; then declare -g ${var_name}=$( scale ${defaults[${index}]} ${scale} ); fi
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

	if [ -d ${perfhammerdir}/hammer-cfg ]; then return; fi # skip this if the configs are already set up

	mkdir -p ${perfhammerdir}/hammer-cfg/cli.modules.d
	cat > ${perfhammerdir}/hammer-cfg/cli_config.yml <<-END_CLI_CONFIG_YML
		:ui:
		  :interactive: true
		  :per_page: 9999
		  :history_file: '${perfhammerdir}/hammer-cfg/history'
		:watch_plain: false
		:reload_cache: true
		:log_dir: '${perfhammerdir}/hammer-cfg/log'
		:log_level: 'debug'
	END_CLI_CONFIG_YML

	for module in foreman foreman_bootdisk foreman_docker foreman_tasks katello; do
		cat > ${perfhammerdir}/hammer-cfg/cli.modules.d/${module}.yml <<-END_MODULE_CONFIG
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
		if [ "${shost}" = "${known_hosts[${i}]}" ]; then return; fi
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

# ensure-packages-installed()
#
# Make sure that bc and GNU time are installed before running perfhammer.sh.
#
# no arguments
#
function ensure-packages-installed {
	local -a packages=(
		bc
		time
	)
	local pkg
	local barf=false

	for pkg in ${packages[*]}; do
		if ! which ${pkg} &>/dev/null; then
			echo "${pkg} is needed for perfhammer.sh to run."
			barf=true
		fi
	done
	if [ "${barf}" = "true" ]; then exit 1; fi
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
	if [ ${verbose} == "true" ]; then addl_opts="--verbose --debug"; fi
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

	benchmark \
		hammer $( verbosity ) \
		--username ${username} \
		--password ${password} \
		--server https://${server} \
		--config ${perfhammerdir}/hammer-cfg \
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

	declare -g record_file="organization_create"

	for i in $( seq 1 ${organization_count} ); do
		name="perf-org-${i}"
		organization_names+=("${name}")
		perfhammer \
			organization create \
			--name ${name}
	done

	unset record_file
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

	declare -g record_file="lifecycle_environment_create"

	for i in $( seq 1 ${lifecycle_environment_count} ); do
		name="perf-lifecycle-env-${i}"
		lifecycle_environment_names+=("${name}")
		perfhammer \
			lifecycle-environment create \
			--organization ${organization_names[0]} \
			--name ${name} \
			--prior Library
	done

	unset record_file
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

	declare -g record_file="content_view_create"

	for i in $( seq 1 ${content_view_count} ); do
		name="perf-content-view-${i}"
		content_view_names+=("${name}")
		perfhammer \
			content-view create \
			--organization ${organization_names[0]} \
			--name ${name}
	done

	unset record_file
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

	declare -g record_file="product_create"

	for i in $( seq 1 ${product_count} ); do
		name="perf-product-${i}"
		product_names+=("${name}")
		perfhammer \
			product create \
			--organization ${organization_names[0]} \
			--name ${name}
	done

	unset record_file
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

	declare -g record_file="repo_create"

	for product in ${product_names[*]}; do
		for i in $( seq 0 $(( ${#repo_names[*]} - 1 )) ); do
			name="${repo_names[${i}]}"
			url="${repo_urls[${i}]}"
			perfhammer \
				repository create \
				--organization ${organization_names[0]} \
				--product ${product} \
				--name ${name} \
				--url ${url} \
				--content-type yum \
				--publish-via-http true
		done
	done

	unset record_file
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

	declare -g record_file="repo_sync"

	for product in ${product_names[*]}; do
		for i in $( seq 0 $(( ${#repo_names[*]} - 1 )) ); do
			repo_name="${repo_names[${i}]}"
			perfhammer \
				repository synchronize \
				--organization ${organization_names[0]} \
				--product ${product} \
				--name ${repo_name}
		done
	done

	unset record_file
}

# publish-content-views()
#
# Adds all products to each content view then publishes a new contenv view
# version for each on the Katello 2.4 server specified in ${server}.
#
# no arguments
#
function publish-content-views {
	local view
	local product
	local repo

	for view in ${content_view_names[*]}; do
		for product in ${product_names[*]}; do
			for repo in ${repo_names[*]}; do
				declare -g record_file="content_view_add_repository"
				perfhammer \
					content-view add-repository \
					--organization ${organization_names[0]} \
					--product ${product} \
					--repository ${repo} \
					--name ${view}
			done
		done

		declare -g record_file="content_view_publish"
		perfhammer \
			content-view publish \
			--organization ${organization_names[0]} \
			--name ${view}
	done

	unset record_file
}

# hosts()
#
# Creates ${host_count} number of content hosts on the Katello 2.4 server
# specified in ${server}. This stores the names of the content hosts in
# ${host_names}.
#
# no arguments
#
function hosts {
	local i
	local name

	declare -g record_file="host_create"

	for i in $( seq 1 ${host_count} ); do
		name="perf-host-${i}"
		host_names+=("${name}")
		perfhammer \
			content-host create \
			--organization ${organization_names[0]} \
			--content-view ${content_view_names[0]} \
			--name ${name} \
		# is this right?!
	done

	unset record_file
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

	readonly perfhammerdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
	readonly pubdir="/var/www/html/pub"
	readonly recordsdir="${perfhammerdir}/records/$( date +%F_%T )"

	readonly -A defaults=(
		[organization]=10
		[lifecycle_environment]=10
		[content_view]=10
		[product]=10
		[repo]=10
		[host]=1000
	)

	# Scale defaults to 100, as in 100%.
	declare -g scale username verbose
	scale=${scale:-100}
	username=${username:-admin}
	verbose=${verbose:-false}
	if [ -z ${server+x} ]; then read -r -p "katello server hostname: " server; fi
	if [ -z ${password+x} ]; then read -r -p "katello password: " password; fi

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
	ensure-packages-installed
	counts
	organizations
	lifecycle-environments
	content-views
	products
	prepare-repos
	repos
	sync-repos
	publish-content-views
	hosts
}

# big green "GO" button!
main
