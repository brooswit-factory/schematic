# Running a server for this pack

A short, practical guide to standing up a Forge 1.20.1 server for the
modpack in this repo, and to how `.github/workflows/server-update.yml` keeps
it in sync.

## 1. Install the Forge server

Download the Forge 47.4.10 installer for Minecraft 1.20.1 from the
[Forge files page](https://files.minecraftforge.net/net/minecraftforge/forge/index_1.20.1.html),
then run it in server mode in an empty directory:

```sh
java -jar forge-1.20.1-47.4.10-installer.jar --installServer
```

On Forge 47.4.10 (1.17+), `--installServer` does **not** produce a
`server.jar`. It produces `run.sh`/`run.bat`, a `user_jvm_args.txt`, and a
`libraries/` tree — `run.sh` is the real entry point, and `start.sh`
launches through it.

## 2. Accept the EULA

Minecraft requires you to accept its EULA before the server will start.
Create `eula.txt` in the server directory (next to `run.sh`):

```
eula=true
```

`start.sh` checks for this and refuses to launch the server without it.

## 3. Install packwiz-installer-bootstrap

The server resolves and downloads its own mods from the pack, rather than
having a pre-built mod bundle uploaded to it. `start.sh` downloads the
pinned `packwiz-installer-bootstrap` release automatically on first run, so
you normally don't need to do this by hand — see the pin in `start.sh` if
you want to fetch it yourself:
<https://github.com/packwiz/packwiz-installer-bootstrap/releases>.

## 4. Where the uploaded pack lands

`.github/workflows/server-update.yml` uploads the packwiz pack directory
(`pack.toml`, `index.toml`, `mods/`, and `config/` if present) over FTP to
the path in the `FTP_REMOTE_DIR` repo variable (default `/`, i.e. your FTP
user's home/server directory). Point `start.sh` at the uploaded `pack.toml`
by setting `PACK_URL`, e.g.:

```sh
PACK_URL=./pack.toml ./start.sh
```

or, if your FTP root differs from the server's working directory, an
absolute path or URL to wherever `pack.toml` landed.

## 5. Run it

```sh
./start.sh
```

This syncs mods via `packwiz-installer-bootstrap`, checks the EULA, and
launches the Forge server via the generated `run.sh`. Set your heap in
`user_jvm_args.txt` (next to `run.sh`), e.g. uncomment and adjust `-Xmx4G`
there to match your host's available RAM — Forge reads JVM args from that
file, not from a command-line flag on `start.sh`.

## Why upload the pack, not a rendered bundle

`packwiz-installer` (run by the bootstrap jar) resolves and downloads mod
jars itself from the hashes and URLs recorded in `pack.toml`/`index.toml`.
That means:

- Uploads over FTP stay tiny — a handful of `.toml` files, not a full mod
  bundle.
- The server always ends up on exactly the same pinned mod versions as
  players' clients, because both sides read the same pack.

## Auto-restart assumption

The RCON step in `.github/workflows/server-update.yml` sends the
`RCON_RESTART_COMMAND` repo variable after announcing the update, which
defaults to `stop`. That assumes your hosting setup **auto-restarts the
server process** when it stops cleanly (a systemd unit with `Restart=on-success`,
a process manager, or your host's built-in "restart on crash/stop"
behaviour) — `stop` on its own does not relaunch anything. If your host
does not auto-restart, set `RCON_RESTART_COMMAND` to whatever command your
setup uses instead (or leave it as `stop` and restart manually/via your
host's panel).
