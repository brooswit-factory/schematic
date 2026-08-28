# Spike: Modrinth Servers API — auth, re-point, restart

KAN-723 (task), owning story KAN-715, epic KAN-713. Answers every question with
evidence: a doc URL, a file path in [modrinth/code](https://github.com/modrinth/code),
or a real request/response transcript. No guesses; anything not yet confirmed
live is marked explicitly.

## 0. Platform prerequisite discovered along the way: `X-Panel-Version`

Every Archon request — auth included — is rejected with `HTTP 426
"unsupported archon request version"` unless it carries `X-Panel-Version: 1`.
Source: `packages/api-client/src/features/panel-version.ts` in modrinth/code —
a client feature applied to both the `labrinth` and `archon` APIs that sets
this header on every request. Verified locally pre-flight (no real
credentials involved — a request to a nonexistent server id):

```
$ curl -sS -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer fake" \
    https://archon.modrinth.com/modrinth/v0/servers/fake_server_id
426

$ curl -sS -o /dev/null -w '%{http_code}\n' \
    -H "Authorization: Bearer fake" -H "X-Panel-Version: 1" \
    https://archon.modrinth.com/modrinth/v0/servers/fake_server_id
400   # "failed to parse path `param0`: ... invalid character" — a UUID-shaped id is required; the point is it got PAST the version gate
```

Anyone reproducing any of the calls below needs this header. `repoint.sh` and
`probe-auth.yml` both send it.

## 1. AUTH — what credential can CI hold?

**Base URL:** `https://archon.modrinth.com` (`apps/app-frontend/src/config.ts`,
`archonBaseUrl` default). Confirmed live-reachable (see §0).

**Evidence gathered pre-live-test:**

- `docs.modrinth.com/api/` (fetched) documents ordinary Modrinth PATs
  (`mrp_...` format, created at `https://modrinth.com/settings/account`) sent
  as a **bare** `Authorization` header — no `Bearer` prefix — against the
  general (labrinth) API. It does **not** document any servers/Archon
  endpoints at all; Archon is a separate API surface with separate docs.
- `packages/api-client/src/features/auth.ts` (`AuthFeature`) is the *generic*
  token-injection feature the client uses for both `labrinth` and `archon`
  requests. Its own doc comment example is:
  ```ts
  const auth = new AuthFeature({
    token: async () => process.env.MODRINTH_TOKEN
  })
  ```
  i.e. the official client's own example wires the **same** `MODRINTH_TOKEN`
  PAT into the generic bearer-style auth feature used for Archon calls too —
  strong circumstantial evidence a standard PAT is the intended credential,
  not a browser-only session JWT.
- `packages/api-client/src/features/node-auth.ts` (`NodeAuthFeature`) is a
  **separate, second-tier** short-lived JWT used only for direct
  node/filesystem access (Kyros `fs` API), obtained via
  `GET /modrinth/v0/servers/:id/fs` and auto-refreshed on 401 with a decode
  of the JWT `exp` claim. This is NOT the primary Archon credential — it's a
  scoped, short-lived token you exchange for using the primary credential.
  This explains the docs' `Authorization: Bearer <JWT>` example: it likely
  describes this secondary node/session token, not the primary API
  credential.
- Pre-flight probing (garbage token, no real credential used) against
  `GET /modrinth/v0/servers/<uuid>` with `X-Panel-Version: 1`:
  ```
  Authorization: Bearer <garbage>   -> HTTP 500 (empty body — looks like an
                                        unhandled JWT-decode crash on a
                                        non-JWT Bearer value)
  Authorization: <garbage, no prefix> -> HTTP 401 {"error":"...", "description":"authorization error"}
                                        (clean, structured auth rejection)
  ```
  The bare-token path fails **gracefully** like a normal PAT check; the
  Bearer-prefixed path fails **ungracefully**, consistent with the server
  trying to decode it specifically as a JWT and choking on a non-JWT string.
  This is suggestive but not proof — a live test with the real token is
  required to confirm, which is exactly what the ticket's required GitHub
  Actions probe (§ Live auth test, below) does.

**AUTH VERDICT:** see the "Live auth test" section below for the confirmed,
evidence-backed answer using the real `MODRINTH_TOKEN` org secret.

## 2. RE-POINT — setting `upstream`

**Endpoint:** `POST /modrinth/v0/servers/:id/reinstall?hard=<bool>`
Source: `packages/api-client/src/modules/archon/servers/v0.ts`,
`ArchonServersV0Module.reinstall()`.

**Request body** (`Archon.Servers.v0.ReinstallModpackRequest`, from
`packages/api-client/src/modules/archon/types.ts`):
```json
{ "project_id": "<modrinth project id>", "version_id": "<modrinth version id>" }
```
(`version_id` is optional in the type — omitting it presumably installs the
project's current/latest version; this spike always passes it explicitly.)
The `hard` query param controls whether existing server data is wiped
(`hard=true`) or preserved (`hard=false`) — `repoint.sh` uses `hard=false`.

**There is no separate "update upstream" endpoint.** `reinstall` is both the
re-point and the install call in one — the `Server.upstream` field
(`{kind, project_id, version_id}`, `UpstreamKind = 'modpack' | 'none'`) is
read-only state that `reinstall` changes as a side effect, confirmed by the
type definitions in the same file. Full request/response shape and the
live before/after transcript proving `upstream.version_id` actually changes
is in "Live re-point + restart proof" below.

## 3. RESTART / APPLY — making the new version run

**Not fully separable from Q2 by source alone** — the source docs don't say
whether `reinstall` restarts the server process automatically or leaves it
stopped. What's confirmed from source:

- `POST /modrinth/v0/servers/:id/power` with body `{"action": "Restart"}`
  (also `"Start"`, `"Stop"`, `"Kill"`) is the explicit power-control endpoint
  (`ArchonServersV0Module.power()`).
- State changes are pushed over the server's console WebSocket as events
  (`WSPowerStateEvent`, `WSInstallationResultEvent` — `archon/types.ts`),
  meaning a client is expected to *watch* for completion/power-state rather
  than assume synchronous completion from the HTTP response alone.

`repoint.sh`'s sequence (both to be safe and to produce the evidence this
question needs) is: `reinstall` → explicit `power(Restart)` → re-`GET` to
confirm. The live transcript below records whether the explicit Restart was
necessary or redundant.

## 4. SERVER ID

**API shape:** the server object's id field is named `server_id` (not `id`)
— `Archon.Servers.v0.Server` in `packages/api-client/src/modules/archon/types.ts`.
Returned by both `GET /modrinth/v0/servers` (list, wrapped in
`{servers: Server[], pagination, users}`) and `GET /modrinth/v0/servers/:id`
(single). Must be a UUID (confirmed empirically in §0 — a non-UUID path
segment 400s with "failed to parse ... string_uuid").

**Dashboard/UI location:** the web frontend's server management route is
`apps/frontend/src/pages/hosting/manage/[id].vue` in modrinth/code (confirmed
via `gh api search/code` against the monorepo), i.e. a human manages a server
at `https://modrinth.com/hosting/manage/<server_id>` — the id is the last URL
path segment on that page.

**Real value:** see "Live auth test" below — recorded there once the
list-servers call runs against the real account.

## 5. VERSION LOOKUP

**Endpoint:** `GET https://api.modrinth.com/v2/project/{id}/version` — public,
no authentication required. Confirmed live:

```
GET https://api.modrinth.com/v2/project/t1tOiUHZ/version
HTTP 200
13 versions returned, newest first, e.g.:
  id=BSg2ZS8u  version_number=6.0.0-alpha-f  date_published=2026-06-15T00:34:52Z  game_versions=[1.21.1]
  id=3XKDXorU  version_number=6.0.0-alpha-e  date_published=2026-05-16T23:04:46Z  game_versions=[1.21.1]
  id=Tg9n3zcA  version_number=6.0.0-alpha-d  date_published=2026-04-27T00:44:47Z  game_versions=[1.21.1]
```
(project `t1tOiUHZ` = "Create+", a small public modpack with 13 versions,
found via `GET /v2/search?query=create&facets=[["project_type:modpack"]]`.)
Response is a JSON array of version objects, newest-first; `[0]['id']` is the
latest version id. `repoint.sh` uses exactly this call/logic when `VERSION_ID`
is omitted.

## 6. FALLBACK — SFTP + console over WebSocket

**SFTP:** the `GET /modrinth/v0/servers/:id` (and list) response embeds the
credentials directly in-line — `sftp_username`, `sftp_password`, `sftp_host`
fields on the `Server` object (`archon/types.ts`). So the fallback still
needs the **same primary Archon credential** (§1) to fetch those fields; it
is not an independent auth path, just a different mechanism (file upload via
SFTP instead of the `content_v0`/`reinstall` API) once you have them. Per the
ticket's ground rules this spike does **not** fetch or exercise these
credentials against the real server — this section is sourced from the type
definition only, not exercised live. sftp.modrinth.gg:2022 (named in the
ticket) is consistent with `sftp_host`/a fixed port pattern but wasn't
independently re-derived here.

**Console:** `GET /modrinth/v0/servers/:id/ws` returns `{url, token}`
(`Archon.Websocket.v0.WSAuth`) — again gated by the primary Archon credential.
The client then opens a WebSocket to that `url` and sends
`{"event": "auth", "jwt": "<token>"}` to authenticate the socket
(`WSAuthMessage` in `archon/types.ts`), after which `{"event": "command",
"cmd": "..."}` runs console commands and the server pushes back events
(`output`, `stats`, `power-state`, `installation-result`, etc.).

**Conclusion:** the SFTP/console fallback is not actually independent of the
Archon API credential — both are *obtained through* an authenticated Archon
call. If the primary credential is rejected outright, this fallback doesn't
help; it would only be useful if the primary credential works for
read-endpoints but is scoped away from mutation endpoints (i.e. a
partial-auth scenario), which the live test below also has evidence on.

## Live auth test (GitHub Actions)

**Status: BLOCKED on a GitHub platform constraint, not yet run.**
`workflow_dispatch` can only be triggered for a workflow file that is
registered on the repo's *default* branch — this is documented GitHub
behavior, confirmed empirically: `gh api
repos/brooswit-minecraft/schematic/actions/workflows` does not list
`.github/workflows/probe-auth.yml` even though it is pushed to branch
`KAN-723` (commit `3b2d73e`), and `gh workflow run probe-auth.yml --ref
KAN-723` 404s with "workflow probe-auth.yml not found on the default
branch." Flagged on KAN-723 (comment 2026-08-28T16:28) asking how to proceed
without unilaterally pushing to `main`. This section will be filled in with
the real HTTP status codes (and, if accepted, the real server id) once
unblocked.

## Live re-point + restart proof

**Status: BLOCKED on the same auth-test dependency above** — `repoint.sh` is
written and passes `bash -n` and local dry-run testing (argument validation,
error paths, the public version-lookup call), but the archon calls it makes
need the same live credential/dispatch path as the auth test to produce a
real before/after transcript against the human's paid server.

## AUTH VERDICT

**Not yet final — pending the live GitHub Actions test above.** Current
best-evidence hypothesis from source alone: a bare-token PAT (the same
`MODRINTH_TOKEN` used for `mc-publish`/releases) is the credential Archon
expects, sent as a plain `Authorization: <token>` header (no `Bearer`
prefix) alongside the mandatory `X-Panel-Version: 1` header — NOT the
`Authorization: Bearer <JWT>` form shown in the third-party docs, which more
likely describes the secondary short-lived node/console token obtained
*through* the primary Archon call. This will be confirmed or corrected by
the live test.
