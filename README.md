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

# siri-ax

`siri-ax` sends a phrase to the Siri AI app on macOS 27 through the
Accessibility (AX) API and prints Siri’s answer as JSON, so that an AI agent can
drive Siri and read what it said. For example, an agent testing a HomeKit bridge
can ask Siri to “set lamp to cool white”, then look at what the bridge received.

It is a command-line tool for agents. Standard output carries one JSON object
per result and nothing else, for every subcommand and every outcome, including
refusals and errors. Help text and human-oriented diagnostics go to standard
error.

It is not a Siri client library, a speech tool, or an MCP server. It does not
read older Siri surfaces, does not support macOS 26’s overlay, and does not use
AppleScript or System Events.

## Requirements

- macOS 27 with the Siri AI app (`/System/Applications/Siri AI.app`, bundle ID
  `com.apple.campo`) and Siri enabled.
- Swift 6.4 to build.
- Accessibility permission for the terminal app that runs `siri-ax`.

## Build

```sh
make build            # .build/release/siri-ax
make test lint        # unit tests and lint
```

## Accessibility permission

macOS grants Accessibility to an app, not to a binary. Grant it to the terminal
app you start `siri-ax` from: System Settings → Privacy & Security →
Accessibility, add the terminal app, and turn it on. Then check:

```sh
siri-ax doctor
```

`accessibility_trusted` must be `true`.

**The stale-grant trap.** A grant can show as enabled in System Settings and
still be refused (`AXIsProcessTrusted` returns false), typically after the
terminal app was updated or replaced. Toggling it off and on does not always
help. Remove the entry with the − button and add the app again. A terminal app
that never had a grant, such as a fresh Terminal.app entry, works.

A process inside an agent sandbox cannot use Accessibility and must not try to
get around that. Run `siri-ax serve` in your own terminal and let the sandboxed
agent use the queue ([below](#the-queue-protocol)).

## Commands

```text
siri-ax ask [--guard FILE] [--allow PATTERN]... [--timeout SECONDS] [--settle SECONDS] [--] PHRASE
siri-ax serve [--guard FILE] [--allow PATTERN]... [--settle SECONDS] QUEUE-DIR
siri-ax doctor
```

`ask` starts a new conversation (so earlier turns cannot influence the answer),
submits the phrase, waits for the answer to settle, and prints one result.
`--timeout` is the number of seconds to wait for the answer, 1–120, default 20.
It covers the answer wait only: up to about 15 seconds of waiting for the window
and for the new conversation come before it. The first request after Siri AI
launches can take most of a minute, so use a longer timeout then. `--settle` is
how long the answer must stay unchanged to count as settled, 0.4–30 seconds,
default 1.2, and must be less than `--timeout`.

`serve` answers request files from a queue directory until it receives SIGINT or
SIGTERM, and logs JSON Lines events to stdout. It checks Accessibility and that
Siri AI is installed at startup and exits with an error if not. It also refuses
to start with no allow patterns (`config_invalid`), since it could only refuse
every request. If the queue becomes unwritable while it runs, it stops with a
failure line and exit 3 after any events already logged.

`doctor` reports whether Accessibility is granted, whether Siri AI is installed,
running, and windowed, and the macOS version. A running app without a window is
fine: `ask` and `serve` open one. Without Accessibility permission `doctor`
cannot count windows, so it reports `siri_has_window` false even if one exists.

`--help` prints to stderr and leaves stdout empty. A usage error prints a JSON
error with code `usage` and exits 64.

### Exit codes

| Code | Meaning                                                    |
| ---- | ---------------------------------------------------------- |
| 0    | `answered`, doctor `ready`, or `serve` stopped by a signal |
| 1    | `no_answer`, or doctor `not_ready`                         |
| 2    | `refused` by the guard                                     |
| 3    | `error`, including a `serve` that could not start          |
| 64   | usage error (status `error`, code `usage`)                 |

## The guard

Siri can send messages, make calls, and control the home. The guard is the only
thing between whoever supplies a phrase and those capabilities, so it fails
closed: **with no patterns configured, every phrase is refused.**

The human who starts `ask` or `serve` gives the allowlist with `--guard FILE`
and, optionally, repeated `--allow PATTERN`. The two are combined. There is no
way to change the guard after `serve` starts, and nothing in a request can reach
it.

A phrase is checked in this order, and the first failure refuses it:

1. no patterns are configured (`no_patterns`);
2. it contains a control character, a newline, a tab, a Unicode format character
   (zero-width, bidirectional override, byte order mark), a line or paragraph
   separator, a private-use or unassigned code point, or any space other than
   U+0020 (`control_character`);
3. after trimming leading and trailing spaces it is empty (`empty_phrase`);
4. it is longer than `max_length` characters, default 100 (`too_long`);
5. it has non-ASCII characters and `non_ascii` is not `allow` (`non_ascii`),
   which keeps look-alike letters and case-folding oddities such as U+212A
   (Kelvin sign) out;
6. it matches no pattern **in full**, case-insensitively (`not_allowed`).

The trimmed phrase is what Siri receives. Refusal messages never repeat the
phrase. The `phrase` field of a refused result is the raw input, so do not
forward it anywhere that would be hurt by it.

### Guard file format

One `key = value` per line. Blank lines and lines starting with `#` are ignored.
A `#` after a value is part of the value, so a pattern can contain one.

| Key          | Value                                                                                                                                 |
| ------------ | ------------------------------------------------------------------------------------------------------------------------------------- |
| `allow`      | A regular expression (ICU syntax). Repeatable; at most 100, each at most 500 characters. `--allow` patterns count toward both limits. |
| `max_length` | 1–200 Unicode scalars, default 100. Set at most once.                                                                                 |
| `non_ascii`  | `allow` or `deny` (default). Set at most once.                                                                                        |

Values are trimmed of surrounding whitespace, so write a significant trailing
space as `\x20`. An empty value is `config_invalid`.

Each pattern is compiled as `\A(?:pattern)\z`. A pattern that is not a
well-formed expression on its own is rejected when the guard is built, so
`x)|(y` cannot escape the anchors. An unknown key, a bad value, a file over
64 KiB, or a file that is not UTF-8 is a `config_invalid` error and `ask` or
`serve` does not run.

`examples/guard.conf` allows “set <one named accessory> to …”:

```text
max_length = 60
allow = set (the )?lamp to (red|orange|yellow|green|blue|purple|pink|(cool |warm |neutral )?white|on|off|[0-9]{1,3}%)
```

### Threat model

The queue is written by an agent that may be confused or adversarial. It can
supply a phrase and a timeout, and nothing else; the guard decides whether the
phrase is sent.

What the guard defends against: phrases that are not on the allowlist,
control-character and newline smuggling, invisible or look-alike characters,
over-long input, pattern tricks that depend on unanchored matching, and any
attempt to change the guard or the runner through the queue.

What it does not defend against:

- **A pattern that backtracks without end.** A pattern such as `(a+)+$` can take
  exponential time on a short phrase. The guard gives each match two seconds. On
  a timeout `ask` returns status `error`, code `guard_timeout`, and `serve`
  writes that result and stops, because ICU cannot cancel the match and the
  spinning thread would otherwise keep the runner slow. Avoid nested unbounded
  quantifiers.
- **Look-alikes with `non_ascii = allow`.** Case-insensitive matching treats
  U+212A (Kelvin sign) as `k` and U+017F (long s) as `s`, and Siri receives the
  look-alike. Keep the default `deny` unless you need non-ASCII text.
- **A pattern that is too broad.** `set lamp to .*` allows “set lamp to red and
  call Mom”. End patterns with a closed list of values, not free text.
- **Siri’s interpretation of an allowed phrase.** The guard checks words, not
  effects.
- **Anyone who can run `siri-ax` with their own guard file**, or who can write
  to the queue directory and read its results. The queue directory is created
  with mode 0700; give a sandboxed agent access to it deliberately.
- **Flooding.** Requests run one at a time, each for at most its timeout plus
  the window waits; there is no rate limit or queue cap, every request leaves a
  result file, and the runner never prunes them. Prune `results/` yourself.
  Grant the agent write access to `requests/` and read access to `results/`
  only, not to `claimed/` or the root.
- **Untrusted answers.** `answer_text` is text that Siri produced and may
  include names, web content, or device labels. An agent should treat it as
  data, never as instructions.

## The queue protocol

`serve QUEUE-DIR` creates three directories (mode 0700):

| Directory   | Written by | Contents                                              |
| ----------- | ---------- | ----------------------------------------------------- |
| `requests/` | the agent  | `<id>.json` request files                             |
| `results/`  | the runner | `<id>.json` result files                              |
| `claimed/`  | the runner | the request being handled; the agent never touches it |

**Requests.** A request is a JSON object of at most 16 KiB with exactly these
fields; any other field makes it malformed:

```json
{ "phrase": "set lamp to cool white", "timeout_seconds": 30 }
```

`phrase` is required. `timeout_seconds` is optional, 1–120, default 20; a value
outside the range is an error, not clamped.

**The id** is the file name without `.json`: 1–64 characters from
`A-Z a-z 0-9 _ -`, starting with a letter or digit. It is never read from the
file contents and never used as anything but a name inside `results/`. Files
with other names that end in `.json` are ignored (the runner logs an `ignored`
event once). Ids must not be reused; ids that differ only in case are the same
id on a case-insensitive volume, which is the macOS default. A request whose
result already exists is dropped, the existing result is left alone, and an
error result with code `invalid_request` is written to
`results/<id>.rejected.json` (its `phrase` is the new request’s). Always compare
`phrase` in a result with what you sent, and use a fresh id each time. A file
with an invalid name never gets a result, so treat a missing result as a
timeout.

**Writing atomically.** Write the file under a name that does not end in
`.json`, then rename it into `requests/`, on the same volume. Only `<id>.json`
names are picked up, so a half-written file is never read. A request written in
place under its final name can be read half-written and answered as malformed.

**Order.** The runner handles one request at a time, always the one whose file
name sorts first (bytewise) among those present. Use ids that sort in the order
you want, such as a UTC timestamp followed by a counter.

**Results.** The runner writes `results/<id>.json` atomically (temporary file,
then rename) containing the same object that `ask` prints, plus a newline, with
`id` set. Poll for the file. Result files are never deleted by the runner. A
request that is not a regular file (a symbolic link, a FIFO, a directory), is
too large, is not valid JSON, or has unknown fields, a missing phrase, or a bad
timeout gets a result with status `error` and code `invalid_request`; its
message names the problem but never repeats the content. Symbolic links are not
followed.

**Crashes.** The runner moves a request to `claimed/` before acting on it and
removes it after the result is written. A request found in `claimed/` at startup
had its handling interrupted; it is answered with error code `interrupted` and
is not retried, because it may already have reached Siri.

**Stopping.** `serve` stops on SIGINT or SIGTERM only. A request in progress
finishes first (its timeout plus the window waits); a second signal ends the
process immediately. There is deliberately no queue command that stops or
reconfigures it.

### Worked example

In your own terminal, which has the Accessibility grant:

```sh
siri-ax serve ~/siri-queue --guard ~/siri-guard.conf
```

```json
{
  "schema": 1,
  "event": "started",
  "time": "2027-01-15T08:00:00.000Z",
  "id": null,
  "status": null,
  "detail": "queue /Users/me/siri-queue; 1 patterns; max length 60"
}
```

From the agent:

```sh
q=~/siri-queue
id=$(date -u +%Y%m%dT%H%M%S)-$$
printf '%s' '{"phrase":"set lamp to cool white","timeout_seconds":30}' >"$q/requests/.tmp-$id"
mv "$q/requests/.tmp-$id" "$q/requests/$id.json"
until [ -e "$q/results/$id.json" ]; do sleep 0.5; done
cat "$q/results/$id.json"
```

`serve` logs, one JSON object per line:

```json
{"schema":1,"event":"request","time":"2027-01-15T08:00:05.100Z","id":"20270115T080005-4242","status":null,"detail":null}
{"schema":1,"event":"result","time":"2027-01-15T08:00:08.400Z","id":"20270115T080005-4242","status":"answered","detail":null}
```

Events are `started`, `request`, `result`, `ignored`, `recovered`, and
`stopped`. `ignored` has `detail` `<reason>: <file name>` with reason
`invalid_id` or `cannot_claim`; a rejected duplicate id logs `ignored` with the
id and status `error`. At most 1000 distinct ignored names are logged. A result
with code `interrupted` has `phrase` null.

## Output schema

Every `ask` result, and every file in `results/`, is one line with these keys,
always present. Absent values are `null`, never missing.

| Key            | Type           | Meaning                                                              |
| -------------- | -------------- | -------------------------------------------------------------------- |
| `schema`       | integer        | Schema version, currently 1.                                         |
| `command`      | string         | `"ask"`.                                                             |
| `id`           | string or null | Queue id; null for the command line.                                 |
| `status`       | string         | `answered`, `no_answer`, `refused`, or `error`.                      |
| `phrase`       | string or null | The phrase as received (before trimming); null if none.              |
| `answer_text`  | string         | The text of every part, joined with newlines; `""` if none.          |
| `answer_parts` | array          | Ordered objects `{"kind":…,"text":…}`; `kind` is `text` or `button`. |
| `settled`      | boolean        | The answer stayed unchanged for `--settle` seconds.                  |
| `error`        | object or null | `{"code":…,"message":…}` for `refused` and `error`.                  |
| `started_at`   | string         | UTC, ISO 8601, millisecond precision.                                |
| `finished_at`  | string         | UTC, ISO 8601, millisecond precision.                                |
| `elapsed_ms`   | integer        | Milliseconds from start to finish.                                   |

Statuses:

- `answered`: Siri’s response had at least one part. If `settled` is false the
  timeout arrived while the answer was still changing, so it may be an interim
  line such as “Searching for red”. Check `settled` before trusting it. A lone
  text part that starts with “Searching for ” is never treated as settled, so it
  ends the wait only at the timeout; other interim text that stays unchanged for
  `--settle` seconds is still reported as settled, so re-ask with a larger
  `--settle` on a cold start.
- `no_answer`: nothing appeared in Siri’s response before the timeout.
- `refused`: the guard refused the phrase; Siri was not touched.
- `error`: something other than the guard failed.

A `text` part is an `AXStaticText` of the answer; a `button` part is an
`AXButton`, labelled by its title or, failing that, its description. A HomeKit
action often answers with only a button such as “Lamp, Red”. Only the last
response of the new conversation is read.

Error codes. Refusals: `no_patterns`, `empty_phrase`, `too_long`,
`control_character`, `non_ascii`, `not_allowed`. Errors: `usage`,
`config_invalid`, `invalid_request`, `interrupted`, `accessibility_not_trusted`,
`siri_not_installed`, `siri_no_window` (Siri AI would not open a window),
`ui_changed` (an expected element is missing, usually after a macOS update),
`ax_failure` (an Accessibility call failed), `queue_failure` (the queue
directory is unusable), `guard_timeout` (an allow pattern backtracked too much).

### Examples

`answered`:

```json
{
  "answer_parts": [{ "kind": "button", "text": "Lamp, Cool White" }],
  "answer_text": "Lamp, Cool White",
  "command": "ask",
  "elapsed_ms": 3012,
  "error": null,
  "finished_at": "2027-01-15T08:00:03.050Z",
  "id": null,
  "phrase": "set lamp to cool white",
  "schema": 1,
  "settled": true,
  "started_at": "2027-01-15T08:00:00.038Z",
  "status": "answered"
}
```

`no_answer`:

```json
{
  "answer_parts": [],
  "answer_text": "",
  "command": "ask",
  "elapsed_ms": 20003,
  "error": null,
  "finished_at": "2027-01-15T08:00:20.041Z",
  "id": null,
  "phrase": "set lamp to red",
  "schema": 1,
  "settled": false,
  "started_at": "2027-01-15T08:00:00.038Z",
  "status": "no_answer"
}
```

`refused`:

```json
{
  "answer_parts": [],
  "answer_text": "",
  "command": "ask",
  "elapsed_ms": 0,
  "error": {
    "code": "not_allowed",
    "message": "the phrase matches no allow pattern"
  },
  "finished_at": "2027-01-15T08:00:00.040Z",
  "id": null,
  "phrase": "call Mom",
  "schema": 1,
  "settled": false,
  "started_at": "2027-01-15T08:00:00.040Z",
  "status": "refused"
}
```

`error`:

```json
{
  "answer_parts": [],
  "answer_text": "",
  "command": "ask",
  "elapsed_ms": 2,
  "error": {
    "code": "accessibility_not_trusted",
    "message": "the terminal app running siri-ax has no Accessibility permission"
  },
  "finished_at": "2027-01-15T08:00:00.042Z",
  "id": null,
  "phrase": "set lamp to red",
  "schema": 1,
  "settled": false,
  "started_at": "2027-01-15T08:00:00.040Z",
  "status": "error"
}
```

Failures with no request to attach to (a usage error outside `ask`, a bad guard
file for `serve`, a `serve` that cannot start) print this instead, with
`command` set to `"serve"`, `"doctor"`, or `null`:

```json
{
  "command": "serve",
  "error": {
    "code": "config_invalid",
    "message": "cannot read the guard file: …"
  },
  "schema": 1,
  "status": "error",
  "time": "2027-01-15T08:00:00.000Z"
}
```

`doctor`:

```json
{
  "checked_at": "2027-01-15T08:00:00.000Z",
  "checks": {
    "accessibility_trusted": true,
    "macos_version": "27.2.1",
    "siri_has_window": true,
    "siri_installed": true,
    "siri_running": true
  },
  "command": "doctor",
  "problems": [],
  "schema": 1,
  "status": "ready"
}
```

`status` is `ready` or `not_ready`; `problems` lists `accessibility_not_trusted`
and `siri_not_installed` when they apply.

## How it works

It finds the Siri AI process, takes its first window, presses the “New
Conversation” button (`newChatButton`), sets the value of the prompt field
(`promptViewTextField`), and performs `AXConfirm` on it. No keyboard focus or
frontmost window is needed. It then polls the `modelResponse` groups of the
window every 0.4 seconds until the last one has stayed unchanged for `--settle`
seconds. If Siri AI has no window, it runs
`/usr/bin/open -a "/System/Applications/Siri AI.app"` and waits up to ten
seconds for a window, preferring one with subrole `AXStandardWindow`. If the
window tree has more than 5000 elements it fails with `ui_changed` rather than
reading a truncated tree.

## Limitations

- macOS 27 only. The identifiers above are private to Siri AI and can change
  between macOS releases; verified on 27.2.1. When they change, `ask` fails with
  `ui_changed`, or, if only the answer’s structure changed, returns `no_answer`.
- The first request after Siri AI launches can take most of a minute; later ones
  take one to six seconds. Use `--timeout` or `timeout_seconds` accordingly.
- An answer can be only a button. The tool reports its label but does not press
  it.
- Siri’s answer states what Siri says it did, not what actually happened.
  Confirm the effect independently; for a HomeKit action, at the device or the
  bridge.
- Only Siri AI is read; older Siri surfaces are not.
- Accessibility cannot be exercised in a sandbox. The live layer
  (`Sources/SiriAXCLI/Live`) has no automated tests; everything else is tested
  against fake trees shaped like the observed one.

## Credit

The technique, driving the Siri AI chat window through Accessibility without
bringing it to the front, comes from
[siri-cli](https://github.com/Pasithea0/siri-cli) by Pasithea0 (MIT). No code is
copied from it.

## License

Apache License 2.0; see `LICENSE`.
