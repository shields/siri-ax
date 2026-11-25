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

# Reports line coverage of the testable code. The Accessibility layer under
# Sources/SiriAXCLI/Live needs a permitted terminal and a running Siri AI, so it
# is excluded from the check.
set -euo pipefail
cd "$(dirname "$0")/.."
bin=$(swift build --show-bin-path)
core=$bin/SiriAXCoreTests.xctest/Contents/MacOS/SiriAXCoreTests
cli=$bin/SiriAXCLITests.xctest/Contents/MacOS/SiriAXCLITests
profile=$bin/codecov/default.profdata
files=(Sources/SiriAXCore/*.swift Sources/SiriAXCLI/*.swift)
xcrun llvm-cov report "$core" -object "$cli" --instr-profile "$profile" "${files[@]}"
percent=$(xcrun llvm-cov export "$core" -object "$cli" --instr-profile "$profile" \
	--summary-only "${files[@]}" | jq '.data[0].totals.lines.percent')
echo "line coverage: $percent%"
if ! jq -n --argjson p "$percent" '$p >= 97' | grep -q true; then
	echo "line coverage is below 97%" >&2
	exit 1
fi
