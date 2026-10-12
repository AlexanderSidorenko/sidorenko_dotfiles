# The consumer-facing interface

**Read this before changing anything under `nix/` or `manifests/`.**

This repo is standalone — `install.sh` needs nothing else — but it is also a
**dependency** of other repos. A NixOS host takes it as a pinned flake input
and imports the module below:

```
it_infra  ──(pinned flake input)──▶  sidorenko_dotfiles
```

Which means an edit *here* can break a machine *there*, and the breakage
surfaces only after someone bumps the pin — possibly weeks later, in a repo
whose author has no idea this file changed. So the surface a consumer depends
on is written down here, and `nix/tests/interface.nix` **enforces** it as a
`nix flake check`. Change the contract deliberately; do not drift out of it.

Nothing in this file constrains `install.sh`, the Ubuntu path, or any dotfile
content. It is only about what a Nix consumer may rely on.

## What a consumer may rely on

### Flake outputs

| Output | Guarantee |
|---|---|
| `homeModules.default` | A home-manager module. Importable, evaluates with no required arguments. |
| `lib.manifests` | A function taking `{ lib }` and returning the manifest reader. |
| `packages.<system>.gitpane` | The one tool not in nixpkgs. |
| `checks.<system>.manifests` | Manifest validation. |
| `checks.<system>.nixos-vm` | The booted NixOS test (x86_64-linux only). |
| `checks.<system>.interface` | This contract. |

A consumer may also re-export `checks.<system>.nixos-vm` as its own check, so
the same test runs in both repos, built against whichever nixpkgs the consumer
pins (its `follows` reaches our `nixpkgs` input).

### Module options — `sidorenkoDotfiles.*`

| Option | Type | Why a consumer needs it |
|---|---|---|
| `enable` | bool, default true | Turn the whole layer off. |
| `livePath` | **str**, not path | Where the working tree lives. Must stay a string: a Nix path copies the repo into the store and makes every symlink immutable, defeating live editing. |
| `gui` | bool | Gates `gui`-tagged packages and links. A headless host sets false. |
| `manageGnomeSettings` | bool | Whether to install the gsettings user unit. |
| `sourceRev` | str | The rev the consumer pinned, so activation can warn when the live tree has moved past it. |

**Renaming or removing any of these breaks consumers silently** — the module
system errors on an unknown option, so the consumer's whole system stops
evaluating. Add options freely; removing one is a breaking change.

### Manifest reader — `lib.manifests { lib }`

Must provide: `packagesFor`, `packagesFrom`, `linksFor`, `linksOfKind`,
`singleLinkOfKind`, `packageRows`, `linkRows`.

`packagesFor` / `linksFor` / `linksOfKind` / `singleLinkOfKind` take
`{ gui, nixos, platform }`. `packagesFrom` takes `pkgs` then that set.

### Manifest files and their appliers

`manifests/` must contain `packages.txt`, `links.txt`, `gsettings.txt`,
`manifest-lib.sh`, `manifest.nix` *(at `nix/manifest.nix`)*, `apply-links.sh`,
`apply-gsettings.sh`, `validate.sh`, `verify-applied.sh`.

The module and the consumer's tooling invoke these with specific flags, so the
flags are part of the contract:

| Script | Flags relied on |
|---|---|
| `apply-links.sh` | `--dotdir`, `--links`, `--nixos`, `--on-conflict`, `--gui`/`--no-gui`, `--quiet` |
| `apply-gsettings.sh` | `--nixos`, `--quiet` |
| `validate.sh` | `--quick`, `--dotdir` |
| `verify-applied.sh` | `--tsv`, `--gui`/`--no-gui`, `--nixos`/`--no-nixos`, `--platform`, `--skip` |

### Manifest vocabulary

Removing a **kind** or a **tag** silently changes what gets applied, because
rows using it stop matching rather than erroring.

- `links.txt` kinds: `link`, `link-children`, `copy`, `shell-source`,
  `git-include`, `ssh-include`, `firefox-user-js`
- tags: `linux`, `darwin`, `gui`, `no-nixos`, `nixos-only`, `nobin`, `bin:NAME`

### `verify-applied.sh` TSV format

`status<TAB>category<TAB>item<TAB>detail`, with `#`-prefixed header lines.
`status ∈ PASS | FAIL | SKIP`. Exit 0 only when there are no `FAIL` rows.
`tests/compare-platforms.sh` and the consumer's VM test both parse this.

### The nixpkgs rev

`flake.nix` must contain a literal `github:NixOS/nixpkgs/<40-hex>` URL.
`nix-packages.sh` greps it back out to pin the Ubuntu install, and a consumer
may compare it against its own pin to detect drift. A flake's `inputs` block
cannot interpolate, so this literal is necessarily the only copy of the value.

## What is explicitly NOT contract

Free to change without warning anyone:

- the contents of any dotfile (`shrc`, `tmux.conf`, `nvim/`, …)
- which packages are in `packages.txt`, which links are in `links.txt`
- `install.sh` and everything it does — no Nix consumer runs it
- `tests/ubuntu-vm.sh`, `tests/compare-platforms.sh`
- internals of the appliers, as long as the flags above keep working

## If you need a breaking change

1. Make it, and update `nix/tests/interface.nix` in the same commit — the check
   exists to force that conversation, not to be worked around.
2. Say so in the commit message, since the consumer's pin bump is where it
   lands.
3. Grep the consumer for the thing you removed. For it_infra that is
   `desktop/nixos/home.nix` (the options) and `desktop/nixos-apply.sh` (the
   script flags and the rev).
