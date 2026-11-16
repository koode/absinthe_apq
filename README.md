# absinthe_apq

[Apollo Automatic Persisted Queries](https://www.apollographql.com/docs/apollo-server/performance/apq)
(APQ) for Absinthe and `Absinthe.Plug`.

With APQ, a client sends the SHA-256 hash of a query instead of the query text. The
server runs the query it stored under that hash. When it does not know the hash yet, it
answers `PersistedQueryNotFound`, and the client sends the hash and the query once, so
the server can store them. Large queries then cost a 64-character hash per request,
and hash-only queries fit in a `GET` URL that a CDN can cache.

- **A document provider.** `AbsintheAPQ.DocumentProvider` plugs into the
  `:document_providers` option of `Absinthe.Plug`. Requests without the APQ extension
  go on to the next provider, so ordinary queries keep working.
- **The errors Apollo Client expects.** `PersistedQueryNotFound` with the code
  `PERSISTED_QUERY_NOT_FOUND`, so Apollo Client 4 retries with the full query.
- **Safe by default.** A registered query is stored only when it hashes to the sent hash
  and passes validation. A stored query runs only if it still hashes to its key. Cache
  errors answer `PersistedQueryNotFound`; they never run another document.
- **Bounded memory.** The built-in ETS store holds at most `:max_entries` queries, and
  queries over `:max_query_bytes` run but are not stored.
- **Any store.** Implement `AbsintheAPQ.Cache` (two callbacks) for Cachex, Nebulex,
  Redis or a database.
- **Telemetry.** Events for hits, misses, stores, hash mismatches and cache errors.

[`docs/PROTOCOL.md`](docs/PROTOCOL.md) lists every protocol rule the library follows,
with its source (the Apollo link README, Apollo Server, Apollo Router and Apollo Client
4) and its test.

AbsintheAPQ is a community library. It is not affiliated with Apollo or the
absinthe-graphql project.

## Installation

```elixir
def deps do
  [
    {:absinthe_apq, "~> 0.1"}
  ]
end
```

It needs `absinthe ~> 1.12`, `absinthe_plug ~> 1.5` and Elixir 1.18 or later (it decodes
`GET` extensions with Elixir's built-in `JSON` module).

## Server setup

Start the store in your supervision tree:

```elixir
# lib/my_app/application.ex
children = [
  {AbsintheAPQ.Cache.ETS, max_entries: 1_000},
  MyAppWeb.Endpoint
]
```

Put the document provider before `Absinthe.Plug.DocumentProvider.Default`:

```elixir
# lib/my_app_web/router.ex
forward "/graphql", Absinthe.Plug,
  schema: MyAppWeb.Schema,
  document_providers: [AbsintheAPQ.DocumentProvider, Absinthe.Plug.DocumentProvider.Default],
  before_send: {AbsintheAPQ, :before_send}
```

`before_send: {AbsintheAPQ, :before_send}` is optional. `Absinthe.Plug` sends every
result with status 200; the hook gives a hash mismatch, an unsupported version and a
malformed hash status 400, and every APQ error `cache-control: private, no-cache,
must-revalidate`, as Apollo Server does. If you already have a `:before_send` hook, call
`AbsintheAPQ.before_send/2` from it.

Keep `Absinthe.Plug.DocumentProvider.Default` after the APQ provider. Without it, an
ordinary request with a `query` and no APQ extension fails, because no provider
handles it.

### Options

Pass options with a `{module, options}` tuple, which `Absinthe.Plug` supports for every
document provider:

```elixir
document_providers: [
  {AbsintheAPQ.DocumentProvider, max_query_bytes: 65_536},
  Absinthe.Plug.DocumentProvider.Default
]
```

| Option | Default | |
|---|---|---|
| `:cache` | `AbsintheAPQ.Cache.ETS` | An `AbsintheAPQ.Cache` module, or `{module, options}`. |
| `:max_query_bytes` | `32_768` | The largest query that is stored. Larger ones run but are not stored. |
| `:enabled` | `true` | With `false`, answers `PersistedQueryNotSupported`, so clients stop sending hashes. |

The built-in store takes `:name` (default `AbsintheAPQ.Cache.ETS`) and `:max_entries`
(default `1_000`). With the defaults, the store holds at most about 32 MiB of query
text. A store with another name is passed as
`cache: {AbsintheAPQ.Cache.ETS, name: MyApp.APQCache}`.

When it is full, the store removes the query that was stored first. An evicted query
costs its clients one extra round trip. The store is per node and empties on restart;
for a cluster, implement `AbsintheAPQ.Cache` on a shared store.

To switch APQ off while clients still send hashes, set `enabled: false` rather than
removing the provider. Apollo Client then sends full queries for the rest of the
session. Without the provider, hash-only requests get "No query document supplied",
which Apollo Client does not retry.

## Client setup (Apollo Client 4)

`PersistedQueryLink` comes from `@apollo/client/link/persisted-queries`. It needs a
SHA-256 function that returns lowercase hex; the Web Crypto API has one, so no extra
package is needed:

```ts
import { ApolloClient, HttpLink, InMemoryCache } from "@apollo/client";
import { PersistedQueryLink } from "@apollo/client/link/persisted-queries";

async function sha256(query: string): Promise<string> {
  const bytes = new TextEncoder().encode(query);
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest), (byte) => byte.toString(16).padStart(2, "0")).join("");
}

const client = new ApolloClient({
  cache: new InMemoryCache(),
  link: new PersistedQueryLink({ sha256 }).concat(new HttpLink({ uri: "/graphql" })),
});
```

- `crypto.subtle` exists only in secure contexts: HTTPS, or `http://localhost`.
- `createPersistedQueryLink({ sha256 })` still works in Apollo Client 4, but is deprecated
  in favour of `new PersistedQueryLink(...)`.
- Pass `useGETForHashedQueries: true` to send hash-only queries as `GET`, for example to
  cache them in a CDN. Registrations and mutations stay `POST`.
- Put the link in front of the HTTP link only; subscriptions over a WebSocket link are
  not covered (see below).

## Telemetry

All events start with `:absinthe_apq`. Their metadata has the `:hash`.

| Event | When |
|---|---|
| `[:absinthe_apq, :hit]` | A hash-only request found its query. |
| `[:absinthe_apq, :miss]` | A hash-only request did not, and gets `PersistedQueryNotFound`. |
| `[:absinthe_apq, :store]` | A query passed validation and was stored. |
| `[:absinthe_apq, :hash_mismatch]` | The query does not hash to the sent hash. |
| `[:absinthe_apq, :query_too_large]` | The query ran but was not stored. |
| `[:absinthe_apq, :invalid_request]` | Unsupported version or malformed hash (`:reason`). |
| `[:absinthe_apq, :not_supported]` | A request with the extension while `enabled: false`. |
| `[:absinthe_apq, :cache_error]` | The cache failed (`:operation`, `:reason`). |

See `AbsintheAPQ` for the measurements and metadata of each event.

## Not in 0.1.0

- **Subscriptions over `Absinthe.Phoenix` sockets.** Socket documents do not go through
  `Absinthe.Plug` document providers, so APQ applies to HTTP requests only.
- **Persisted query lists (safelisting).** Any client can register any valid query. APQ
  saves bandwidth; it does not limit which queries run.

## License

MIT. See [LICENSE](LICENSE).
