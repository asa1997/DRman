#!/usr/bin/env bash

#
#   Copyright 2020 the original author or authors.
#
#   Licensed under the Apache License, Version 2.0 (the "License");
#   you may not use this file except in compliance with the License.
#   You may obtain a copy of the License at
#
#       http://www.apache.org/licenses/LICENSE-2.0
#
#   Unless required by applicable law or agreed to in writing, software
#   distributed under the License is distributed on an "AS IS" BASIS,
#   WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
#   See the License for the specific language governing permissions and
#   limitations under the License.
#

function __drm_install() {
	local candidate version folder

	candidate="$1"
	version="$2"
	folder="$3"

	__drman_check_candidate_present "$candidate" || return 1
	__drman_determine_version "$candidate" "$version" "$folder" || return 1

	if [[ -d "${DRMAN_CANDIDATES_DIR}/${candidate}/${VERSION}" || -L "${DRMAN_CANDIDATES_DIR}/${candidate}/${VERSION}" ]]; then
		echo ""
		__drman_echo_red "Stop! ${candidate} ${VERSION} is already installed."
		return 1
	fi

	if [[ ${VERSION_VALID} == 'valid' ]]; then
		__drman_determine_current_version "$candidate"
		__drman_install_candidate_version "$candidate" "$VERSION" || return 1

		if [[ "$drman_auto_answer" != 'true' && "$auto_answer_upgrade" != 'true' && -n "$CURRENT" ]]; then
			__drman_echo_confirm "Do you want ${candidate} ${VERSION} to be set as default? (Y/n): "
			read USE
		fi

		if [[ -z "$USE" || "$USE" == "y" || "$USE" == "Y" ]]; then
			echo ""
			__drman_echo_green "Setting ${candidate} ${VERSION} as default."
			__drman_link_candidate_version "$candidate" "$VERSION"
			__drman_add_to_path "$candidate"
		fi

		return 0
	elif [[ "$VERSION_VALID" == 'invalid' && -n "$folder" ]]; then
		__drman_install_local_version "$candidate" "$VERSION" "$folder" || return 1
	else
		echo ""
		__drman_echo_red "Stop! $1 is not a valid ${candidate} version."
		return 1
	fi
}

function __drman_install_candidate_version() {
	local candidate version

	candidate="$1"
	version="$2"

	__drman_download "$candidate" "$version" || return 1
	__drman_echo_green "Installing: ${candidate} ${version}"

	mkdir -p "${DRMAN_CANDIDATES_DIR}/${candidate}"

	rm -rf "${DRMAN_DIR}/tmp/out"
	unzip -oq "${DRMAN_DIR}/archives/${candidate}-${version}.zip" -d "${DRMAN_DIR}/tmp/out"
	mv "$DRMAN_DIR"/tmp/out/* "${DRMAN_CANDIDATES_DIR}/${candidate}/${version}"
	__drman_echo_green "Done installing!"
	echo ""
}

function __drman_install_local_version() {
	local candidate version folder version_length version_length_max

	version_length_max=15

	candidate="$1"
	version="$2"
	folder="$3"

	# Validate max length of version
	version_length=${#version}
	__drman_echo_debug "Validating that actual version length ($version_length) does not exceed max ($version_length_max)"

	if [[ $version_length -gt $version_length_max ]]; then
		__drman_echo_red "Invalid version! ${version} with length ${version_length} exceeds max of ${version_length_max}!"
		return 1
	fi

	mkdir -p "${DRMAN_CANDIDATES_DIR}/${candidate}"

	# handle relative paths
	if [[ "$folder" != /* ]]; then
		folder="$(pwd)/$folder"
	fi

	if [[ -d "$folder" ]]; then
		__drman_echo_green "Linking ${candidate} ${version} to ${folder}"
		ln -s "$folder" "${DRMAN_CANDIDATES_DIR}/${candidate}/${version}"
		__drman_echo_green "Done installing!"
	else
		__drman_echo_red "Invalid path! Refusing to link ${candidate} ${version} to ${folder}."
		return 1
	fi

	echo ""
}

function __drman_download() {
	local candidate version archives_folder

	candidate="$1"
	version="$2"

	archives_folder="${DRMAN_DIR}/archives"
	if [ ! -f "${archives_folder}/${candidate}-${version}.zip" ]; then
		local platform_parameter="$(echo $DRMAN_PLATFORM | tr '[:upper:]' '[:lower:]')"
		local download_url="${DRMAN_CANDIDATES_API}/broker/download/${candidate}/${version}/${platform_parameter}"
		local base_name="${candidate}-${version}"
		local zip_archive_target="${DRMAN_DIR}/archives/${candidate}-${version}.zip"

		# pre-installation hook: implements function __drman_pre_installation_hook
		local pre_installation_hook="${DRMAN_DIR}/tmp/hook_pre_${candidate}_${version}.sh"
		__drman_echo_debug "Get pre-installation hook: ${DRMAN_CANDIDATES_API}/hooks/pre/${candidate}/${version}/${platform_parameter}"
		__drman_secure_curl "${DRMAN_CANDIDATES_API}/hooks/pre/${candidate}/${version}/${platform_parameter}" >| "$pre_installation_hook"
		__drman_echo_debug "Copy remote pre-installation hook: $pre_installation_hook"
		source "$pre_installation_hook"
		__drman_pre_installation_hook || return 1
		__drman_echo_debug "Completed pre-installation hook..."

		export local binary_input="${DRMAN_DIR}/tmp/${base_name}.bin"
		export local zip_output="${DRMAN_DIR}/tmp/$base_name.zip"

		echo ""
		__drman_echo_no_colour "Downloading: ${candidate} ${version}"
		echo ""
		__drman_echo_no_colour "In progress..."
		echo ""

		# download binary
		__drman_secure_curl_download "${download_url}" --output "${binary_input}"
		__drman_echo_debug "Downloaded binary to: ${binary_input}"

		# post-installation hook: implements function __drman_post_installation_hook
		# responsible for taking `binary_input` and producing `zip_output`
		local post_installation_hook="${DRMAN_DIR}/tmp/hook_post_${candidate}_${version}.sh"
		__drman_echo_debug "Get post-installation hook: ${DRMAN_CANDIDATES_API}/hooks/post/${candidate}/${version}/${platform_parameter}"
		__drman_secure_curl "${DRMAN_CANDIDATES_API}/hooks/post/${candidate}/${version}/${platform_parameter}" >| "$post_installation_hook"
		__drman_echo_debug "Copy remote post-installation hook: ${post_installation_hook}"
		source "$post_installation_hook"
		__drman_post_installation_hook || return 1
		__drman_echo_debug "Processed binary as: $zip_output"
		__drman_echo_debug "Completed post-installation hook..."

		mv "$zip_output" "$zip_archive_target"
		__drman_echo_debug "Moved to archive folder: $zip_archive_target"
	else
		echo ""
		__drman_echo_no_colour "Found a previously downloaded ${candidate} ${version} archive. Not downloading it again..."
	fi
	__drman_validate_zip "${archives_folder}/${candidate}-${version}.zip" || return 1
	echo ""
}

function __drman_validate_zip() {
	local zip_archive zip_ok

	zip_archive="$1"
	zip_ok=$(unzip -t "$zip_archive" | grep 'No errors detected in compressed data')
	if [ -z "$zip_ok" ]; then
		rm "$zip_archive"
		echo ""
		__drman_echo_red "Stop! The archive was corrupt and has been removed! Please try installing again."
		return 1
	fi
}
