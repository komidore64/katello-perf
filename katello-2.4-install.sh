#!/usr/bin/env bash
# vim: noet

set -x

cd
yum install -y ruby git
git clone https://github.com/Katello/katello-deploy.git
pushd katello-deploy
git checkout KATELLO-2.4
./setup.rb --version 2.4
popd

ruby -rpsych -e "p Psych.load_file('/etc/katello-installer/answers.katello-installer.yaml')['foreman']['admin_password']" \
  | tr -d '"' \
  | tee $HOME/admin_password
