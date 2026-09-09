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

On its way past, `up` asks about the login screen — greetd's config is Arch's
agreety one until something replaces it, and the unit ships disabled — and
about getting this machine's GPU into the initramfs, which is what lets
phylax's greetd drop-in start the greeter without waiting on udev. Both are
offered, never assumed; answering `n` leaves the machine exactly as it was,
and `--no-session` skips the asking altogether. The same two checks on their
own, whenever you want them:

```sh
./kallos session         # check both, offer to fix each
./kallos doctor          # ...and every other preflight, reporting only
```

Then reboot into it. Optionally take the rest of the boot too — kernel flags,
the loader timeout — so the machine goes from the firmware logo straight to
the login screen with no console in between:

```sh
./kallos boot          # report what would change; writes nothing
./kallos boot apply    # ...and `./kallos boot revert` puts it all back
```

That one stays opt-in and out of `up`: it edits `/etc` and `/boot`, and after
it VT1 has no text console at all (the rescue console becomes Ctrl+Alt+F2).
The GPU half of it is the exception — `./kallos boot initramfs` is just that
piece, and it is what `up` offers above. `phylax/docs/boot.md` has the
measurements behind each flag.

On a fresh Arch install, take the network too — `iwd` only associates, so
without this there is no DHCP lease, and `/etc/resolv.conf` stays the real file
Arch ships rather than the symlink to systemd-resolved's stub, which is what
makes a captive-portal login hang for minutes instead of loading:

```sh
./kallos net           # report what would change; writes nothing
./kallos net apply     # ...and `./kallos net revert` puts it all back
```

Also opt-in, for the same reason. `./kallos doctor` says when a machine needs
it.

Or skip the login screen entirely and start a session from a TTY by hand:

```sh
./test.sh
```

Arch is the paved road, not a requirement. `scripts/deps.sh` speaks pacman and
its package names are Arch's, so on anything else it reports what Kallos needs
and hands over rather than exiting — install the equivalents, then run with
`--no-deps`. The lists, grouped by which component needs them, are at the top of
that file, and the build itself is the real check: pkg-config names whatever is
still missing far more precisely than a list can.

Nothing else assumes a distro. The scripts detect what they are running on and
adapt — which init is PID 1, whether the seat comes from **seatd** or **logind**
(libseat picks at runtime, and `scripts/lib/detect.sh` asks the same questions in
the same order), which initramfs generator is installed — and say which way it
went. A machine that answers differently gets different advice, not a refusal.

## Layout

The submodules sit flat, as siblings, and must stay that way: all six Rust
binaries declare `kallos = { path = "../kallos-lib" }`.

| | |
|---|---|
| `kosmos/` | the compositor — the last C in the tree. Binary: `kosmos` |
| `kallosd/` | the session daemon and session root |
| `kallosctl/` | the control CLI |
| `hajime/` | the overlay |
| `phylax/` | the locker and greeter |
| `kallos-lib/` | the `kallos` crate the Rust binaries share |
| `yggdrasil/` `torrential/` `renzoku/` | apps — opt-in, `--apps` |

`kbrowser/` is **not** a submodule — it has no remote yet. Clone it alongside
if you want it; the root ignores it.

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
./kallos [up]         deps -> sync -> build -> install -> session -> verify
./kallos status       where every submodule is
./kallos sync         move submodules to the recorded pins
./kallos pin [-m MSG] record where they are now
./kallos push         publish every submodule
./kallos deps         packages and muon, nothing else
./kallos session      the login screen and the boot-time GPU; asks before each
./kallos doctor       preflight — reports, writes nothing
./kallos build|install|verify
```

Useful flags: `--latest`, `--pin`, `--pull`, `--apps`, `--debug`/`--release`,
`--prefix=P`, `--no-deps`, `--no-install`, `--no-session`, `--no-verify`, `-n`.
`./kallos --help` has the rest.

A user prefix needs no sudo:

```sh
./kallos --prefix="$HOME/.local"
```

## Scripts

`./kallos` is a dispatcher and owns no build knowledge. Each script below stays
independently runnable, and running them directly is the normal way to iterate.

| | |
|---|---|
| `scripts/deps.sh` | the Arch package list, muon, and the group/seat checklist |
| `scripts/sync.sh` | the submodule engine behind `sync`/`status`/`pin`/`push` |
| `scripts/build.sh` | the compositor through kosmos's own muon build, then cargo |
| `scripts/install.sh` | copies into `$PREFIX`; never builds |
| `scripts/session.sh` | the login screen and the boot GPU — checks, then asks |
| `scripts/boot.sh` | opt-in: kernel flags, the GPU into the initramfs, loader timeout; `initramfs` alone |
| `scripts/net.sh` | opt-in: networkd/resolved/iwd, DHCP, and the resolv.conf stub symlink |
| `scripts/verify.sh` | 24 checks against a headless session — no sudo, no TTY, **no live session** (it kills every compositor it finds) |
| `scripts/lib/out.sh` | the shared output vocabulary — headers, labels, colour |
| `scripts/lib/detect.sh` | what this machine is: init, seat backend, packaging, initramfs |
| `test.sh` | build, install, and run a session on the primary TTY |

The build always runs unprivileged and the install only copies, so cargo never
runs under sudo and never leaves root-owned artifacts in a `target/`. `./kallos`
refuses to run as root for the same reason.
