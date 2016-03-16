#!/usr/bin/env bash
# vim: noet

# ####################
# CAUTION - This has only been tested on Beaker machines running Centos7. Run
# at your own risk.
# ####################

set -x

cd # go home

# repartition
tar cvzf $HOME/home.tgz /home
umount /home
lvremove --force /dev/mapper/*home
sed -i '/home/d' /etc/fstab
lvresize --force --extents +100%FREE /dev/mapper/*root
resize2fs --force /dev/mapper/*root
tar xvzf $HOME/home.tgz --directory /

# install katello 2.4
yum install -y ruby git
git clone https://github.com/Katello/katello-deploy.git
pushd katello-deploy
git checkout KATELLO-2.4
./setup.rb --version 2.4 --skip-installer

# hax
sed -i 's/include ::apache::mod::passenger/&\n  include ::apache::mod::status/' \
	/usr/share/katello-installer/modules/foreman/manifests/config/passenger.pp

./setup.rb --version 2.4
popd

# get katello admin password
ruby -rpsych -e "p Psych.load_file('/etc/katello-installer/answers.katello-installer.yaml')['foreman']['admin_password']" \
	| tr -d '"' \
	| tee $HOME/admin_password
