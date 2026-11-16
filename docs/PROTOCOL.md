# Protocol notes

The rules of Automatic Persisted Queries (APQ) that AbsintheAPQ follows, each with
where it comes from and the test that checks it. Every rule has a `describe` block with
the same number in `test/absinthe_apq/protocol_test.exs`, which sends real requests
through `Plug.Parsers` and `Absinthe.Plug`.

Sources:

- **Link README**: the "Protocol" section of the original client,
  [apollo-link-persisted-queries](https://github.com/apollographql/apollo-link-persisted-queries).
- **Apollo Server docs**: [Automatic Persisted Queries](https://www.apollographql.com/docs/apollo-server/performance/apq).
- **Apollo Server source**: `packages/server/src/requestPipeline.ts` and
  `internalErrorClasses.ts` in [apollo-server](https://github.com/apollographql/apollo-server).
- **Router docs and source**: [Automatic Persisted Queries (APQ)](https://www.apollographql.com/docs/graphos/routing/operations/apq)
  and `apollo-router/src/services/layers/apq.rs` in [router](https://github.com/apollographql/router).
- **Apollo Client 4**: `link/persisted-queries/index.js` and `link/http/` in the
  published `@apollo/client` package (checked against 4.3.8).

Where the sources disagree, AbsintheAPQ follows Apollo Client 4 and Apollo Server.

## P1. The hash goes in `extensions.persistedQuery`

A request carries `extensions.persistedQuery = {"version": 1, "sha256Hash": "<hash>"}`.
A hash-only request leaves out the `query` field. `operationName` and `variables` are
sent as usual and apply to the stored query.

Sources: Link README, "Query Signature". Apollo Client 4 sets
`operation.extensions.persistedQuery = { version: 1, sha256Hash }` and
`http.includeQuery: false` for the first request.

## P2. A GET request sends the extensions as a JSON string

With `useGETForHashedQueries: true`, Apollo Client 4 sends hash-only queries as `GET`
and puts `JSON.stringify(extensions)` in the `extensions` query parameter. The provider
reads `extensions` both as a decoded map (JSON `POST` body) and as a JSON string.

Sources: Apollo Client 4 `link/http/rewriteURIForGET.js`; Apollo Server docs,
"Command-line testing" and "Using GET requests with APQ on a CDN".

## P3. The hash is the lowercase hex SHA-256 of the exact query text

The server hashes the bytes of the `query` field as sent. Apollo Client 4 hashes
`print(query)` and sends the same printed text when it registers, so the two agree.

Apollo Server compares `createHash('sha256').update(query).digest('hex')` with the sent
hash as strings, so only lowercase hex can match. Apollo Router decodes the hash as hex
and ignores the APQ extension when the hash is not 64 hex characters.

AbsintheAPQ answers a `sha256Hash` that is not 64 lowercase hexadecimal characters with
the error `PERSISTED_QUERY_INVALID_HASH` (status 400 with the `before_send/2` hook). This
keeps malformed keys out of the cache. See "Open points" for the difference with Router.

## P4. A known hash runs the stored query

Sources: Link README, "Happy Path"; Apollo Server and Router source.

## P5. An unknown hash gets `PersistedQueryNotFound` with status 200

```json
{"errors": [{"message": "PersistedQueryNotFound", "extensions": {"code": "PERSISTED_QUERY_NOT_FOUND"}}]}
```

The response has no `data` key. The status is 200 with or without the hook, because
`Absinthe.Plug` sends every executed result with 200.

Sources: Link README, "Error Responses" ("must send back the following response
signature with a 200 OK status code"); Apollo Server `PersistedQueryNotFoundError`
(status 200, code `PERSISTED_QUERY_NOT_FOUND`); Router (same message and code).
Apollo Client 4 retries when an error has the message `PersistedQueryNotFound` **or** the
code `PERSISTED_QUERY_NOT_FOUND`; the response has both.

## P6. APQ error responses are not cacheable

Apollo Server and Router send `cache-control: private, no-cache, must-revalidate` with
`PersistedQueryNotFound` (Apollo Server also with `PersistedQueryNotSupported`), so a CDN
does not keep the error for a hash that is stored a moment later.

`AbsintheAPQ.before_send/2` sets that header on every APQ error. Without the hook, Plug's
default `cache-control: max-age=0, private, must-revalidate` stays on the response,
which a shared cache also must not store, unless the application overrides it.

Sources: Apollo Server `getPersistedQueryErrorHttp()`; Router `DONT_CACHE_HEADER_VALUE`.

## P7. A hash with its query runs the query, and stores it once it is valid

When the query hashes to the sent hash, the query runs and the pair is stored.

Apollo Server stores only after parsing, validation and its `didResolveOperation` hooks
succeed, so an invalid query is never stored. Router stores before validation.
AbsintheAPQ follows Apollo Server: the store phase runs right after Absinthe's
`Validation.Result` phase, which skips the rest of the pipeline when the document has
errors. A store error does not stop the request (Apollo Server only logs it).

A query larger than `:max_query_bytes` runs but is not stored. This limit is not part
of the protocol; it keeps anonymous clients from filling memory.

Sources: Link README, "Missing hash path"; Apollo Server source (cache write after
`didResolveOperation`); Router source.

## P8. A hash that does not match its query is rejected

```json
{"errors": [{"message": "provided sha does not match query", "extensions": {"code": "PERSISTED_QUERY_HASH_MISMATCH"}}]}
```

Status 400 with the hook. Nothing is stored and nothing runs.

Sources: Apollo Server (same message, status 400, no code of its own); Router (same
message, code `PERSISTED_QUERY_HASH_MISMATCH`, status 400). AbsintheAPQ uses Router's
code, so the error has a machine-readable code.

## P9. A version other than 1 is rejected

```json
{"errors": [{"message": "Unsupported persisted query version", "extensions": {"code": "PERSISTED_QUERY_UNSUPPORTED_VERSION"}}]}
```

Status 400 with the hook. A `persistedQuery` that is not an object, or has no
`version`, gets the same error.

Sources: Apollo Server (same message, status 400, no code of its own). Router does not
check the version. The code is AbsintheAPQ's own; it must not be
`PERSISTED_QUERY_NOT_SUPPORTED`, which turns APQ off in Apollo Client.

## P10. `PersistedQueryNotSupported` turns APQ off in the client

```json
{"errors": [{"message": "PersistedQueryNotSupported", "extensions": {"code": "PERSISTED_QUERY_NOT_SUPPORTED"}}]}
```

A server that does not support APQ, or not for this client, answers any request with
the extension with this error, status 200. Apollo Client 4 then stops sending hashes for
the rest of the session and resends the operation with the full query and without the
extension.

With `enabled: false`, the provider answers every request that has the extension with
this error. Without the provider at all, a hash-only request gets `Absinthe.Plug`'s
"No query document supplied" (status 400), which Apollo Client 4 neither retries nor
treats as "not supported", so every operation fails until the page reloads with APQ
off. Use `enabled: false` to switch APQ off while clients still send hashes.

Sources: Link README, "Error Responses"; Apollo Server `PersistedQueryNotSupportedError`
(status 200); Router `disabled_apq_request`; Apollo Client 4 `processErrors` and the
default `disable` option.

## P11. A request without the extension is an ordinary request

The provider returns `{:cont, request}`, so the next document provider (usually
`Absinthe.Plug.DocumentProvider.Default`) handles it.

Sources: Apollo Server (`else if (query)` branch); Router (`_ => Ok(request)`).

## P12. Apollo Client retries once, with the full query, on not-found

Apollo Client 4 retries one time per operation, sending `query` and `extensions` as a
`POST` (also when the first request was a `GET`). It looks for the not-found or
not-supported message or code in the `errors` of a 2xx JSON result, and in the JSON
body of a non-2xx response when that body has only `data`, `errors` and `extensions`
keys. Any other error goes to the application without a retry. In Apollo Client 4,
`disable` defaults to "not supported" only; the old link also disabled APQ on any
HTTP 400 or 500.

Every APQ error response has only an `errors` key, with both the message and the code,
and no other APQ error uses the not-found or not-supported message or code.

Sources: Apollo Client 4 `link/persisted-queries/index.js` (`processErrors`,
`defaultOptions`, `handleRetry`) and `utilities/graphql/isFormattedExecutionResult.js`.

## P13. A mutation never runs over GET

Apollo Client 4 sends mutations as `POST` even with `useGETForHashedQueries`. Apollo
Server rejects a `GET` mutation with status 405. A stored query runs through the
pipeline that `Absinthe.Plug` configured, with its `HTTPMethod` phase, so a stored
mutation sent hash-only over `GET` gets status 405 as well.

Sources: Apollo Client 4 `operationDefinesMutation`; Apollo Server source.

## P14. Each operation in a batch is handled on its own

`Absinthe.Plug` runs the document providers for each operation of a batched `POST`, so
hits, misses and registrations mix in one batch. The hook keeps status 200 for a batch,
because the other results are not errors. `GET` does not work with batching.

Sources: Link README, `useGETForHashedQueries` ("not compatible with
apollo-link-batch-http").

## P15. The built-in store is bounded

Apollo Server's default in-memory store has no TTL and evicts with its cache's own
policy; its `ttl` option sets a TTL for other stores. Router's in-memory store is an
LRU cache of 512 entries by default, with an optional Redis store and TTL.

`AbsintheAPQ.Cache.ETS` holds at most `:max_entries` queries (default 1,000), evicts the
oldest stored entry first, and has no TTL. An evicted query costs one extra round trip:
the hash-only request misses and the client registers the query again. A store with a
TTL or shared between nodes is an `AbsintheAPQ.Cache` module of your own.

Sources: Apollo Server docs, "Cache configuration" and "Adjusting cache time-to-live";
Router docs, "In-memory caching" and "Distributed caching with Redis".

## P16. A hash can never be bound to another query

Apollo Server checks the hash of a registered query "to prevent hash hijacking, where a
new and potentially malicious query is associated with an existing hash" (P8).
AbsintheAPQ also checks the hash of every query it reads from the cache, and answers
`PersistedQueryNotFound` when it does not match, so a shared or tampered store cannot
make a hash run another query.

Sources: Apollo Server source (comment on the hash check).

## Not covered

- **Subscriptions over `Absinthe.Phoenix` sockets.** Socket documents do not go through
  `Absinthe.Plug` document providers. Apollo Client sends subscriptions over its
  WebSocket link, which the persisted query link does not change unless it is placed in
  front of it.
- **Persisted query lists (safelisting).** APQ lets any client register any valid query;
  it saves bandwidth, it does not restrict which queries run.

## Open points

- **Malformed hashes.** Router ignores the APQ extension when the hash is not 64 hex
  characters and runs the request as if there were none; Apollo Server uses any string
  as a cache key, so an uppercase hash misses and then fails the hash check. AbsintheAPQ
  rejects it at once with `PERSISTED_QUERY_INVALID_HASH`.
- **When to store.** Apollo Server stores after validation, Router before. AbsintheAPQ
  follows Apollo Server.
- **Error codes.** Apollo Server has no code for a hash mismatch or an unsupported
  version. AbsintheAPQ uses Router's `PERSISTED_QUERY_HASH_MISMATCH` and its own
  `PERSISTED_QUERY_UNSUPPORTED_VERSION`.
- **Status 400 needs the hook.** Without `AbsintheAPQ.before_send/2` every APQ error has
  status 200. Apollo Client 4 behaves the same for both, but logs and HTTP caches see
  the difference.
