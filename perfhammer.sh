#!/usr/bin/env bash
# vim: noet

# This script requires less interaction while running if you've added your
# public key to the server for ssh authentication during a couple calls made.

# Defaults for objects created during this population run are listed below in
# the `main` function. Any of these can be overridden by passing an environment
# variable to this script.

# $ organization_count=10 password=abcd12345678 server=stupid-slow.katello.com ./perfhammer.sh


function scale {
	local percentage=$1
	local default_value=$2

	echo "${percentage} * ${default_value} / 100" | bc
}

function counts {
	local index
	local var_name

	for index in ${!defaults[*]}; do
		var_name="${index}_count"
		[ -z ${!var_name+x} ] && declare ${var_name}=$( scale ${scale} ${defaults[${index}]} )
	done
}

function setup-hammer-configs {
	local module

	[ -d ${perfhammer}/hammer.cfg.d ] && return ## skip this if the configs are already setup

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

function verbosity {
	local addl_opts=""
	[ ${verbose} == "true" ] && addl_opts="--verbose --debug"
	echo ${addl_opts}
}

function perfhammer {
	hammer $( verbosity ) --username ${username} --password ${password} --server https://${server} --config ${perfhammer}/hammer-cfg $@
}

function organizations {
	local i
	local name

	for i in $( seq 1 ${organization_count} ); do
		name="perf-org-${i}"
		organization_names+=("${name}")
		perfhammer organization create --name ${name}
	done
}

function lifecycle-environments {
	local i
	local name

	for i in $( seq 1 ${lifecycle_environment_count} ); do
		name="perf-lifecycle-env-${i}"
		lifecycle_environment_names+=("${name}")
		perfhammer lifecycle-environment create --name ${name} --organization ${organization_names[0]} --prior Library
	done
}

function content-views {
	local i
	local name

	for i in $( seq 1 ${content_view_count} ); do
		name="perf-content-view-${i}"
		content_view_names+=("${name}")
		perfhammer content-view create --name ${name} --organization ${organization_names[0]}
	done
}

function products {
	local i
	local name

	for i in $( seq 1 ${product_count} ); do
		name="perf-product-${i}"
		product_names+=("${name}")
		perfhammer product create --name ${name} --organization ${organization_names[0]}
	done
}

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
				--name ${name} \
				--product ${product} \
				--url ${url} \
				--organization ${organization_names[0]} \
				--content-type yum \
				--publish-via-http true
		done
	done
}

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

function main {
	set -x
	set -e

	readonly perfhammer="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
	readonly pubdir="/var/www/html/pub"

	# -A for "associative array"
	readonly -A defaults=(
		[organization]=100
		[lifecycle_environment]=100
		[content_view]=100
		[product]=100
		[repo]=100
		[host]=1000
	)

	# Scale defaults to 100, as in 100%.
	scale=${scale:-100}

	username=${username:-admin}
	[ -z ${password+x} ] && read -r -p "katello password: " password
	[ -z ${server+x} ] && read -r -p "katello server url: " server
	verbose=${verbose:-false}

	organization_names=()
	lifecycle_environment_names=()
	content_view_names=()
	product_names=()
	repo_names=()
	repo_urls=()
	host_names=()

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

main
