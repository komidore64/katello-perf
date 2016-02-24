#!/usr/bin/env bash

# vim: noet

function ensure-rvm-gemset () {
	if [ "$( rvm current )" != "ruby-2.2.1@hammer-cli-katello-0.0.19" ]; then
		rvm_is_not_a_shell_function=0 rvm use ruby-2.2.1@hammer-cli-katello-0.0.19
	fi
}

function phammer () {
	hammer -v -d $@
}

function main () {
	local i

	ensure-rvm-gemset

	for i in $( seq 1 1000 ); do
		phammer organization create --name perf-org-$i
	done
}

main
