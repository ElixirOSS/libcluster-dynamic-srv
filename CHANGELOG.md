# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-05-08

### Fixed

- Replace double poll scheduling with `handle_continue/2` to ensure a single, clean poll chain
- Use `handle_continue(:poll, state)` for initial poll instead of calling `do_poll/1` directly in `init/1`
- Add catch-all clause in `get_nodes/1` to handle unexpected resolver responses without crashing
- Fix regex character class `[a-z0-9-_]` to `[a-z0-9_-]` to avoid ambiguous range matching

### Added

- Test coverage for unexpected resolver responses
- Test coverage for SRV records with non-matching hostname formats
- Test coverage for missing `:service` config
- Test coverage for `meta: nil` initialization path
- Test coverage for self-exclusion from the node list
- Test coverage for recurring polls after the initial poll

## [0.1.4] - 2025-09-08

### Fixed

- Fix hexdocs configuration — add README and links

## [0.1.3] - 2025-09-07

### Fixed

- Fix broken link to GitHub repository

## [0.1.2] - 2025-09-07

### Added

- ExDoc support for generating documentation

## [0.1.1] - 2025-09-07

### Fixed

- Fix packaging configuration for Hex publish

## [0.1.0] - 2025-09-07

### Added

- Initial release of `Cluster.Strategy.DynamicSrv` — a libcluster strategy using DNS SRV records
- Support for Consul SRV records in `<node-name>.<service-domain-name>` format
- Configurable polling interval (default 5000ms)
- Configurable resolver function for testing and custom DNS backends
- MIT license

[Unreleased]: https://github.com/ElixirOSS/libcluster-dynamic-srv/compare/0.1.4...HEAD
[0.1.4]: https://github.com/ElixirOSS/libcluster-dynamic-srv/compare/0.1.3...0.1.4
[0.1.3]: https://github.com/ElixirOSS/libcluster-dynamic-srv/compare/0.1.2...0.1.3
[0.1.2]: https://github.com/ElixirOSS/libcluster-dynamic-srv/compare/0.1.1...0.1.2
[0.1.1]: https://github.com/ElixirOSS/libcluster-dynamic-srv/compare/0.1.0...0.1.1
[0.1.0]: https://github.com/ElixirOSS/libcluster-dynamic-srv/releases/tag/0.1.0
