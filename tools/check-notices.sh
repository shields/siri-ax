#!/bin/bash
# Copyright © 2026 Michael Shields
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail
cd "$(dirname "$0")/.."
while IFS= read -r -d '' notice_file; do
	case $notice_file in
	LICENSE | Package.resolved | bun.lock) continue ;;
	esac
	if ! rg -q 'Copyright © 2026 Michael Shields' "$notice_file"; then
		echo "Missing copyright: $notice_file" >&2
		exit 1
	fi
	if ! rg -q 'Apache License|Apache-2.0' "$notice_file"; then
		echo "Missing license: $notice_file" >&2
		exit 1
	fi
done < <(git ls-files --cached --others --exclude-standard -z)
