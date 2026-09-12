# Kallos

A Wayland desktop: a compositor, a session daemon, a control CLI, an overlay,
and a few apps. This repo is the **superproject** — it holds no source of its
own, only a git submodule per component, the combination of commits known to
work together, and the scripts that turn that into an installed system.

## A new machine

```sh
git clone --recursive git@github.com:tmathews/kallos.git
cd kallos && ./dev
```

That is the whole of it. `./dev` is `./dev install`, and `install` means the
machine, not a file copy — it works through eight steps — the tree first, then
the machine — in the order they depend on each other:

| | |
|---|---|
| **submodules** | every component checked out at the commit this repo records |
| **packages** | pacman's list, then muon built from source (it isn't packaged on Arch) |
| **build** | the compositor through muon, then cargo for the rest |
| **binaries** | copied into `/usr/local` |
| **network** | networkd, resolved, iwd, DHCP, and the `resolv.conf` stub symlink |
| **login screen** | greetd + phylax, and this machine's GPU into the initramfs |
| **boot** | kernel flags and the loader timeout — firmware logo straight to the login screen, no console in between |
| **verify** | 23 checks against a headless session |

**Every step is checked first and only then offered.** A machine that is
already set up prints OK lines and asks nothing, so the same command is the
fresh-install command, the update command and the repair command — there is no
way to tell which one you are running, and nothing is one-shot. Answering `n`
to anything leaves that part exactly as it was and the run carries on; what you
declined is listed at the end, and re-running offers it again.

To see the whole report without changing anything:

```sh
./dev install -n      # check everything, touch nothing
```

Two of the steps edit `/etc` and `/boot` and take effect at the next reboot, so
they are worth knowing before you answer `y`. The **boot** step puts `quiet
fbcon=vc:2-6` and friends on the kernel command line: after it VT1 has no text
console at all, the rescue console is Ctrl+Alt+F2, and the fallback boot entry
stays verbose as the way back in. `phylax/docs/boot.md` has the measurements
behind each flag. The **network** step rewrites the resolver — Arch ships
`/etc/resolv.conf` as a real file, which permanently defeats systemd's own
tmpfiles rule and is why a captive-portal login hangs for minutes instead of
loading.

Both undo themselves, and `./dev` has no verb for it on purpose — reverting is
rare, deliberate, and reads better spelled out:

```sh
scripts/boot.sh revert
scripts/net.sh revert
```

Then reboot into it.

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

Two verbs. Neither of them needs git, and neither needs you to think about
pins.

```sh
./dev pull     # everything to its latest main — submodules and this repo
./dev push     # publish all the work, and record it here in one commit
./dev status   # where everything is, and which of the two to run
```

`pull` fetches, fast-forwards every submodule to its own `origin/main`, and
brings this repo up to date with its own. Commits you made but never pushed get
rebased onto the new tip and the line says so. A rebase that conflicts is
aborted cleanly — the submodule is left exactly as it was found, with the one
command to resolve it by hand.

`push` goes the other way, in the order that makes the result clonable:
every submodule's commits first, then one commit here recording the new pins.
**You do not write that commit message.** It is assembled from the submodules'
own logs, which already describe the work:

```
pin kosmos +4, phylax +1  (5 commits)

kosmos  a1b2c3de..9f8e7d6c  4 commits
    Fix damage tracking on rotated outputs
    ...

phylax  40affb1f..3dfd25ca  1 commit
    Stop the delay inhibitor leaking on resume
```

One submodule with one commit gets that commit's subject as the subject line —
`pin phylax +1` says strictly less than what it is pinning.

Both verbs stop before touching anything if a submodule is **not on `main`**.
This tree tracks main and only main, and guessing what to do with a branch
somebody is in the middle of is how work gets lost. `push` also stops on
**uncommitted changes**, anywhere — publishing a pin that silently excludes the
edit you were in the middle of is the exact surprise this exists to prevent.
`pull` reports them and carries on, because bringing in new code does not
threaten them.

When two machines have both pinned, the second one's `push` is rejected and
says so; `pull` merges the two sets of pins — resolving any collision to the
tips, which is what "work on latest main" means — and the next `push` lands.

Submodules are always left on a real local `main` with upstream tracking, never
on a detached HEAD, so you can just start editing in one and commit normally.

### The pins, and when they matter

`pull` and `push` always go to the tips, so most days the recorded pins are
just a side effect. They exist for one thing: a fresh clone, and `./dev
install`, build the exact combination this repo records — not whatever the tips happen to
be that morning. `./dev sync` puts the submodules back on that combination,
which is the command to reach for when a pull brought in something broken.

## Commands

Four, and a fifth for when a pull goes wrong.

```
./dev [install]     the whole machine: check every step, offer to fix it, build
./dev pull          everything to its latest main
./dev push          publish all work, pin it, commit it, push it
./dev status        where everything is, and what to run next
./dev sync          put the submodules back on the pins this repo records
```

`deps`, `session`, `boot`, `net`, `build`, `verify` and `doctor` used to be
commands here and are now steps inside `install` — `doctor` is `install -n`.
Typing any of them still tells you where it went. To run one on its own, or to
undo one, go straight to the script: they are all independently runnable and
always will be.

Useful flags: `-n`/`--dry-run`, `--yes`, `--apps`, `--debug`/`--release`,
`--prefix=P`, `--no-deps`, `--no-verify`. `./dev --help` has the rest.

A user prefix needs no sudo:

```sh
./dev --prefix="$HOME/.local"
```

## Scripts

`./dev` is a dispatcher and owns no build knowledge. Each script below stays
independently runnable, and running them directly is the normal way to iterate.

| | |
|---|---|
| `scripts/deps.sh` | the Arch package list, muon, and the group/seat checklist |
| `scripts/repo.sh` | the submodule engine behind `pull`/`push`/`status`/`sync` |
| `scripts/build.sh` | the compositor through kosmos's own muon build, then cargo |
| `scripts/install.sh` | copies the binaries into `$PREFIX`; never builds. The *binaries* step, not the `install` command |
| `scripts/session.sh` | the login screen and the boot GPU — checks, then asks |
| `scripts/boot.sh` | kernel flags, the GPU into the initramfs, loader timeout; `initramfs` alone, and `revert` |
| `scripts/net.sh` | networkd/resolved/iwd, DHCP, and the resolv.conf stub symlink; `revert` undoes it |
| `scripts/verify.sh` | 24 checks against a headless session — no sudo, no TTY, **no live session** (it kills every compositor it finds) |
| `scripts/lib/out.sh` | the shared output vocabulary — headers, labels, colour |
| `scripts/lib/detect.sh` | what this machine is: init, seat backend, packaging, initramfs |
| `test.sh` | build, install, and run a session on the primary TTY |

The build always runs unprivileged and the install only copies, so cargo never
runs under sudo and never leaves root-owned artifacts in a `target/`. `./dev`
refuses to run as root for the same reason.
