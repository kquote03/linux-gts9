# Agent instructions for this repo

This is `linux-tabs9-port`: a mainline Linux port for the Samsung Galaxy Tab
S9 5G (SM-X716B, Qualcomm SM8550). Before acting, read (don't re-derive):

- `docs/porting-log.md` — the dated, session-by-session engineering diary.
  Authoritative for *why* things are the way they are, not just *what*.
  Start here to avoid repeating dead ends.
- `docs/hardware-facts.md` — ground-truth device facts (measured vs.
  assumed vs. inherited from a reference device).
- `docs/distro-porting.md` — the contract a rootfs builder must satisfy
  (device overlay application, firmware staging, ALSA UCM, etc.) and how
  each of the three real distro targets (Fedora, NixOS, Debian) implements
  it.
- `README.md` — human-facing feature-status summary.

**Current state**: Fedora (`scripts/build-fedora-rootfs.sh`) is the active
base for continued feature work, per explicit user direction (see
`docs/porting-log.md` Session 15). NixOS and Debian are both real-hardware-
validated alternate targets, not the current focus.

## Git workflow for this repo

When asked to commit/push work here (`kquote03/linux-gts9`): branch off
`main` first, commit, push the branch — then **merge that branch into
`main` and push `main` directly**. Don't stop at "here's a PR link," and
don't leave the feature branch sitting open/unmerged.

```
git checkout -b <branch>
# commit ...
git push -u origin <branch>
git checkout main && git pull
git merge --no-ff <branch>
git push origin main
git branch -d <branch> && git push origin --delete <branch>
```

This is a standing preference for this repo, not a one-off — apply it on
every commit/push without asking again. Still only commit/push when
actually asked to.
