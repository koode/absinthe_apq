# Contributing

Thanks for helping with AbsintheAPQ. This file explains how to set up the project,
what to check before you open a pull request, and how to write commit messages.

## Setup

The project uses [mise](https://mise.jdx.dev) to pin Erlang and Elixir in `mise.toml`.
Do not use another version manager or a global install.

```sh
mise trust && mise install
mise exec -- mix deps.get
```

## Before you open a pull request

Run these checks. All of them must pass.

```sh
mise exec -- mix format --check-formatted
mise exec -- mix compile --warnings-as-errors
mise exec -- mix credo
mise exec -- mix test
mise exec -- mix docs --warnings-as-errors
mise exec -- mix hex.build
mise exec -- mix dialyzer
```

CI runs the same checks.

- **Credo runs in strict mode with every [ExSlop](https://github.com/elixir-vibe/ex_slop)
  check** (`.credo.exs`). Fix a finding rather than disable it. If a check is wrong
  for one line, disable it for that line only and add a comment with the reason.
- **New logic needs tests.** Put them in `test/`.
- **Protocol changes start in `docs/PROTOCOL.md`.** Every rule there names its source
  (the Apollo link README, Apollo Server, Apollo Router or Apollo Client) and has a
  `describe` block with the same number in `test/absinthe_apq/protocol_test.exs` that
  sends real requests through `Absinthe.Plug`. Change the rule, its source and its test
  together.
- **Fail closed.** A cache error, an unexpected cache answer or a stored query that does
  not hash to its key must end in `PersistedQueryNotFound`. Never run a document the
  request did not prove with its hash.
- **Do not add a cache library as a dependency.** Cachex, Nebulex and Redis belong in
  the application, behind `AbsintheAPQ.Cache`.
- **Update `CHANGELOG.md`** under an `## Unreleased` heading for changes that users
  can see.

## Commit messages

This project uses [Conventional Commits 1.0.0](https://www.conventionalcommits.org/en/v1.0.0/).
Every commit on `main` follows this format:

```
<type>(<scope>): <subject>

<body>

<footer>
```

The scope, body and footer are optional.

### Types

| Type | Use it for |
|---|---|
| `feat` | A new feature or option that users can see |
| `fix` | A bug fix |
| `docs` | Documentation only: README, guides, module docs, examples |
| `test` | Tests only |
| `refactor` | A code change that does not change behavior |
| `perf` | A change that makes something faster or smaller |
| `build` | Hex dependencies, package metadata |
| `ci` | CI configuration |
| `style` | Formatting only |
| `chore` | Other maintenance, for example tool versions or releases |
| `revert` | Reverts an earlier commit |

### Scopes

Use a scope when the change is in one area:

| Scope | Area |
|---|---|
| `plug` | `AbsintheAPQ.DocumentProvider`, the pipeline phases and `AbsintheAPQ.before_send/2` |
| `cache` | `AbsintheAPQ.Cache` and `AbsintheAPQ.Cache.ETS` |
| `telemetry` | Telemetry events |
| `protocol` | `docs/PROTOCOL.md` and the protocol tests |
| `deps` | Dependency updates |
| `hex` | Hex package metadata |
| `release` | Release commits |

### Subject and body

- Write the subject in the imperative mood, in lower case, with no period at the end:
  `fix(cache): keep the entry count after a failed insert`.
- Keep the subject line to 72 characters or fewer.
- Use the body to explain why the change is necessary, not what each line does.
- Refer to issues in the footer, for example `Closes #12`.

### Breaking changes

Mark a breaking change with `!` after the type or scope, and explain it in a
`BREAKING CHANGE:` footer:

```
feat(plug)!: rename :max_query_bytes to :max_stored_query_bytes

BREAKING CHANGE: the :max_query_bytes option is now :max_stored_query_bytes. Rename it
where you configure the document provider.
```

Before 1.0.0, a breaking change increments the minor version (0.1.x to 0.2.0).

## Pull requests

- Keep one topic per pull request.
- Rebase on `main` before you ask for a review. History on `main` is linear: no merge
  commits and no squash merges, so every commit must pass the checks on its own and
  have a Conventional Commits message.
- Describe what changed and how you tested it.

## Releases

Maintainers make releases:

1. Set the new version in `mix.exs` and move the `## Unreleased` entries in
   `CHANGELOG.md` under the new version.
2. Commit with `chore(release): vX.Y.Z`.
3. Tag the commit with `git tag -a vX.Y.Z -m vX.Y.Z` and push the branch and the tag.
4. Run `mise exec -- mix hex.publish`.

## License

By contributing, you agree that your contributions are licensed under the MIT
license in `LICENSE`.
