#!/bin/bash

# This script looks up movies on IMDb, and displays information about
# them.

# Usage: imdb.sh "Movie Title (Year)"

# (The year is optional, and only recommended for more accurate search
# results. The paranthesis around 'Year' are required for proper
# parsing.)

# This creates a function called 'uriencode', which will translate
# the special characters in any string to be URL friendly. This will be
# used in the 'imdb' function.
uriencode () {
	curl -Gso /dev/null -w %{url_effective} --data-urlencode @- "" <<<"${@}" | sed -E 's/..(.*).../\1/'
}

# Creates a function called 'c_time_calc', which will translate seconds
# into the HH:MM:SS format.
c_time_calc () {
	s="$1"

# While $s (seconds) is equal to (or greater than) 60, clear the $s
# variable and add 1 to the $m (minutes) variable.
	while [[ $s -ge 60 ]]; do
		m=$(( m + 1 ))
		s=$(( s - 60 ))
	done

# While $m (minutes) is equal to (or greater than) 60, clear the $m
# variable and add 1 to the $h (hours) variable.
	while [[ $m -ge 60 ]]; do
		h=$(( h + 1 ))
		m=$(( m - 60 ))
	done

# While $h (hours) is equal to 100 (or greater than), clear the $h
# variable.
	while [[ $h -ge 100 ]]; do
		h=$(( h - 100 ))
	done

	printf '%02d:%02d:%02d' "$h" "$m" "$s"
}

# This creates a function called 'imdb', which will look up the movie
# name on IMDb.
imdb () {
	term="${@}"
	t_y_regex='^(.*) \(([0-9]{4})\)$'
	id_regex='<a href=\"/title/(tt[0-9]{4,})/'
	title_regex1='\,\"originalTitleText\":'
	title_regex2='\"text\":\"(.*)\"\,\"__typename\":\"TitleText\"'
	year_regex1='\,\"releaseYear\":'
	year_regex2='\"year\":([0-9]{4})\,\"endYear\":.*\,\"__typename\":\"YearRange\"'
	plot_regex1='\"plotText\":'
	plot_regex2='\"plainText\":\"(.*)\"\,\"__typename\":\"Markdown\"'
	rating_regex1='\,\"ratingsSummary\":'
	rating_regex2='\"aggregateRating\":(.*)\,\"voteCount\":.*\,\"__typename\":\"RatingsSummary\"'
	genre_regex1='\"genres\":\['
	genre_regex2='\"text\":\"(.*)\"\,\"id\":\".*\"\,\"__typename\":\"Genre\"'
	director_regex1='\]\,\"director\":\['
	director_regex2='\"@type\":\"Person\",\"url\":\".*\"\,\"name\":\"(.*)\"'
	runtime_regex1='\,\"runtime\":'
	runtime_regex2='\"seconds\":(.*)\,\"__typename\":\"Runtime\"'


# agent='Lynx/2.8.9rel.1 libwww-FM/2.14 SSL-MM/1.4.1 OpenSSL/1.1.1d'
	agent='Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/103.0.0.0 Safari/537.36'

	get_page () {
		curl --location --user-agent "${agent}" --retry 10 --retry-delay 10 --connect-timeout 10 --silent "${1}" 2>&-
	}

	if [[ $# -eq 0 ]]; then
		printf '%s\n' 'Usage: imdb "Movie Title (Year)"'
		return 1
	else
		t=$(uriencode "$(sed -E "s/${t_y_regex}/\1/" <<<"${term}")")

		if [[ $term =~ $t_y_regex ]]; then
			y=$(sed -E "s/${t_y_regex}/\2/" <<<"${term}")
		else
			y='0000'
		fi
	fi

# Sets the type of IMDb search results to include.
	type='feature,tv_movie,tv_special,documentary,video'

# If the year is set to '0000', that means it's unknown, hence we will
# need to use slightly different URLs, when searching for the movie.
# https://www.imdb.com/interfaces/
	if [[ $y == '0000' ]]; then
		url_tmp="https://www.imdb.com/search/title/?title=${t}&title_type=${type}&view=simple"
	else
		url_tmp="https://www.imdb.com/search/title/?title=${t}&title_type=${type}&release_date=${y},${y}&view=simple"
	fi

	id=$(get_page "${url_tmp}" | grep -Eo "$id_regex" | sed -E "s|${id_regex}|\1|" | head -n 1)

	if [[ -z $id ]]; then
		return 1
	fi

	url="https://www.imdb.com/title/${id}/"

# Translate {} characters to newlines so we can parse the JSON data.
# I came to the conclusion that this is the most simple, reliable and
# future-proof way to get the movie information. It's possible to add
# more regex:es to the for loop below, to get additional information.
# Excluding lines that are longer than 500 characters, to make it
# slightly faster.
	mapfile -t tmp_array < <(get_page "$url" | tr '{}' '\n' | grep -Ev '.{500}')

	n=0

	declare -A json_types

	json_types=(['title']=1 ['year']=1 ['plot']=1 ['rating']=1 ['genre']=1 ['director']=1 ['runtime']=1)

	for (( z = 0; z < ${#tmp_array[@]}; z++ )); do
		for json_type in "${!json_types[@]}"; do
			json_regex1_ref="${json_type}_regex1"
			json_regex2_ref="${json_type}_regex2"

			if [[ "${tmp_array[${z}]}" =~ ${!json_regex1_ref} ]]; then
				n=$(( z + 1 ))
				eval ${json_type}=\"$(sed -E "s/${!json_regex2_ref}/\1/" <<<"${tmp_array[${n}]}")\"
				unset -v json_types[${json_type}]
				break
			fi
		done
	done

	runtime=$(c_time_calc "$runtime")

	cat <<IMDB
${title} (${year})
${url}

Rating: ${rating}

Genre: ${genre}

Runtime: ${runtime}

Plot summary:
${plot}

Director: ${director}

IMDB

	unset -v title year plot rating genre director runtime
}

imdb "{$@}"
