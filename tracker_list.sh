#!/bin/bash
# This script parses a BitTorrent tracker list text file, sorts, removes
# duplicates, checks online status of each URL, and prints the list to
# STDOUT in the correct format.

# The second argument to the script (-nocheck), is optional. If used,
# the online status of trackers will not be checked, but the list will
# only get sorted and rid of duplicates.

# Only the trackers that are still online will be printed. This is
# useful to clean up old lists of public trackers that can be found
# online, as an example. Though, it might be a good idea to run the
# script a couple of times, waiting a few hours or days inbetween, since
# a tracker could be only temporarily offline.

# If you want to save the list in a text file, you can just do a
# redirection like so:

# tracker_list.sh 'trackers.txt' | tee 'trackers_checked.txt'

usage () {
	printf '%s\n\n' "Usage: $(basename "$0") [tracker txt] [-nocheck]"
	exit
}

if [[ -z $1 || ! -f $1 ]]; then
	usage
elif [[ ! -z $2 && $2 != '-nocheck' ]]; then
	usage
fi

nocheck=0

if [[ $2 == '-nocheck' ]]; then
	nocheck=1
fi

if=$(readlink -f "$1")
switch=0

declare -a trackers

mapfile -t lines < <(sort --unique <"$if")

for (( i = 0; i < ${#lines[@]}; i++ )); do
	line=$(tr -d '[:space:]' <<<"${lines[${i}]}")
	switch=0

	if [[ ! -z $line ]]; then
		for (( j = 0; j < ${#trackers[@]}; j++ )); do
			line_tmp=$(sed -e 's_/$__' -e 's_/announce__' <<<"$line")
			grep --quiet "$line_tmp" <<<"${trackers[${j}]}"

			if [[ $? -eq 0 ]]; then
				switch=1

				array_l="${#trackers[${j}]}"
				line_l="${#line}"

				if [[ $line_l > $array_l && $line =~ /announce$ ]]; then
					trackers[${j}]="$line"
				fi
			fi
		done

		if [[ $switch -eq 0 ]]; then
			trackers+=("$line")
		fi
	fi
done

declare -A md5h

for (( i = 0; i < ${#trackers[@]}; i++ )); do
	tracker=$(tr -d '[:space:]' <<<"${trackers[${i}]}")

	if [[ $nocheck -eq 1 ]]; then
		printf '%s\n\n' "$tracker"

		continue
	fi

	curl --retry 8 --silent --output /dev/null "$tracker"

	if [[ $? -ne 0 ]]; then
		address=$(sed -e 's_^.*//__' -e 's_:[0-9]*__' -e 's_/.*$__' <<<"$tracker")
		ping -c 10 "$address" &> /dev/null

		if [[ $? -eq 0 ]]; then
			printf '%s\n\n' "$tracker"
		fi
	elif [[ $? -eq 0 ]]; then
		printf '%s\n\n' "$tracker"
	fi
done
