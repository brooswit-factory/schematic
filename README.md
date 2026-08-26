# schematic

A boilerplate repository for a Minecraft **1.20.1 / Forge** modpack, managed with
[packwiz](https://packwiz.infra.link). Clone it, swap in your own mods, and you have a
modpack project that builds and validates itself on every push.

Out of the box the pack contains the [Create](https://modrinth.com/mod/create) mod and
nothing else — it is a starting point, not a curated pack.

| | |
|---|---|
| Minecraft | 1.20.1 |
| Loader | Forge 47.4.10 |
| Mods | Create (`mc1.20.1-6.0.8`) |

## Prerequisites

- [packwiz](https://packwiz.infra.link) — the pack manager. It publishes no tagged
  releases, so this repo pins a commit SHA (`PACKWIZ_REF` in the `Makefile`).
- [Go](https://go.dev) 1.23+, only if you want `make tools` to install that pinned
  packwiz for you. If you already have a packwiz on your `PATH`, it is used instead.

```sh
make tools     # installs the pinned packwiz into ./bin (needs Go)
```

## Build it locally

```sh
make build     # -> build/schematic-<version>.mrpack
```

CI runs these same `make` targets, so a local build and a CI build cannot drift.

```sh
make check     # fails if the committed index.toml is stale
make refresh   # rewrite index.toml after changing files by hand
make clean     # remove build/ and bin/
```

## Add or remove a mod

```sh
packwiz modrinth add <slug>     # e.g. packwiz modrinth add jei
packwiz remove <name>           # e.g. packwiz remove jei
```

Both commands update `index.toml` for you. Commit the resulting `mods/<name>.pw.toml`
along with the changed `index.toml` and `pack.toml` — CI fails if the index does not
match what is on disk.

packwiz also has `packwiz curseforge add` and `packwiz url add` if a mod is not on
Modrinth. Note that `packwiz modrinth export` restricts downloads to domains Modrinth
allows, so URL-sourced mods may not be exportable.

## What is in the repo

```
pack.toml               pack metadata — name, version, Minecraft and Forge versions
index.toml              generated file list with hashes; do not edit by hand
mods/*.pw.toml          one file per mod, pinning a version and its hash
.packwizignore          repo files (docs, CI, Makefile) kept out of the pack
.github/workflows/ci.yml  validates the index and builds the .mrpack on every push
Makefile                the build entry point, shared by humans and CI
```

No jars are committed — `.pw.toml` files reference downloads by URL and hash, and
packwiz fetches them at export time.

## CI

`.github/workflows/ci.yml` runs on every push to `main` and on every pull request. It
installs the pinned packwiz, fails if `packwiz refresh` produces a diff, builds the
pack, and uploads the resulting `.mrpack` as a workflow artifact.

## Coming in this template

This repo is being built out in stages. Still to land:

- **Release publishing** — tag a release and have CI publish the `.mrpack` to Modrinth.
- **Server update** — CI uploads the pack to a game server over FTP, then announces and
  reloads it over RCON.
- **Full usage guide** — a proper walkthrough of forking this template for your own pack.
