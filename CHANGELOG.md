# Changelog

All notable changes follow [Keep a Changelog](https://keepachangelog.com/).
Kernport uses semantic versioning after the first stable release.

## [0.2.0] - 2026-11-07

### Changed

- The product name is Kernport. The Mac bundle id is `app.kernport.mac`, the Android application id is `app.kernport.clip`, and nearby discovery uses `_kernport._tcp`. Phones that were paired before this version pair again.

## [Unreleased]

### Added

- Native Swift 6 menu-bar application for macOS 26 and newer
- Android Quick Share LAN discovery, UKEY2 handshake, encrypted transfer, and
  bidirectional streaming
- Drag-and-drop, file/folder picker, QR connection, transfer progress, and
  configurable receive destination
- Finder Share extension with live send progress, and opt-in localhost CLI/API
- Phone clipboard sync: an Android copy becomes the Mac pasteboard, so ⌘V pastes
  text, images, and files
- Headless real-device protocol probe
- Golden vectors, randomized parser tests, loopback integration tests, and
  deterministic performance tests
- Signed/notarized release automation

### Security

- Explicit consent and matching PIN required for every inbound transfer
- Bounded frame, payload, file-count, file-size, and parser-depth limits
- Safe destination names, temporary partial files, disk-space checks, and
  quarantine attributes
