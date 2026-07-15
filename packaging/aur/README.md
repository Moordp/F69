# AUR publishing for f69

One-time setup (needs an AUR account with your SSH key registered at
https://aur.archlinux.org):

```sh
git clone ssh://aur@aur.archlinux.org/f69.git aur-f69   # empty repo claims the name
cp PKGBUILD aur-f69/ && cd aur-f69
updpkgsums                       # pins the real sha256 of the tag tarball
makepkg --printsrcinfo > .SRCINFO
git add PKGBUILD .SRCINFO && git commit -m "f69 0.10.1-1" && git push
```

Per release: bump `pkgver`, reset `pkgrel=1`, rerun `updpkgsums` +
`--printsrcinfo`, commit, push.

Test locally before pushing (on any Arch box/VM):

```sh
makepkg -si      # builds in a chroot-less env; use extra-x86_64-build for clean-room
```

Notes:

- `prepare()` runs `zig build --fetch` — hash-pinned deps from
  build.zig.zon land in a build-local cache. AUR convention prefers all
  network in `source=()`; zig has no tarball-per-dep story yet, and this
  is the accepted pattern for zig packages.
- Arch's `zig` package satisfies `minimum_zig_version` 0.16.0. If Arch
  jumps to a breaking zig before we do, pin via `zig-bin` in makedepends.
- The v0.10.1 tag predates the 2026-07-15 bug fixes (sync crash, wrong
  row clicks, phantom UPDATE badge, invisible settings titles). Cut a
  v0.10.2 tag before first publish so Arch users start on the fixed
  build.
