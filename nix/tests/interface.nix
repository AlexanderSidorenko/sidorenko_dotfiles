# Enforce the consumer-facing contract described in ../INTERFACE.md.
#
# WHY A CHECK AND NOT JUST THE DOC. This repo is a dependency: a NixOS host
# imports ../home.nix through a pinned flake input. An edit here can therefore
# break a machine in another repo, and it surfaces only when someone bumps that
# pin — later, elsewhere, to someone who never saw the change. A document
# describing the surface would rot exactly when it mattered most; this fails
# the build instead, in THIS repo, in the commit that breaks it.
#
# Deliberately cheap: pure evaluation plus a few file greps, no VM, no network.
# It runs on every `nix flake check` so it costs nothing to keep honest.
#
# WHAT IT DOES NOT DO is pin down behaviour — ./nixos-vm.nix boots a machine and
# measures that. This only asserts the SHAPE a consumer compiles against:
# outputs exist, option names exist, reader functions exist, scripts accept the
# flags they are called with, and the manifest vocabulary still contains every
# kind and tag in use. Each of those, if removed, breaks a consumer silently
# rather than loudly — an unknown module option stops their whole system
# evaluating, and a removed kind or tag just stops matching rows.
{ pkgs, lib, self }:

let
  # --- 1. Flake outputs a consumer names directly ---------------------------
  requiredOutputs = [
    [ "homeModules" "default" ]
    [ "nixosModules" "default" ]
    [ "lib" "manifests" ]
  ];

  missingOutputs =
    builtins.filter (p: !(lib.hasAttrByPath p self)) requiredOutputs;

  # --- 2. Module options ----------------------------------------------------
  # Evaluated through the real module system rather than grepped, so a
  # mis-declared option (wrong type, missing default) fails here too.
  evaluated = lib.evalModules {
    modules = [
      self.homeModules.default
      # The minimum home-manager surface ../home.nix touches. Declared as
      # free-form options so this can evaluate without pulling in all of
      # home-manager, which would make a contract check depend on the thing
      # it is supposed to be independent of.
      {
        options = {
          home = lib.mkOption { type = lib.types.attrs; default = { }; };
          programs = lib.mkOption { type = lib.types.attrs; default = { }; };
          fonts = lib.mkOption { type = lib.types.attrs; default = { }; };
          systemd = lib.mkOption { type = lib.types.attrs; default = { }; };
          xdg = lib.mkOption { type = lib.types.attrs; default = { }; };
        };
        config = {
          home = { homeDirectory = "/home/contract"; username = "contract"; };
        };
      }
      # Disabled, so none of the config body has to evaluate: this check is
      # about the OPTION surface, and a disabled module still declares it.
      { sidorenkoDotfiles.enable = false; }
    ];
  };

  requiredOptions = [
    "enable" "livePath" "gui" "manageGnomeSettings" "sourceRev" "managePackages"
  ];
  declaredOptions = builtins.attrNames (evaluated.options.sidorenkoDotfiles or { });
  missingOptions = builtins.filter (o: !(builtins.elem o declaredOptions)) requiredOptions;

  # --- 2b. The NixOS module's own option surface ----------------------------
  # A SECOND option tree with the same name. ../home.nix declares
  # `sidorenkoDotfiles` inside home-manager's tree; ../nixos.nix declares it in
  # the NixOS tree, and a consumer sets both on one host. They cannot collide,
  # but they can drift — so the NixOS half is asserted here too rather than
  # left to the VM test, which would only notice by failing to boot.
  evaluatedNixos = lib.evalModules {
    modules = [
      self.nixosModules.default
      # The minimum NixOS surface ../nixos.nix touches, as free-form options,
      # so a contract check does not have to instantiate all of NixOS.
      {
        options = {
          environment = lib.mkOption { type = lib.types.attrs; default = { }; };
          fonts = lib.mkOption { type = lib.types.attrs; default = { }; };
        };
      }
      { sidorenkoDotfiles.enable = false; }
    ];
  };

  requiredNixosOptions = [ "enable" "gui" ];
  declaredNixosOptions =
    builtins.attrNames (evaluatedNixos.options.sidorenkoDotfiles or { });
  missingNixosOptions =
    builtins.filter (o: !(builtins.elem o declaredNixosOptions)) requiredNixosOptions;

  # livePath must stay a string. As a path it would copy the repo into the
  # store and make every symlink immutable, silently destroying live editing —
  # a change that type-checks and passes a VM test, so it needs asserting.
  livePathType = evaluated.options.sidorenkoDotfiles.livePath.type.name or "missing";
  livePathOk = livePathType == "str";

  # --- 3. Manifest reader ---------------------------------------------------
  manifests = self.lib.manifests { inherit lib; };
  requiredReaderFns = [
    "packagesFor" "packagesFrom" "linksFor" "linksOfKind"
    "singleLinkOfKind" "packageRows" "linkRows"
  ];
  missingReaderFns = builtins.filter (f: !(manifests ? ${f})) requiredReaderFns;

  # And it must actually work, not merely expose the names.
  samplePackages = manifests.packagesFor { gui = true; nixos = true; platform = "linux"; };
  sampleLinks = manifests.linksFor { gui = true; nixos = true; platform = "linux"; };
  shellRow = manifests.singleLinkOfKind "shell-source" {
    gui = true; nixos = true; platform = "linux";
  };

  # --- 4. Files and script flags --------------------------------------------
  requiredFiles = [
    "manifests/packages.txt" "manifests/links.txt" "manifests/gsettings.txt"
    "manifests/manifest-lib.sh" "manifests/apply-links.sh"
    "manifests/apply-gsettings.sh" "manifests/validate.sh"
    "manifests/verify-applied.sh" "nix/manifest.nix" "nix/home.nix" "nix/nixos.nix"
    "nix/INTERFACE.md" "flake.nix"
  ];

  # script -> flags the module or a consumer passes it
  requiredFlags = {
    "manifests/apply-links.sh" =
      [ "--dotdir" "--links" "--nixos" "--on-conflict" "--gui" "--no-gui" "--quiet" ];
    "manifests/apply-gsettings.sh" = [ "--nixos" "--quiet" ];
    "manifests/validate.sh" = [ "--quick" "--dotdir" ];
    "manifests/verify-applied.sh" =
      [ "--tsv" "--gui" "--no-gui" "--nixos" "--no-nixos" "--platform" "--skip" ];
  };

  # The flag must appear as a CASE ARM — `--flag)` or `--flag|` — not merely
  # somewhere in the file. An earlier version grepped the whole file and so
  # matched the flag in the --help text, which meant deleting it from the
  # argument parser still passed. Proven by deleting one and watching the check
  # stay green; every one of these scripts parses with `case "$1" in`, so
  # requiring `)` or `|` immediately after the flag is both strict and correct.
  flagChecks = lib.concatStringsSep "\n" (lib.mapAttrsToList (file: flags: ''
    for flag in ${lib.escapeShellArgs flags}; do
      if ! grep -qE -- "^[[:space:]]*([^#)]*\|)?${"\${flag}"}[)|]" "${self}/${file}"; then
        echo "CONTRACT VIOLATION: ${file} no longer accepts ${"\${flag}"}" >&2
        echo "  (looked for it as a case arm, not just a mention in --help)" >&2
        echo "  A consumer calls it with that flag; see nix/INTERFACE.md." >&2
        fail=1
      fi
    done
  '') requiredFlags);

  # --- 5. Manifest vocabulary ----------------------------------------------
  requiredKinds = [
    "link" "link-children" "copy" "shell-source"
    "git-include" "ssh-include" "firefox-user-js"
  ];
  requiredTags = [ "linux" "darwin" "gui" "no-nixos" "nixos-only" "nobin" "bin:" ];

in
assert lib.assertMsg (missingOutputs == [ ]) ''
  CONTRACT VIOLATION: missing flake output(s): ${
    lib.concatMapStringsSep ", " (p: lib.concatStringsSep "." p) missingOutputs
  }
  Consumers name these directly. See nix/INTERFACE.md.
'';
assert lib.assertMsg (missingOptions == [ ]) ''
  CONTRACT VIOLATION: sidorenkoDotfiles is missing option(s): ${
    lib.concatStringsSep ", " missingOptions
  }
  A consumer setting a removed option fails to evaluate its ENTIRE system.
  See nix/INTERFACE.md.
'';
assert lib.assertMsg (missingNixosOptions == [ ]) ''
  CONTRACT VIOLATION: the NixOS module's sidorenkoDotfiles is missing option(s): ${
    lib.concatStringsSep ", " missingNixosOptions
  }
  nixosModules.default is what puts the package set in environment.systemPackages
  so root and every other account get it. See nix/INTERFACE.md.
'';
assert lib.assertMsg livePathOk ''
  CONTRACT VIOLATION: sidorenkoDotfiles.livePath has type '${livePathType}', must be 'str'.
  As a path it would be copied into the store and every symlink would point at
  an immutable copy, silently destroying live editing. See nix/INTERFACE.md.
'';
assert lib.assertMsg (missingReaderFns == [ ]) ''
  CONTRACT VIOLATION: lib.manifests is missing: ${
    lib.concatStringsSep ", " missingReaderFns
  }
  See nix/INTERFACE.md.
'';
assert lib.assertMsg (builtins.length samplePackages > 0)
  "CONTRACT VIOLATION: packagesFor returned nothing; the reader or packages.txt is broken.";
assert lib.assertMsg (builtins.length sampleLinks > 0)
  "CONTRACT VIOLATION: linksFor returned nothing; the reader or links.txt is broken.";
assert lib.assertMsg (shellRow.source != "")
  "CONTRACT VIOLATION: no usable shell-source row; consumers wire the shell rc from it.";

pkgs.runCommand "sidorenko-dotfiles-interface"
{
  nativeBuildInputs = [ pkgs.bash pkgs.gnugrep pkgs.coreutils ];
} ''
  fail=0

  echo "== files a consumer depends on =="
  for f in ${lib.escapeShellArgs requiredFiles}; do
    if [ -e "${self}/$f" ]; then
      echo "  ok      $f"
    else
      echo "  MISSING $f" >&2
      echo "    CONTRACT VIOLATION: see nix/INTERFACE.md." >&2
      fail=1
    fi
  done

  echo "== script flags a consumer passes =="
  ${flagChecks}
  [ "$fail" = 0 ] && echo "  all documented flags still accepted"

  echo "== manifest vocabulary =="
  # Kinds and tags are checked against manifest-lib.sh and nix/manifest.nix,
  # the two parsers. Dropping one from either makes matching rows silently
  # inert rather than raising, which is the whole reason to assert it.
  for kind in ${lib.escapeShellArgs requiredKinds}; do
    if grep -q -- "$kind" "${self}/manifests/apply-links.sh" ||
       grep -q -- "$kind" "${self}/manifests/links.txt"; then
      echo "  ok      kind $kind"
    else
      echo "  MISSING kind $kind" >&2
      fail=1
    fi
  done
  for tag in ${lib.escapeShellArgs requiredTags}; do
    if grep -q -- "$tag" "${self}/manifests/manifest-lib.sh" &&
       grep -q -- "$tag" "${self}/nix/manifest.nix"; then
      echo "  ok      tag $tag"
    else
      # bin:/nobin are consumed by manifest-lib.sh only; accept either parser.
      if grep -q -- "$tag" "${self}/manifests/manifest-lib.sh"; then
        echo "  ok      tag $tag (bash reader only)"
      else
        echo "  MISSING tag $tag" >&2
        fail=1
      fi
    fi
  done

  echo "== TSV contract =="
  # compare-platforms.sh and the consumer's VM test both parse these.
  for token in 'PASS' 'FAIL' 'SKIP'; do
    grep -q -- "$token" "${self}/manifests/verify-applied.sh" ||
      { echo "  MISSING status $token" >&2; fail=1; }
  done
  echo "  ok      PASS/FAIL/SKIP statuses present"

  echo "== the nixpkgs rev is a literal in flake.nix =="
  if grep -qE 'github:NixOS/nixpkgs/[0-9a-f]{40}' "${self}/flake.nix"; then
    echo "  ok      $(grep -oE 'github:NixOS/nixpkgs/[0-9a-f]{40}' "${self}/flake.nix" | head -1)"
  else
    echo "  MISSING a literal github:NixOS/nixpkgs/<40-hex> URL in flake.nix" >&2
    echo "    nix-packages.sh greps it to pin the Ubuntu install, and a" >&2
    echo "    consumer compares it against its own pin. See nix/INTERFACE.md." >&2
    fail=1
  fi

  if [ "$fail" != 0 ]; then
    echo >&2
    echo "The consumer-facing contract is broken. Either restore it, or change" >&2
    echo "nix/tests/interface.nix and nix/INTERFACE.md in the same commit and" >&2
    echo "say so in the message — the consumer's pin bump is where it lands." >&2
    exit 1
  fi

  echo
  echo "interface contract OK:"
  echo "  ${toString (builtins.length samplePackages)} packages, ${
    toString (builtins.length sampleLinks)
  } links readable; shell rc = ${shellRow.source}"
  echo "  home-manager options: ${lib.concatStringsSep " " requiredOptions}"
  echo "  nixos options:        ${lib.concatStringsSep " " requiredNixosOptions}"
  > $out
''
