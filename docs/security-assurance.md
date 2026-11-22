# Security testing

Pulshade's design is described in [how-it-works.md](how-it-works.md) and [protocol.md](protocol.md). This page is
about testing: what is checked, how to check it, and what is not covered.

**Pulshade has not had an independent security audit.** Its encryption is our own code following published
designs. Until a third party has reviewed it, don't rely on it where your safety depends on it. See
[SECURITY.md](../SECURITY.md) for how to report a problem.

## What the tests cover

| Check | Covers | Command |
|---|---|---|
| Unit suite | keys, envelopes, ratchet, groups, vault, wire formats, UI maths | `swift test` |
| Delivery stress | loss, duplication, reordering and restart across ratchet steps | `swift test --filter DeliveryChaosTests` |
| Input robustness | every code, link, frame and JSON parser against arbitrary bytes | `swift test --filter ParserFuzzTests` |
| Mutation fuzzer | the same parsers, under AddressSanitizer, for a chosen duration | `./scripts/fuzz.sh 60` |
| Address + undefined sanitizers | memory errors and integer/UB traps | `swift test --sanitize=address --sanitize=undefined` |
| Thread sanitizer | data races in shared and async paths | `swift test --sanitize=thread` |
| Release gates | relay, pin and admin keys must be present | `project.yml`, `scripts/build-app.sh` |
| Name scan | no home folder or account name in a release build | `scripts/testflight.sh` |

`scripts/verify.sh` runs the suite and both sanitizer passes. Tests that need a relay live in the complete tree;
if they are absent, the script says so and will not report a non-relay run as complete.

## What these tests are for

- The delivery stress test drives the ratchet through loss, duplication and reordering, including a
  serialize/reload between rounds (what a suspended app does).
- The parser tests are crash-only: they don't prove a parser accepts the right input, only that it never traps
  on arbitrary bytes.
- The fuzzer mutates a seed corpus and feeds it to the same parsers; it runs for a chosen time under
  AddressSanitizer, so a bad parse stops the run instead of waiting for a test case.
- The sanitizers are where concurrency in saves, relay sessions and stored state shows up.

## Not covered here

- **A relay.** The relay-dependent suites (groups, channels, delivery, detach) need the relay test harness.
- **A physical device.** The vault, Keychain, Secure Enclave and panic/decoy timing need device tests.
- **Coverage-guided fuzzing.** The fuzzer is deterministic mutation with ASan, not libFuzzer: Swift's compiler
  driver here does not accept `-sanitize=fuzzer`. A clang harness over the same parsers is the next step.
- **iOS.** The commands above run the macOS build.
- **The relay's own implementation.** The server is not published.
