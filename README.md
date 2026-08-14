# Kallos

A Wayland desktop: a compositor, a session daemon, a control CLI, an overlay,
and a few apps. This repo is the **superproject** — it holds no source of its
own, only a git submodule per component, the combination of commits known to
work together, and the scripts that turn that into an installed system.

## A new machine

```sh
git clone --recursive git@github.com:tmathews/kallos.git
cd kallos && ./kallos
```

`./kallos` installs the system packages, builds muon from source (it isn't
packaged on Arch), checks out every submodule at its recorded commit, builds
everything, and installs it to `/usr/local`. Run it again a week later and it
updates instead — there is no separate init, because `up` is idempotent.

Then start a session from a TTY:

```sh
./test.sh
```

Arch only, for now: `scripts/deps.sh` speaks pacman. On anything else, pass
`--no-deps` and install the equivalents by hand — the lists, grouped by which
component needs them, are at the top of that file.

## Layout

The submodules sit flat, as siblings, and must stay that way: all five Rust
binaries declare `kallos = { path = "../kallos-lib" }`.

| | |
|---|---|
| `kosmos/` | the compositor — the last C in the tree. Binary: `kosmos` |
| `kallosd/` | the session daemon and session root |
| `kallosctl/` | the control CLI |
| `hajime/` | the overlay |
| `kallos-lib/` | the `kallos` crate the Rust binaries share |
| `yggdrasil/` `torrential/` `renzoku/` | apps — opt-in, `--apps` |

`kstart/` (frozen C legacy, the parity oracle for `scripts/verify.sh`) and
`kbrowser/` are **not** submodules. Clone them alongside if you want them; the
root ignores both.

## Working across machines

The superproject records an exact commit per submodule, so a fresh clone gets a
combination that built. Day to day:

```sh
./kallos status          # branch, dirty, ahead/behind, pin drift — read this first
./kallos push            # publish every submodule, so the pins are clonable
./kallos pin -m "..."    # record where the submodules are now
./kallos up --latest     # move them to their origin/main tips instead
```

`sync` never touches a submodule with uncommitted changes or unpushed commits —
it reports and skips. So on the machine you left work on, `./kallos` tells you
what is unfinished rather than quietly discarding it.

Submodules are always left on a real local `main` with upstream tracking, never
on a detached HEAD, so you can just start editing in one and commit normally.

## Commands

```
./kallos [up]         deps -> sync -> build -> install -> verify
./kallos status       where every submodule is
./kallos sync         move submodules to the recorded pins
./kallos pin [-m MSG] record where they are now
./kallos push         publish every submodule
./kallos deps         packages and muon, nothing else
./kallos doctor       preflight — reports, writes nothing
./kallos build|install|verify
```

Useful flags: `--latest`, `--pin`, `--pull`, `--apps`, `--debug`/`--release`,
`--prefix=P`, `--no-deps`, `--no-install`, `--no-verify`, `-n`. `./kallos --help`
has the rest.

A user prefix needs no sudo:

```sh
./kallos --prefix="$HOME/.local"
```

## Scripts

`./kallos` is a dispatcher and owns no build knowledge. Each script below stays
independently runnable, and running them directly is the normal way to iterate.

| | |
|---|---|
| `scripts/deps.sh` | the Arch package list, muon, and the session checklist |
| `scripts/sync.sh` | the submodule engine behind `sync`/`status`/`pin`/`push` |
| `scripts/build.sh` | the compositor through kosmos's own muon build, then cargo |
| `scripts/install.sh` | copies into `$PREFIX`; never builds |
| `scripts/verify.sh` | 13 checks against a headless session — no sudo, no TTY |
| `test.sh` | build, install, and run a session on the primary TTY |

The build always runs unprivileged and the install only copies, so cargo never
runs under sudo and never leaves root-owned artifacts in a `target/`. `./kallos`
refuses to run as root for the same reason.
