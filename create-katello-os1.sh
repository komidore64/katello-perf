#!/usr/bin/env bash

# vim: noet
#
# ##############################
# # settable env variables to avoid prompts
# ##############################
# - OPENSTACK_KEY_NAME
# - PORTAL_USERNAME
# - PORTAL_PASS
# - KT_VERSION
#
# ##############################
# # openstack-env.sh
# ##############################
# openstack-env.sh is a script which sets a handful of environment variables that the openstack command requires for operation.
# it can be downloaded from your friendly, neighborhood openstack. you know where to find it...

set -x
set -e

readonly SERVER_NAME="${OS_USERNAME}-katello-perf"

# source them-there OS env variables
if ! env | grep ^OS &>/dev/null; then
	source $( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )/openstack-env.sh
fi

if [ -z ${OPENSTACK_KEY_NAME+x} ]; then
	echo "enter your openstack key-name (used with --key-name on server creation)"
	read -r OPENSTACK_KEY_NAME
fi

if [ -z ${PORTAL_USERNAME+x} ]; then
	echo "enter your redhat portal username"
	read -r PORTAL_USERNAME
fi

if [ -z ${PORTAL_PASS+x} ]; then
	echo "enter your redhat portal password"
	read -sr PORTAL_PASS
fi


# a little strange, it is needed to work around a bug in setup.rb
read -p "install katello 2.4? (y/n) " answer
if [ "$answer" == "y" ]; then KT_VERSION='--version 2.4'
else KT_VERSION=''
fi

if ! which openstack &>/dev/null; then
	echo "please install 'python-openstackclient'"
	exit 1
fi

SERVER_UUID="$( openstack server create ${SERVER_NAME} \
	--flavor c3.xlarge \
	--image _OS1_rhel-guest-image-7.2-20151102.0.x86_64.qcow2 \
	--key-name ${OPENSTACK_KEY_NAME} \
	--security-group default \
	--wait | \
	grep '\<id\>' | \
	cut -d '|' -f3 | \
	tr -d ' ' )"

readonly SERVER_ADDRESS="$( openstack server show ${SERVER_UUID} --format shell --column addresses \
	| sed 's/.*"\(.*\)".*/\1/' \
	| cut -d= -f2 \
	| cut -d' ' -f 2 )"

[ -z "${SERVER_ADDRESS}" ] && exit 1 # bail if we don't get the IP address

if ! which nmap &>/dev/null; then
	echo "please install 'nmap'"
	exit 1
fi

SSH_UP=1
while [ ${SSH_UP} -gt 0 ]; do
	if nmap -p22 ${SERVER_ADDRESS} -oG - | grep -q 22/open; then
		SSH_UP=0
	fi
	sleep 1
done

ssh-keyscan -H ${SERVER_ADDRESS} >> ~/.ssh/known_hosts

ssh -tt cloud-user@${SERVER_ADDRESS} <<-END_OF_SHELL
	sudo su -l <<-END_OF_ROOT
		fdisk /dev/vdb <<-END_OF_FDISK
			o
			n
			p



			p
			w
		END_OF_FDISK

		mkfs.xfs /dev/vdb1
		mkdir -p /var/lib/pulp
		mount /dev/vdb1 /var/lib/pulp

		sed -i -e 's/vdb/vdb1/' -e 's/\/mnt/\/var\/lib\/pulp/' /etc/fstab
		exit
	END_OF_ROOT
	exit
END_OF_SHELL

ssh -t cloud-user@${SERVER_ADDRESS} sudo subscription-manager register \
	--username ${PORTAL_USERNAME} \
	--password ${PORTAL_PASS} \
	--auto-attach

ssh -t cloud-user@${SERVER_ADDRESS} sudo sed -i \'s/enabled = 1/enabled = 0/\' /etc/yum.repos.d/redhat.repo

ssh -t cloud-user@${SERVER_ADDRESS} sudo yum-config-manager \
	--enable rhel-7-server-rpms \
	--save

# for 2.4, apply this installer patch. See https://github.com/Katello/puppet-candlepin/pull/36/
scp foreman-redmine-13361.patch cloud-user@${SERVER_ADDRESS}:

# install katello 2.4 yall
ssh -tt cloud-user@${SERVER_ADDRESS} <<-END_OF_SHELL
	sudo su -l <<-END_OF_ROOT
		cd # go home, lassie
		yum install -y git ruby
		git clone https://github.com/katello/katello-deploy.git
		cd katello-deploy
		./setup.rb ${KT_VERSION} --skip-installer
		yum install -y patch; patch /usr/share/katello-installer/modules/candlepin/manifests/service.pp < /home/cloud-user/foreman-redmine-13361.patch
		./setup.rb ${KT_VERSION}

		yum install -y tfm-rubygem-hammer_cli_csv

		# brace yourself, hack is coming
		# TODO: this part doesn't work yet :(
		# sed -i '/gettext/d' $( rpm -ql tfm-rubygem-hammer_cli_csv | grep gemspec )

		# katello admin password
		ruby -rpsych -e "p Psych.load_file('/etc/katello-installer/answers.katello-installer.yaml')['foreman']['admin_password']" | tr -d '"' > \$HOME/admin_password
		exit
	END_OF_ROOT
	exit
END_OF_SHELL
