<!--
Copyright © 2026 Michael Shields

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
-->

Use [right-answers](https://github.com/shields/right-answers) as the canonical
source for shared conventions, especially `swift.md` and `ci.md`.

Use `make build`, `make test`, `make lint`, `make fmt`, `make coverage`, and
`make run`. Install development dependencies with `make setup`.

- Everything except `Sources/SiriAXCLI/Live` is unit tested through the
  `SiriSurface`, `SystemProbe`, and `Timekeeper` protocols with fakes in
  `Tests/SiriAXTestSupport`. `Live` is the only code that calls the
  Accessibility API and needs a permitted terminal; keep it thin.
- Standard output is JSON and nothing else, for every subcommand and outcome.
  Help text and human diagnostics go to standard error. Do not add `print`
  calls; write through `Environment.out`.
- The guard fails closed and cannot be changed through the queue. A request file
  carries only `phrase` and `timeout_seconds`; nothing read from the queue is
  executed or used as a path. Do not add queue commands, in particular none that
  stop or reconfigure the runner.
- The AX identifiers in `SiriIdentifiers` are private to Siri AI and can change
  between macOS releases; fake trees in `FakeTrees` mirror what was observed on
  macOS 27.2.1.
