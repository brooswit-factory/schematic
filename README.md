# schematic

A [packwiz](https://packwiz.infra.link) modpack **template** for Minecraft **1.20.1 /
Forge** (both are defaults you can change) — clone it, edit a couple of fields, and you
have a modpack project that validates and builds itself on every push, with release and
server-update automation available too. CI, release, and server-update are provided as
**reusable GitHub Actions workflows**, called — from the thin stubs already sitting in
this repo — at their upstream location in this template, pinned `@v1`, so you get all
three without writing any workflow logic yourself.

[brooswit-factory/schematic-example](https://github.com/brooswit-factory/schematic-example)
is the living example built from this template: a real pack (starting from the [Create](https://modrinth.com/mod/create)
mod) that began life as a clone of this repo. Look there for what a filled-in version of
this template looks like.

## Getting started

```sh
git clone https://github.com/brooswit-factory/schematic.git <yours>
cd <yours>
git remote rename origin template
git remote add origin <your repo url>
git push -u origin main
```

`template` stays as the upstream you can pull future improvements from (see
[Updating from the template](#updating-from-the-template) below); `origin` becomes your
own repo.

## Rename checklist

Almost nothing to rename. Edit the pack identity in `pack.toml`:

```toml
name = "my-modpack"      # -> your pack's name
author = "your-name"     # -> you
```

and, if you want a Minecraft version or mod loader other than the defaults, the
`[versions]` block (`minecraft`, `forge`) too — the reusable workflows derive the
Modrinth game-versions/loaders from these.

Then regenerate the index and commit:

```sh
make refresh
git add pack.toml index.toml
git commit -m "Rename pack"
```

That's it. The build artifact name (`<name>-<version>.mrpack`) is derived from
`pack.toml` automatically, and so are the Modrinth game version and loader it publishes
under — nothing to rename in the Makefile or the workflows. The Modrinth project you
publish *to* is a separate thing: it's set by the `MODRINTH_PROJECT_ID` repo variable,
not by anything in `pack.toml` (see [Secrets & variables](#secrets--variables) below).

Nothing under `.github/workflows` needs editing or deleting — see
[Template-only files](#template-only-files) below for why.

Verify with `grep -ri schematic .`: the only remaining hits should be this README, the
`uses: brooswit-factory/schematic/.github/workflows/reusable-<name>.yml@v1` line in
each of `ci.yml`, `release.yml`, and `server-update.yml`, and the
`if: github.repository == 'brooswit-factory/schematic'` guard in `tag-v1.yml`. **Leave
all of those alone** — the `uses:` lines point at this project's upstream reusable
workflows, not at your own pack, and the `tag-v1.yml` guard is what keeps that
template-only file from creating a tag in your repo (see
[Template-only files](#template-only-files) below). Renaming any of them will break the
thing they exist to do.

Optionally, you can also replace the copyright holder in `LICENSE` with your own name —
that's not required for anything to work; it's your call whether the template's MIT
license and holder should carry over to your fork.

## Updating from the template

### Pulling template changes

This repo keeps evolving — Makefile fixes, `server/` tooling, README clarifications,
improvements to the reusable workflows. Pull those into your own pack with:

```sh
git fetch template
git merge template/main                                  # expect conflicts
git checkout ORIG_HEAD -- pack.toml index.toml mods      # your pack content wins, conflicted or not
git checkout --theirs -- <other conflicted files you have not customised>
make refresh
git add -A
git commit
```

`ORIG_HEAD` is your branch tip as it was immediately before the merge — checking out
`pack.toml`, `index.toml`, and `mods/` from it restores **your own content** there no
matter what happened during the merge. It only restores paths that existed on your
branch; it never deletes, so a file the template adds under `mods/` (such as its
placeholder `mods/.gitkeep`) is kept — harmless, because `.packwizignore` keeps it out
of the exported pack.

That last point matters: git only reports a conflict on a file **both sides changed**.
If the template deletes or changes a file you never touched — most importantly a mod
file in `mods/`, or `index.toml` — there's no conflict, and the merge silently applies
the template's version, which for a deleted mod means it's just gone with nothing to
resolve. That's the intended behaviour for tooling files (`Makefile`, `server/`,
workflow stubs) that should track the template automatically, but it's exactly why the
`git checkout ORIG_HEAD -- pack.toml index.toml mods` step above is unconditional
rather than only for conflicted paths — it protects your pack content whether or not git
flagged a conflict on it.

For the `--theirs` line, "other conflicted files you have not customised" typically
means `Makefile`, `server/README.md`, and `server/start.sh` — take the template's
version of these unless you've made local edits worth preserving. `README.md` is the
one file you have almost certainly customised — reconcile it by hand: keep your
pack-specific prose and fold in template improvements where they still apply. If you
previously deleted `.github/workflows/tag-v1.yml` locally, you'll see it as a
delete/modify conflict instead of a clean merge; per
[Template-only files](#template-only-files) above, you don't need to delete it in
the first place, so the simplest fix is to keep the template's version
(`git checkout --theirs -- .github/workflows/tag-v1.yml`) rather than re-deleting it.

### The pinned workflow stubs

`ci.yml`, `release.yml`, and `server-update.yml` each pin their `uses:` line to `@v1` —
a moving tag kept pointed at this repo's `main`. Fixes and improvements to the reusable
workflows they call reach your repo automatically, with **zero merge effort** on your
part.

`v1` promises backwards-compatible inputs, secrets, and variable names; anything that
would break your workflow ships as a `v2` instead. If you'd rather not receive moving
updates, pin a specific tag or commit SHA in place of `@v1` in your stub's `uses:` line.

## Template-only files

Four files under `.github/workflows` are template-only — inert in any repo cloned from
this template, and safe to leave in place:

`tag-v1.yml` keeps the `v1` tag on **this** repo pointed at its own `main`. It is
guarded by a `github.repository` check, so it is inert in any repo cloned from this
template — the job is skipped entirely, so it creates no tag in your repo.

`reusable-ci.yml`, `reusable-release.yml`, and `reusable-server-update.yml` are
`workflow_call`-only definitions — nothing invokes them by local path. Your stubs
(`ci.yml`, `release.yml`, `server-update.yml`) call them **upstream**, at
`brooswit-factory/schematic/.github/workflows/reusable-<name>.yml@v1`, so your local
copies never run.

There's no need to delete any of the four — doing so gains nothing, since they don't
run locally either way, and it makes every future `git merge template/main` conflict on
them, exactly when a template improvement to a reusable workflow would otherwise reach
you with zero merge effort. A `git merge template/main` would just bring a deleted one
back anyway.

`ci.yml`, `release.yml`, and `server-update.yml` are the three stubs you, as a consumer
of this template, need to care about — the four template-only files above need no
attention at all.

## Secrets & variables

Everything below is optional. With none of them set, `ci.yml` still builds and uploads
the `.mrpack` as a workflow artifact, `release.yml` still builds and attaches it to the
GitHub Release, and any workflow step that needs a secret **skips cleanly** (the run
still finishes green) when it isn't configured.

| Name | Kind | Used by | Purpose |
|---|---|---|---|
| `MODRINTH_TOKEN` | secret | `release.yml` | Auth token for publishing to Modrinth (needs the **write-version** scope) |
| `MODRINTH_PROJECT_ID` | variable | `release.yml` | Identifies which Modrinth project to publish to |
| `FTP_HOST` | secret | `server-update.yml` | FTP server hostname for the pack upload |
| `FTP_USER` | secret | `server-update.yml` | FTP username |
| `FTP_PASSWORD` | secret | `server-update.yml` | FTP password |
| `FTP_REMOTE_DIR` | variable | `server-update.yml` | Remote directory to upload the pack to (default `/`) |
| `RCON_HOST` | secret | `server-update.yml` | RCON server hostname for the announce/restart |
| `RCON_PASSWORD` | secret | `server-update.yml` | RCON password |
| `RCON_PORT` | variable | `server-update.yml` | RCON port (default `25575`) |
| `RCON_RESTART_COMMAND` | variable | `server-update.yml` | Command sent after the announce (default `stop`; assumes your host auto-restarts) |

## Releasing

`.github/workflows/release.yml` cuts a release. To publish a new version:

1. Create a GitHub Release with a tag of the form `vX.Y.Z` (e.g. `v0.2.0`).
2. On publish, the workflow:
   - sets the pack version from the tag (in-workflow only — nothing is committed back),
   - builds `build/<name>-<version>.mrpack` with the same `make` targets used locally
     and in CI,
   - attaches the `.mrpack` to the GitHub Release as a download,
   - publishes the same file to Modrinth, if Modrinth is configured (see
     [Secrets & variables](#secrets--variables) above).

You can also dry-run the whole build-and-package path without creating a Release, via
`workflow_dispatch`:

```sh
gh workflow run release.yml --ref <branch> -f version=0.0.1-test
```

This builds and uploads the `.mrpack` as a workflow artifact but skips the
Release-asset step (there is no Release object to attach to) and the Modrinth publish
step, the same as any run without Modrinth configured.

## Updating a server

`.github/workflows/server-update.yml` runs on a published GitHub release, or on demand
via `workflow_dispatch` (with an optional `version` input; it otherwise falls back to
the `version` field in `pack.toml`). It uploads the packwiz pack to your game server
over FTP, then announces the update and restarts the server over RCON — see
[`server/README.md`](server/README.md) for how to set up the server side of this.

Both halves are independent and **skip cleanly** (the workflow still finishes green)
when their secrets aren't configured, so this works out of the box on a fresh clone —
you opt in by adding the secrets/variables above whenever you're ready.

## Working on the pack

```sh
packwiz modrinth add <slug>     # e.g. packwiz modrinth add jei
packwiz remove <name>           # e.g. packwiz remove jei
```

Both commands update `index.toml` for you. Commit the resulting `mods/<name>.pw.toml`
along with the changed `index.toml` and `pack.toml` (`packwiz refresh` writes the new
index hash into `pack.toml`'s `[index]` block) — **CI fails if the index does not
match what is on disk.**

packwiz also has `packwiz curseforge add` and `packwiz url add` if a mod is not on
Modrinth. Note that `packwiz modrinth export` restricts downloads to domains Modrinth
allows, so URL-sourced mods may not be exportable.

```sh
make check     # fails if the committed index.toml is stale
make refresh   # rewrite index.toml after changing files by hand
make build     # -> build/<name>-<version>.mrpack
make clean     # remove build/ and bin/
```

### Prerequisites

- [packwiz](https://packwiz.infra.link) — the pack manager. It publishes no tagged
  releases, so this repo pins a commit SHA (`PACKWIZ_REF` in the `Makefile`).
- [Go](https://go.dev) 1.23+, only if you want `make tools` to install that pinned
  packwiz for you. If you already have a packwiz on your `PATH`, it is used instead.

```sh
make tools     # installs the pinned packwiz into ./bin (needs Go)
```

### What is in the repo

```
pack.toml                           pack metadata — name, version, Minecraft and Forge versions
index.toml                          generated file list with hashes; do not edit by hand
mods/                                one *.pw.toml file per mod, pinning a version and its hash — empty by default
.packwizignore                      repo files (docs, CI, Makefile) kept out of the pack
.github/workflows/ci.yml            validates the index and builds the .mrpack on every push
.github/workflows/release.yml       cuts a release (see Releasing above)
.github/workflows/server-update.yml keeps a game server in sync (see server/README.md)
.github/workflows/tag-v1.yml        template-only (see Template-only files above)
Makefile                            the build entry point, shared by humans and CI
server/                             sample scripts for running/updating a Forge server for this pack
```

No jars are committed — `.pw.toml` files reference downloads by URL and hash, and
packwiz fetches them at export time.

### CI

`.github/workflows/ci.yml` runs on every push to `main` and on every pull request. It
installs the pinned packwiz, fails if `packwiz refresh` produces a diff, builds the
pack, and uploads the resulting `.mrpack` as a workflow artifact.

## Removing a path you don't need

- No Modrinth publishing or releases? Delete `.github/workflows/release.yml`, the
  [Releasing](#releasing) section above, and the `MODRINTH_TOKEN` /
  `MODRINTH_PROJECT_ID` rows in the [secrets & variables](#secrets--variables) table.
- No server to keep in sync? Delete `.github/workflows/server-update.yml`, the
  `server/` directory (`server/README.md` and `server/start.sh` both only make sense
  alongside it), and the [Updating a server](#updating-a-server) section and its rows
  in the [secrets & variables](#secrets--variables) table above.
