# Changelog

## [Unreleased]

### Added

- Conversation search now uses a labeled three-tier engine: the matching macOS app FTS5 index
  read-only, a separate incremental `node:sqlite` CLI index on Node 22.5+, or the existing scan on
  older Node versions. The CLI index supports append-only updates, schema-version rebuilds,
  `--rebuild-index`, and an `engine` field in newline-delimited JSON without adding dependencies.
