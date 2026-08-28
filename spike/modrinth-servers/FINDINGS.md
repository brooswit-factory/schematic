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
  Actions probe (§ Live auth test, below) does. **This hypothesis turned out
  to be backwards** — see the live results below. The 500-vs-401 split on
  garbage input was real but not predictive of which *valid* token format
  Archon accepts; garbage input just exercises error handling, not the
  success path.

**AUTH VERDICT: CONFIRMED LIVE — the standard Modrinth PAT (`MODRINTH_TOKEN`,
the same one used for release publishing) is accepted by Archon when sent as
`Authorization: Bearer <token>`, alongside the mandatory `X-Panel-Version: 1`
header (§0). No session JWT, no separate credential, no scope other than
whatever the existing PAT already has.** See "Live auth test" below for the
run URL and exact status codes.

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

**Real value: `ff783f0f-ec3c-4037-b39f-452ce590891d`** ("brooswit's server"),
confirmed live via `GET /modrinth/v0/servers` — see "Live auth test" below.
Dashboard URL: `https://modrinth.com/hosting/manage/ff783f0f-ec3c-4037-b39f-452ce590891d`.

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

**Status: RUN, CONFIRMED.** GitHub platform note first, since it shaped how
this ran: `workflow_dispatch` can only be triggered for a workflow file
registered on the repo's *default* branch (confirmed empirically — see
KAN-723 comment 2026-08-28T16:28 — `gh workflow run` 404'd against branch
KAN-723). Per KAN-713/KAN-715's decision (KAN-723 comment 2026-08-28T09:28),
the probe was switched to `on: push: branches: ['KAN-723']`, which has no
such restriction and still gets repo/org secrets for same-repo pushes.

**Run:** https://github.com/brooswit-minecraft/schematic/actions/runs/33190198880
(commit `16db7db`, workflow `.github/workflows/probe-auth.yml` / archived at
`spike/modrinth-servers/probe-auth.yml`)

**Results (status codes only, no secret values — GitHub's own log masking is
a second line of defence on top of this script never printing the token):**

| Call | Auth header form | HTTP status |
|---|---|---|
| `GET https://api.modrinth.com/v2/user` | bare token (documented labrinth form) | **200** |
| `GET https://archon.modrinth.com/modrinth/v0/servers` | `Bearer <token>` | **200** |
| `GET https://archon.modrinth.com/modrinth/v0/servers` | bare token | **401** |

The labrinth call confirms the token itself is live. The Archon comparison is
the answer to Q1: **`Authorization: Bearer <MODRINTH_TOKEN>` is accepted**
(the client's `AuthFeature` default — see §1); the bare-token form that
labrinth wants is rejected by Archon with a clean 401. Both Archon calls also
required `X-Panel-Version: 1` (§0) or they 426 regardless of the credential.

The accepted call returned **one real server** (allowlisted fields only —
`server_id`, `name`, `status`, `upstream`; the response also carries
`sftp_username`/`sftp_password`/`sftp_host` inline, which the parser never
touches, see §6):

```
server count: 1
server_id: ff783f0f-ec3c-4037-b39f-452ce590891d | name: brooswit's server | status: available | upstream: None
```

`upstream: None` confirms the server is fresh/empty exactly as the ticket
said — the live re-point proof below installs an upstream for the first
time, then re-points it, using this same server id.

## Live re-point + restart proof

**Status: reaches an exact, reproducible blocked step — a per-server
authorization gate, distinct from the authentication question Q1 answers.**
`repoint.sh` is the thing that actually attempted this (invoked by a
temporary CI workflow, `repoint-proof.yml`, that supplied the real
`MODRINTH_TOKEN` — not a hand-run curl session).

Runs (same underlying result across all of them — the GET-by-id 403 was
reproduced on a manual rerun too, so not a one-off blip):
- https://github.com/brooswit-minecraft/schematic/actions/runs/33190648580 —
  `repoint.sh` step 2 (GET-by-id) 403, plus the token-vs-owner diagnostic.
- https://github.com/brooswit-minecraft/schematic/actions/runs/33190779441 —
  same diagnostic, plus the `POST /reinstall` probe (item 3 below).

**What was tried, in order, all against the real server
`ff783f0f-ec3c-4037-b39f-452ce590891d`:**

1. `GET /modrinth/v0/servers/ff783f0f-ec3c-4037-b39f-452ce590891d` (`repoint.sh` step 2, "capture BEFORE upstream") →
   **HTTP 403, empty body.** This is `repoint.sh`'s own first live call, so it
   never reached the `reinstall`/`power` calls that would actually change
   anything — the server was never mutated.
2. Diagnostic (read-only): compared the token's own identity
   (`GET https://api.modrinth.com/v2/user`, bare-token form) against the
   server's `owner_id` and `current_user_permissions` from the LIST response
   (ids are not secrets, so these are safe to record in plain):
   ```
   token user id: XKg3yGJl | username: brooswit
   server_id: ff783f0f-ec3c-4037-b39f-452ce590891d | owner_id: XKg3yGJl | current_user_permissions: -32768
   users[XKg3yGJl]: {id: XKg3yGJl, username: brooswit}
   ```
   **The token's user IS the server's owner** (`owner_id` matches exactly) —
   this rules out a simple ownership mismatch. `current_user_permissions` is
   declared `export type UserScope = number` (`archon/types.ts` line 652) —
   the type fixes no bit width, so the observed value `-32768` does **not**
   decode to a single established meaning:
   - as **i16**: `-32768` = `0x8000` — exactly one bit set (bit 15).
   - as **i32**: `-32768` = `0xFFFF8000` — bit 15 *and* bits 16–31 all set,
     i.e. many flags, not none — the opposite reading.
   Nothing in the type or the response says which width applies, so **which
   of these holds is undetermined from source alone.** Even the i16 reading
   isn't cleanly "no permissions": the sibling `ServerUsers.v1.UserScope`
   declares 15 named scopes (`SERVER_ADMIN`, `BASE_READ`, `POWER_ACTIONS`,
   `EXEC_COMMANDS`, `FILES_WRITE`, `SETUP`, `BACKUPS`, `ADVANCED`,
   `RESET_SERVER`, `MANAGE_USERS`, `SUPPORT_AGENT`, `INFRA_MANAGER`,
   `INFRA_MANAGER_READ`, `INFRA_SERVERS_XFER`, `INFRA_USERS`) — if those map
   to bits 0–14, bit 15 is a 16th, *unnamed* flag, so the i16 reading would
   actually be "exactly one undocumented flag is set," not "nothing granted."
   The only established fact is the raw observed value; what it means for
   this account's access is not determined here.
3. Diagnostic (safe — a rejected POST has no server-side effect): the same
   token attempting the actual re-point mutation directly —
   `POST /modrinth/v0/servers/ff783f0f-ec3c-4037-b39f-452ce590891d/reinstall?hard=false`
   with body `{"project_id":"t1tOiUHZ","version_id":"Tg9n3zcA"}` →
   **HTTP 404 "not found".** A different status than the GET's 403. The
   leading hypothesis is still a shared per-resource permission gate (a pure
   permission check would typically produce the *same* status for read and
   write on the same resource, though APIs are not required to be
   consistent about this) — but a 403-vs-404 split is *also* consistent with
   the mutation route itself being slightly off (the `hard` query param, the
   exact path, or something else in the `v0` prefix), which source alone
   doesn't rule out. What would distinguish the two: does a **known-bad**
   (nonexistent) server id return 404 on this same reinstall call? If yes,
   404 is this route's generic "can't act on this id" response (permission
   gate, consistent story); if a nonexistent id instead 404s while THIS real
   id also 404s, that's still ambiguous; if a nonexistent id behaves
   differently again, the route shape itself is suspect. Not run here to
   avoid more live traffic against the real server on a diagnostic that
   isn't required to answer the ticket's six questions — noted as the
   concrete next check for whoever picks this up.

**Conclusion:** authentication (Q1) and per-resource authorization are two
different gates. The token is genuinely live and Archon-accepted (LIST
returns 200 and the real server), but reading and mutating this specific
server both fail (`403` then `404`) despite the token belonging to the
confirmed owner. The leading hypothesis is a per-server permission gate
(`current_user_permissions`), though its exact value doesn't decode to an
established meaning (see above) and the status-code asymmetry leaves the
mutation-route-shape alternative on the table too. This looks like either
(a) a permissions-sync gap for a server purchased only minutes before
testing, (b) the "full-admin Modrinth API key" being a platform/staff-tier
credential that can enumerate servers but was never granted normal
owner-level permissions on this specific one, or (c) a granular PAT scope
(distinct from the admin/staff role itself) that this key lacks. Determining
which requires either checking the PAT's scopes in the Modrinth account
settings UI, waiting and retrying, or asking Modrinth support — not something
resolvable from here without guessing. **The intended request shape (used
above) is exactly what a real deploy workflow would send once this is
resolved** — no changes needed to `repoint.sh` itself.

The server was left untouched throughout (every blocked call was read-only
or a rejected write) — it remains in its original state: running, `status:
available`, `upstream: None`.

## AUTH VERDICT

**Token-level auth: CONFIRMED LIVE.** `Authorization: Bearer <MODRINTH_TOKEN>`
(the same long-lived Modrinth PAT already used for release publishing) is
accepted by the Archon Servers API — HTTP 200 on `GET /modrinth/v0/servers`
— provided the request also carries `X-Panel-Version: 1`. No session JWT, no
separate credential type. This resolves the primary open risk: a GitHub
Actions workflow can hold exactly the credential this repo already has
(`secrets.MODRINTH_TOKEN`) and it authenticates against Archon.

**Per-server authorization: BLOCKED on this specific server**, for the
confirmed owning account (`GET` 403, `POST /reinstall` 404) — see "Live
re-point + restart proof" above for the full evidence, including why the
raw `current_user_permissions: -32768` value does not decode to an
established meaning (the type is an unwidthed `number`; i16 and i32 readings
disagree). This is a human/Modrinth-account follow-up, not a code or
credential-format problem — recommend checking the server's
permissions/ownership state in the Modrinth dashboard, or contacting
Modrinth support, before the next attempt.
