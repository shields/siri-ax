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


SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

.PHONY: setup ci-setup build test coverage lint fmt run

setup:
	bun install --frozen-lockfile
	lefthook install

ci-setup:
	brew install lefthook shellcheck shfmt zizmor ripgrep jq
	$(MAKE) setup

build:
	swift build --configuration release

test:
	swift test --enable-code-coverage

coverage: test
	./tools/coverage.sh

lint: actions-lock-verify-local
	./tools/check-notices.sh
	swift format lint --strict --recursive Package.swift Sources Tests
	bun run --bun --no-install prettier --check .
	shellcheck --external-sources tools/*.sh
	shfmt -d tools/*.sh
	zizmor --persona pedantic .github/workflows

fmt:
	swift format format --in-place --recursive Package.swift Sources Tests
	bun run --bun --no-install prettier --write .
	shfmt -w tools/*.sh

run: build
	.build/release/siri-ax doctor

.PHONY: actions-lock-install actions-lock actions-lock-verify-local actions-lock-verify

# `gh extension install` leaves an installed extension unchanged, and `--force`
# upgrades an out-of-date one to the latest release, unpinned. Remove it first.
actions-lock-install:
	installed=$$(gh extension list) && \
		if printf '%s\n' "$$installed" | grep -q '^gh actions-lock[[:space:]]'; then gh extension remove actions-lock; fi
	gh extension install github/gh-actions-lock --pin v0.5.1

actions-lock:
	gh actions-lock --no-interactive

actions-lock-verify-local:
	gh actions-lock --verify-local

actions-lock-verify:
	gh actions-lock --verify
