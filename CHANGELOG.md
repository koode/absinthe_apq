# Changelog

## Unreleased

## 0.1.0

First release.

- `AbsintheAPQ.DocumentProvider`, an `Absinthe.Plug` document provider for Apollo
  Automatic Persisted Queries (`persistedQuery` version 1), with the `:cache`,
  `:max_query_bytes` and `:enabled` options. It reads the extension from JSON `POST`
  bodies and from the `extensions` parameter of `GET` requests.
- Answers `PersistedQueryNotFound` (`PERSISTED_QUERY_NOT_FOUND`) for an unknown hash,
  `PersistedQueryNotSupported` (`PERSISTED_QUERY_NOT_SUPPORTED`) with `enabled: false`,
  and errors with the codes `PERSISTED_QUERY_HASH_MISMATCH`,
  `PERSISTED_QUERY_UNSUPPORTED_VERSION` and `PERSISTED_QUERY_INVALID_HASH`.
- Stores a registered query only after it passes validation, and runs a stored query
  only if it still hashes to its key. Cache errors answer `PersistedQueryNotFound`.
- `AbsintheAPQ.Cache`, the behaviour for stores, and `AbsintheAPQ.Cache.ETS`, a bounded
  in-memory store with first-in, first-out eviction.
- `AbsintheAPQ.before_send/2`, an `Absinthe.Plug` hook that gives APQ errors status 400
  where Apollo Server does, and `cache-control: private, no-cache, must-revalidate`.
- `AbsintheAPQ.hash/1`.
- Telemetry events under `[:absinthe_apq, ...]`.
- `docs/PROTOCOL.md`: the protocol rules the library follows, with their sources.
