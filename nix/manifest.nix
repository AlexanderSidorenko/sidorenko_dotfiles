# Nix-side reader for ../manifests/packages.txt and links.txt.
#
# This is the ONE unavoidable second implementation of the manifest format:
# Nix cannot source ../manifests/manifest-lib.sh, and the package list has to
# be known at EVALUATION time to become home.packages.
# ../manifests/validate.sh therefore runs both readers over the same file and
# fails if they disagree, which is what keeps "two parsers" from becoming "two
# sources of truth".
#
# Importable two ways, and both matter:
#   * through ../flake.nix as `lib.manifests`, by a consumer like it_infra
#   * directly as `import ./manifest.nix { inherit lib; }`, which is what
#     validate.sh does, so the cross-reader check needs no flake machinery
#
# Parsing differs from the bash version in one immaterial way: this treats the
# first '#' on a line as the start of a comment, where the bash version
# requires the '#' to be preceded by whitespace. No field in either manifest
# contains a literal '#', so the two agree on the actual data — and
# ./validate.sh proves it rather than taking this comment's word for it.
{ lib }:

let
  # --- tiny text helpers ---------------------------------------------------

  # Everything before the first '#'.
  stripComment = line:
    let m = builtins.match "^([^#]*).*$" line;
    in if m == null then "" else builtins.elemAt m 0;

  # Trim surrounding whitespace. Hand-rolled rather than lib.trim so this
  # keeps working on older nixpkgs; POSIX ERE has no lazy quantifier, so the
  # trailing trim leans on "greedy, but must end in a non-space".
  trim = s:
    let
      noLead = let m = builtins.match "^[[:space:]]*(.*)$" s;
               in if m == null then s else builtins.elemAt m 0;
      noTrail = let m = builtins.match "^(.*[^[:space:]])[[:space:]]*$" noLead;
                in if m == null then "" else builtins.elemAt m 0;
    in noTrail;

  # Split on runs of whitespace, dropping the regex machinery's own artefacts.
  fields = s:
    builtins.filter (x: builtins.isString x && x != "")
      (builtins.split "[[:space:]]+" s);

  # Non-empty, non-comment lines of a file, already trimmed.
  contentLines = path:
    builtins.filter (l: l != "")
      (map (l: trim (stripComment l))
        (lib.splitString "\n" (builtins.readFile path)));

  parseTags = s: if s == "" then [ ] else lib.splitString "," s;

  # --- packages.txt --------------------------------------------------------

  packageRows = map
    (line:
      let f = fields line;
      in {
        name = builtins.elemAt f 0;
        tags = if builtins.length f > 1 then parseTags (builtins.elemAt f 1) else [ ];
      })
    (contentLines ../manifests/packages.txt);

  # --- links.txt -----------------------------------------------------------

  linkRows = map
    (line:
      let f = fields line;
      in
      assert lib.assertMsg (builtins.length f >= 3)
        "links.txt row needs at least 'kind source target': ${line}";
      {
        kind = builtins.elemAt f 0;
        source = builtins.elemAt f 1;
        target = builtins.elemAt f 2;
        tags = if builtins.length f > 3 then parseTags (builtins.elemAt f 3) else [ ];
      })
    (contentLines ../manifests/links.txt);

  # --- gating --------------------------------------------------------------

  # Same gate semantics as manifest-lib.sh: a platform/gui tag RESTRICTS a row
  # to that platform, no-nixos excludes it on NixOS, nixos-only requires it.
  keep = { gui, nixos, platform }: tags:
    let has = t: builtins.elem t tags;
    in
    (!(has "linux") || platform == "linux")
    && (!(has "darwin") || platform == "darwin")
    && (!(has "gui") || gui)
    && (!(has "no-nixos") || !nixos)
    && (!(has "nixos-only") || nixos);

in
rec {
  inherit packageRows linkRows;

  # Package NAMES for the given context.
  packagesFor = { gui ? true, nixos ? true, platform ? "linux" }:
    map (r: r.name)
      (builtins.filter (r: keep { inherit gui nixos platform; } r.tags) packageRows);

  # Resolve those names against a package set. Fails loudly and by name rather
  # than with a bare "attribute missing" from somewhere inside the module.
  packagesFrom = pkgs: args:
    map
      (n:
        if pkgs ? ${n} then pkgs.${n}
        else throw ''
          packages.txt names '${n}', which does not exist in this nixpkgs.
          Run desktop/nixos/dotfiles/validate.sh to check every name at once.
        '')
      (packagesFor args);

  linksFor = { gui ? true, nixos ? true, platform ? "linux" }:
    builtins.filter (r: keep { inherit gui nixos platform; } r.tags) linkRows;

  # Rows of one kind — how home.nix finds, say, the shell-source row without
  # restating that shrc is the shell rc.
  linksOfKind = kind: args:
    builtins.filter (r: r.kind == kind) (linksFor args);

  # Exactly one row of a kind, or an error. Used where the module needs a
  # single answer (which file is the shell rc?) and silence on a missing or
  # duplicated row would be worse than a failed evaluation.
  singleLinkOfKind = kind: args:
    let rows = linksOfKind kind args;
    in
    if builtins.length rows == 1 then builtins.head rows
    else throw "links.txt must have exactly one '${kind}' row, found ${
      toString (builtins.length rows)
    }";
}
