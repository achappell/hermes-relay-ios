# Changelog

## 0.4.0 (2026-09-15)

<!-- Release notes generated using configuration in .github/release.yml at main -->

## What's Changed
### Dependencies
* chore(deps): bump apple-actions/download-provisioning-profiles from 473562c853e9f580367eeff7c180258653e416e0 to 2126b5f86a0e2863cbf4d2d312112b22b943a594 by @dependabot[bot] in https://github.com/achappell/hermes-relay-ios/pull/76
* chore(deps): bump apple-actions/import-codesign-certs from b2e261033a9e248f91a9b57201e8d1e12b15a24e to 5142e029c445c10ffc7149d172e540235a065466 by @dependabot[bot] in https://github.com/achappell/hermes-relay-ios/pull/75
* chore(deps): bump apple-actions/upload-testflight-build from 6fd267a887d75a215682c05c861278a67801855c to 5e75ff58276689011512ba87a381d93dc67dbcf8 by @dependabot[bot] in https://github.com/achappell/hermes-relay-ios/pull/74
### Other Changes
* fix(ci): use Xcode managed TestFlight signing by @achappell in https://github.com/achappell/hermes-relay-ios/pull/61
* fix(ci): use integer TestFlight build numbers by @achappell in https://github.com/achappell/hermes-relay-ios/pull/63
* feat(ios): add Home wake arbitration configuration seam by @achappell in https://github.com/achappell/hermes-relay-ios/pull/64
* chore: make iOS BMad delivery status local by @achappell in https://github.com/achappell/hermes-relay-ios/pull/65
* docs(ios): specify Home service client slice by @achappell in https://github.com/achappell/hermes-relay-ios/pull/66
* chore: standardize project-local worktrees by @achappell in https://github.com/achappell/hermes-relay-ios/pull/72
* docs: register Apple next-wave story roster by @achappell in https://github.com/achappell/hermes-relay-ios/pull/73
* feat(ios): implement Story 4 Home bridge migration by @achappell in https://github.com/achappell/hermes-relay-ios/pull/77

## New Contributors
* @dependabot[bot] made their first contribution in https://github.com/achappell/hermes-relay-ios/pull/76

**Full Changelog**: https://github.com/achappell/hermes-relay-ios/compare/v0.3.2...v0.4.0

## 0.3.2 (2026-09-12)

<!-- Release notes generated using configuration in .github/release.yml at main -->

## What's Changed
### Other Changes
* fix(ci): prevent macOS speech test timeout by @achappell in https://github.com/achappell/hermes-relay-ios/pull/59


**Full Changelog**: https://github.com/achappell/hermes-relay-ios/compare/v0.3.1...v0.3.2

## 0.3.1 (2026-09-12)

<!-- Release notes generated using configuration in .github/release.yml at main -->

## What's Changed
### Other Changes
* fix(release): keep Xcode version in sync by @achappell in https://github.com/achappell/hermes-relay-ios/pull/57


**Full Changelog**: https://github.com/achappell/hermes-relay-ios/compare/v0.3.0...v0.3.1

## 0.3.0 (2026-09-12)

<!-- Release notes generated using configuration in .github/release.yml at main -->

## What's Changed
### Other Changes
* feat: bounded reconnect after unexpected transport loss (IOS-25) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/21
* fix: resend the unconfirmed turn through the voice coordinator (IOS-25) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/22
* fix: pace only the active assistant message (IOS-30) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/23
* fix: end the response on turn completion, not segment end (IOS-31) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/24
* feat: instrument segment boundaries and speech timing (IOS-32) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/25
* fix: drain playback before ending the response (IOS-33) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/27
* chore: log audio diagnostics in every debug build (IOS-32) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/26
* fix: pace the caption from the playback clock before timings arrive (IOS-32) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/28
* fix: open the conversation history at the newest message (IOS-29) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/29
* fix: give each relay profile its own conversation (IOS-35) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/31
* feat: saved relay profiles and connection switching (IOS-13) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/30
* fix: terminate relay turns on native socket closure by @achappell in https://github.com/achappell/hermes-relay-ios/pull/32
* feat: adopt server-confirmed interruption by @achappell in https://github.com/achappell/hermes-relay-ios/pull/33
* feat(ios): add native transcript export and prompt history by @achappell in https://github.com/achappell/hermes-relay-ios/pull/34
* chore: add Hermes Home BMAD upstream context by @achappell in https://github.com/achappell/hermes-relay-ios/pull/35
* feat(ios): gate turns on verified Hermes Profile sessions by @achappell in https://github.com/achappell/hermes-relay-ios/pull/36
* feat(ios): render honest turn phases and response delivery by @achappell in https://github.com/achappell/hermes-relay-ios/pull/37
* fix(ios): harden voice capture recovery by @achappell in https://github.com/achappell/hermes-relay-ios/pull/38
* feat: add opt-in iOS hands-free voice turns by @achappell in https://github.com/achappell/hermes-relay-ios/pull/39
* docs: align local BMad task guidance by @achappell in https://github.com/achappell/hermes-relay-ios/pull/40
* Feat/ios device 01 discovery by @achappell in https://github.com/achappell/hermes-relay-ios/pull/41
* test(ios): add device discovery smoke fixture by @achappell in https://github.com/achappell/hermes-relay-ios/pull/42
* feat(ios): preserve incomplete device setup drafts by @achappell in https://github.com/achappell/hermes-relay-ios/pull/43
* docs: define iOS planning authorities by @achappell in https://github.com/achappell/hermes-relay-ios/pull/44
* docs(ios): add retroactive spec for Story 1.4 recovery (I-3) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/45
* feat(ios): preserve verified wake mappings during publish by @achappell in https://github.com/achappell/hermes-relay-ios/pull/46
* fix(ios): rehydrate approved devices from saved state by @achappell in https://github.com/achappell/hermes-relay-ios/pull/47
* test(ios): verify capture acknowledgement and live transcription (2-I-1) by @achappell in https://github.com/achappell/hermes-relay-ios/pull/48
* docs(ios): close 3-I-3 review gate by @achappell in https://github.com/achappell/hermes-relay-ios/pull/49
* feat(ios): harden disconnected state recovery by @achappell in https://github.com/achappell/hermes-relay-ios/pull/50
* feat(ios): fail closed for unavailable and revoked Device identities by @achappell in https://github.com/achappell/hermes-relay-ios/pull/51
* feat(ios): revoke Device access safely by @achappell in https://github.com/achappell/hermes-relay-ios/pull/52
* feat(ios): complete visual design and distribution foundations by @achappell in https://github.com/achappell/hermes-relay-ios/pull/54
* chore: redact private planning and fixture data by @achappell in https://github.com/achappell/hermes-relay-ios/pull/55
* fix(ci): use CodeQL default setup only by @achappell in https://github.com/achappell/hermes-relay-ios/pull/56


**Full Changelog**: https://github.com/achappell/hermes-relay-ios/compare/v0.2.0...v0.3.0

## 0.2.0 (2026-09-03)

<!-- Release notes generated using configuration in .github/release.yml at main -->

## What's Changed
### Other Changes
* fix: harden secure relay configuration by @achappell in https://github.com/achappell/hermes-relay-ios/pull/6
* fix: preserve websocket protocol errors by @achappell in https://github.com/achappell/hermes-relay-ios/pull/8
* Fix iOS local voice capture lifecycle by @achappell in https://github.com/achappell/hermes-relay-ios/pull/9
* fix: propagate finish-time audio failures by @achappell in https://github.com/achappell/hermes-relay-ios/pull/10
* feat: report accurate voice playback state by @achappell in https://github.com/achappell/hermes-relay-ios/pull/11
* feat: auto-scroll conversation to latest message by @achappell in https://github.com/achappell/hermes-relay-ios/pull/12
* feat: add auto-connect and native interruption foundation by @achappell in https://github.com/achappell/hermes-relay-ios/pull/13
* feat: add audio activity signal contract by @achappell in https://github.com/achappell/hermes-relay-ios/pull/14
* feat: add ambient voice HUD by @achappell in https://github.com/achappell/hermes-relay-ios/pull/15


**Full Changelog**: https://github.com/achappell/hermes-relay-ios/compare/v0.1.0...v0.2.0

## 0.1.0 (2026-09-01)

<!-- Release notes generated using configuration in .github/release.yml at main -->

## What's Changed
### Other Changes
* fix: stabilize iOS voice capture lifecycle by @achappell in https://github.com/achappell/hermes-relay-ios/pull/1
* polish: separate bottom interaction surface by @achappell in https://github.com/achappell/hermes-relay-ios/pull/2
* ci: add GitHub Actions and release automation by @achappell in https://github.com/achappell/hermes-relay-ios/pull/3
* fix: bootstrap Release Please without a fake previous tag by @achappell in https://github.com/achappell/hermes-relay-ios/pull/4

## New Contributors
* @achappell made their first contribution in https://github.com/achappell/hermes-relay-ios/pull/1

**Full Changelog**: https://github.com/achappell/hermes-relay-ios/commits/v0.1.0

## Changelog

All notable changes to Hermes Relay iOS will be documented here by Release Please.
