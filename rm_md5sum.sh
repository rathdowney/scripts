#!/bin/sh

# This script removes duplicate files in the directory given as
# argument. The files with the oldest modification date will be
# considered to be the originals, when other files with the same MD5
# hash are found.

if [[ ! -d $1 ]]; then
	exit
fi

dn=$(readlink -f "$1")

mapfile -t files < <(find "$dn" -type f -iname "*" 2>&-)

declare -A md5s_date md5s_fn md5s_og

for (( i = 0; i < ${#files[@]}; i++ )); do
	fn="${files[${i}]}"

	md5_fn=$(md5sum -b <<<"$fn" | cut -d' ' -f1)
	md5=$(md5sum -b "$fn" | cut -d' ' -f1)
	date=$(stat -c '%s' "$fn")

	if [[ ! -z ${md5s_date[${md5}]} ]]; then
		if [[ $date -lt ${md5s_date[${md5}]} ]]; then
			md5s_date[${md5}]="$date"
			md5s_og[${md5}]="$fn"
		fi
	else
		md5s_date[${md5}]="$date"
		md5s_og[${md5}]="$fn"
	fi

	md5s_fn[${md5_fn}]="$md5"
done

for (( i = 0; i < ${#files[@]}; i++ )); do
	fn="${files[${i}]}"

	md5_fn=$(md5sum -b <<<"$fn" | cut -d' ' -f1)
	md5="${md5s_fn[${md5_fn}]}"

	if [[ ! -z ${md5s_og[${md5}]} ]]; then
		if [[ "$fn" != "${md5s_og[${md5}]}" ]]; then
			printf '%s\n' "$fn"
			rm -f "$fn"
		fi
	fi
done
