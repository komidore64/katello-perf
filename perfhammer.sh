#!/usr/bin/env bash
# vim: noet

# $ ./perfhammer.sh # will prompt you for server's hostname and katello admin password
# $ server=katello24.server.example.com password=super-secret-password ./perfhammer.sh 2>&1 | tee katello-perf.log


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
	local file="${recordsdir}/${record_file:-perfhammer}.csv"

	if [ ! -w "${file}" ]; then
		mkdir -p "${recordsdir}"
		echo "elapsedtime [HH:]MM:SS,command" > "${file}"
	fi

	/usr/bin/time --output ${file} --append --format "%E,%C" -- "$@"
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

	shost="$( ssh-keyscan ${server} )"
	mapfile -t known_hosts < ~/.ssh/known_hosts
	for i in $( seq 0 $(( ${#known_hosts[*]} - 1 )) ); do
		if [ "${shost}" = "${known_hosts[${i}]}" ]; then return; fi
	done
	echo ${shost} > ~/.ssh/known_hosts
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

# hammer-verbosity()
#
# Outputs the proper verbose and debug flags for Hammer CLI to consume if the
# ${hammer_verbose} environment variable is set to ``true``.
#
# no arguments
#
function hammer-verbosity {
	local addl_opts=""
	if [ ${hammer_verbose} = "true" ]; then addl_opts="--verbose --debug"; fi
	echo ${addl_opts}
}

# hammer-async()
#
# Outputs the proper asynchronous flag for Hammer CLI to consume if the
# ${hammer_async} environment variable is set to ``true``.
#
# no arguments
#
function hammer-async {
	local addl_opts=""
	if [ ${hammer_async} = "true" ]; then addl_opts="--async"; fi
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
	local command_line="benchmark hammer $( hammer-verbosity ) --username ${username} --password ${password} --server https://${server} --config ${perfhammerdir}/hammer-cfg ${hammer_args}"

	if [ ${verbose} = "false" ]; then echo ${command_line}; fi
	eval "$command_line"
}

# display-environment()
#
# This is a helper function that outputs all of perfhammer's current variable
# values to the user just incase those would like to be logged also during a
# perfhammer run.
#
# no arguments
#
function display-environment {
	local var
	local -a vars=(
		manifest
		scale
		verbose
		bulldoze
		hammer_verbose
		hammer_async
		recordsdir
		server
		username
		password
		organization_count
		lifecycle_environment_count
		content_view_count
		product_count
		activation_key_count
		repo_count
		host_count
	)

	for var in ${vars[*]}; do
		echo "${var}: ${!var}"
	done
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
		perfhammer organization create --name ${name}
	done

	unset record_file
}

# import-manifest()
#
# Imports a manifest found in the current directory into the Katello 2.4 server
# specified in ${server}. If no manifest is found, this function exits and
# prevents any other RH product related functions from running because they
# would depend on a manifest existing in the Katello server.
#
# no arguments
#
function import-manifest {
	if [ -r "${manifest}" ]; then
		echo "manifest found"
		declare -g manifest_operations="true"
	else
		echo "no manifest found - skipping manifest import"
		declare -g manifest_operations="false"
		return
	fi

	perfhammer subscription upload --organization ${organization_names[0]} --file ${manifest}
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

	local library_id=$( perfhammer --output csv lifecycle-environment info --organization ${organization_names[0]} --name Library | grep -v ID | cut -d, -f1 )

	declare -g record_file="lifecycle_environment_create"

	for i in $( seq 1 ${lifecycle_environment_count} ); do
		name="perf-lifecycle-env-${i}"
		lifecycle_environment_names+=("${name}")
		perfhammer lifecycle-environment create --organization ${organization_names[0]} --name ${name} --prior-id ${library_id}
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
		perfhammer content-view create --organization ${organization_names[0]} --name ${name}
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
		perfhammer product create --organization ${organization_names[0]} --name ${name}
	done

	unset record_file
}

# rando-package-muncher()
#
# Creates ${repo_count} number of RPM repositories on the Katello 2.4 server's
# filesystem specified in ${server}. This stores the names of all created
# repositories in the array ${repo_names}.
#
# no arguments
#
function rando-package-muncher {
	local i
	local name
	local repo_name

	for i in $( seq 1 ${repo_count} ); do
		name="perf-repo-${i}"
		repo_names+=("${name}")
		repo_urls+=("http://${server}/pub/fakerepos/${name}/")
	done

	ssh -tt root@${server} <<-END_ROOT_SSH
		cd
		git clone https://github.com/mccun934/fakerpmrepo-generator
		cd fakerpmrepo-generator
		for i in ${repo_names[*]}; do
			./generate-repo.py -n 15 -p 1
			mkdir -pv ${pubdir}/fakerepos/\${i}
			mv -v /var/tmp/generated-repo/* ${pubdir}/fakerepos/\${i}/
			rm -rfv /var/tmp/generated-repo \$HOME/rpmbuild
		done
		restorecon -Rv /var/www/html
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
			perfhammer repository create --organization ${organization_names[0]} --product ${product} --name ${name} --url ${url} --content-type yum --publish-via-http true
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
			perfhammer repository synchronize --organization ${organization_names[0]} --product ${product} --name ${repo_name} $( hammer-async )
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
				perfhammer content-view add-repository --organization ${organization_names[0]} --product ${product} --repository ${repo} --name ${view}
			done
		done

		declare -g record_file="content_view_publish"
		perfhammer content-view publish --organization ${organization_names[0]} --name ${view} $( hammer-async )
	done

	unset record_file
}

# activation-keys()
#
# Creates ${activation_key_count} number of activation keys on the Katello 2.4
# server specified in ${server}. This stores the names of the activation keys
# in ${activation_key_names}.
#
# no arguments
#
function activation-keys {
	local name
	local i

	declare -g record_file="activation_key_create"

	for i in $( seq ${activation_key_count} ); do
		name="perf-activation-key-${i}"
		activation_key_names+=("${name}")
		perfhammer activation-key create --organization ${organization_names[0]} --lifecycle-environment ${lifecycle_environment_names[0]} --content-view ${content_view_names[0]} --name ${name}
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
	local host_create_json

	local org_id=$( perfhammer --output csv organization info --name ${organization_names[0]} | grep -v Id | cut -d, -f1 )
	local lfc_id=$( perfhammer --output csv lifecycle-environment info --organization-id ${org_id} --name Library | grep -v ID | cut -d, -f1 )
	local cv_id=$( perfhammer --output csv content-view info --organization-id ${org_id} --name '"Default Organization View"' | grep -v ID | cut -d, -f1 )

	declare -g record_file="host_create"

	for i in $( seq ${host_count} ); do

		name="perf-content-host-${i}"
		host_names+=("${name}")
		host_create_json='{ "name": "'${name}'", "organization_id": '${org_id}', "lifecycle_environment_id": '${lfc_id}', "content_view_id": '${cv_id}', "type": "system", "facts": { "system.certificate_version": "3.2", "network.hostname": "'${name}'", "cpu.core(s)_per_socket": 4, "memory.memtotal": "8GB", "uname.machine": "x86_64", "distribution.name": "RHEL", "distribution.version": "6.4", "virt.is_guest": false, "cpu.cpu(s)": 1 } }'
		curl -k -u admin:${password} -H "Content-Type: application/json" -X POST -d @<( echo ${host_create_json} ) "https://${server}/api/hosts/subscriptions"
	done

	unset record_file
}

# enable-redhat-repos()
#
# Enable some Red Hat repos on the Katello 2.4 server specified in ${server}.
#
# no arguments
#
function enable-redhat-repos {
	local -a el6_repo_sets=(
		[0]='"Red Hat Enterprise Linux 6 Server (RPMs)"'
		[1]='"Red Hat Enterprise Linux 6 Server - Optional (RPMs)"'
		[2]='"Red Hat Enterprise Linux 6 Server - RH Common (RPMs)"'
		[3]='"Red Hat Enterprise Linux 6 Server - Supplementary (RPMs)"'
	)

	local -a el7_repo_sets=(
		[0]='"Red Hat Enterprise Linux 7 Server (RPMs)"'
		[1]='"Red Hat Enterprise Linux 7 Server - Optional (RPMs)"'
		[2]='"Red Hat Enterprise Linux 7 Server - RH Common (RPMs)"'
		[3]='"Red Hat Enterprise Linux 7 Server - Supplementary (RPMs)"'
	)

	local i

	if [ "${manifest_operations}" = "false" ]; then
		echo "no manifest found - skipping redhat repo enablement"
		return
	fi

	declare -g record_file="redhat_repo_enable"

	for i in $( seq 0 $(( ${#el6_repo_sets[*]} - 1 )) ); do
		perfhammer repository-set enable --organization perf-org-1 --product '"'Red Hat Enterprise Linux Server'"' --name ${el6_repo_sets[${i}]} --releasever 6Server --basearch x86_64
	done

	for i in $( seq 0 $(( ${#el7_repo_sets[*]} - 1 )) ); do
		perfhammer repository-set enable --organization perf-org-1 --product '"'Red Hat Enterprise Linux Server'"' --name ${el7_repo_sets[${i}]} --releasever 7Server --basearch x86_64
	done

	unset record_file
}

# sync-redhat-repos()
#
# Sync some Red Hat repos that have been enabled on the Katello 2.4 server
# specified in ${server}.
#
# no arguments
#
function sync-redhat-repos {
	local -a redhat_repos=(
		[0]='"Red Hat Enterprise Linux 6 Server RPMs x86_64 6Server"'
		[1]='"Red Hat Enterprise Linux 6 Server - Optional RPMs x86_64 6Server"'
		[2]='"Red Hat Enterprise Linux 6 Server - RH Common RPMs x86_64 6Server"'
		[3]='"Red Hat Enterprise Linux 6 Server - Supplementary RPMs x86_64 6Server"'
		[4]='"Red Hat Enterprise Linux 7 Server RPMs x86_64 7Server"'
		[5]='"Red Hat Enterprise Linux 7 Server - Optional RPMs x86_64 7Server"'
		[6]='"Red Hat Enterprise Linux 7 Server - RH Common RPMs x86_64 7Server"'
		[7]='"Red Hat Enterprise Linux 7 Server - Supplementary RPMs x86_64 7Server"'
	)

	local i

	if [ "${manifest_operations}" = "false" ]; then
		echo "no manifest found - skipping redhat repo sync"
		return
	fi

	declare -g record_file="redhat_repo_sync"

	for i in $( seq 0 $(( ${#redhat_repos[*]} - 1 )) ); do
		perfhammer repository synchronize --organization perf-org-1 --product '"'Red Hat Enterprise Linux Server'"' --name ${redhat_repos[${i}]} $( hammer-async )
	done

	unset record_file
}

# cleanup()
#
# This function cleans up any unnecessary bits when perfhammer exits, as
# desired or otherwise.
#
# no arguments
#
function cleanup {
	sed -i /${server}/d $HOME/.ssh/known_hosts
}

# main()
#
# This is the main function that prepares the environment for perfhammer.sh's
# operation calling all the above methods.
#
# no arguments
#
function main {
	readonly perfhammerdir="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
	readonly pubdir="/var/www/html/pub"
	readonly manifest="${perfhammerdir}/manifest.zip"

	readonly -A defaults=(
		[organization]=10
		[lifecycle_environment]=10
		[content_view]=10
		[product]=10
		[activation_key]=10
		[repo]=10
		[host]=1000
	)

	# Scale defaults to 100, as in 100%.
	declare -g scale verbose hammer_verbose record_name recordsdir username password server
	bulldoze=${bulldoze:-false}
	scale=${scale:-100}
	verbose=${verbose:-false}
	hammer_verbose=${hammer_verbose:-false}
	hammer_async=${hammer_async:-false}
	record_name=${record_name:-""}
	recordsdir="${perfhammerdir}/records/$( date --iso-8601=minutes )${record_name}"
	if [ -z ${server+x} ]; then read -r -p "katello server hostname: " server; fi
	username=${username:-admin}
	if [ -z ${password+x} ]; then read -r -p "katello password: " password; fi

	declare -g organization_names=()
	declare -g lifecycle_environment_names=()
	declare -g content_view_names=()
	declare -g product_names=()
	declare -g repo_names=()
	declare -g repo_urls=()
	declare -g host_names=()
	declare -g activation_key_names=()

	declare -g rh_product="Red Hat Enterprise Linux Server"

	if [ ${verbose} = "true" ]; then set -x; fi
	if [ ${bulldoze} = "false" ]; then set -e; fi

	setup-hammer-configs
	ensure-ssh-connectivity
	ensure-packages-installed
	counts
	display-environment
	organizations
	import-manifest
	lifecycle-environments
	content-views
	products
	if [ ${bulldoze} = "false" ]; then rando-package-muncher; fi
	repos
	sync-repos
	publish-content-views
	hosts
	enable-redhat-repos
	sync-redhat-repos
}

trap cleanup EXIT
main
