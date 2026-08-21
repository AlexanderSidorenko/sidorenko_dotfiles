# gitpane — multi-repo git workspace dashboard for the terminal.
# https://github.com/affromero/gitpane
#
# WHY THIS FILE EXISTS
#
# gitpane is not in nixpkgs, so it cannot join NIX_PACKAGES with everything
# else. Building it from a derivation here keeps the install path identical to
# every other tool -- nix-env, a pinned version, one profile to roll back --
# instead of introducing a second package manager (cargo install) or a
# hand-managed binary in ~/.local/bin that nothing tracks.
#
# BUMPING THE VERSION
#
# Change `version`, then recompute the one hash:
#
#   nix-prefetch-url --unpack \
#     https://github.com/affromero/gitpane/archive/refs/tags/v<VERSION>.tar.gz
#   nix-hash --to-sri --type sha256 <the base32 hash printed above>
#
# and paste the sha256-... line into `hash`. There is deliberately no second
# hash to chase; see the cargoLock note below. Releases are frequent (0.10.3 ->
# 0.13.0 in two weeks), so expect this to need doing.
#
#   nix-env -f gitpane.nix -i gitpane      # what nix_install_local runs
{ pkgs ? import <nixpkgs> { } }:

let
  version = "0.13.0";

  src = pkgs.fetchFromGitHub {
    owner = "affromero";
    repo = "gitpane";
    rev = "v${version}";
    hash = "sha256-2PV4g/61ZLOEt5bdJvbiwDjS4RvfiB94w7kGWEFiijA=";
  };
in
pkgs.rustPlatform.buildRustPackage {
  pname = "gitpane";
  inherit version src;

  # Read upstream's own Cargo.lock out of the fetched source rather than
  # pinning a cargoHash. Two reasons, and the second one is not optional here:
  #
  #   - There is then exactly ONE hash to update per release, and no 4000-line
  #     copy of someone else's lock file vendored into this repo.
  #   - The cargoHash route goes through this channel's fetchCargoVendor, which
  #     asks crates.io/api/v1/crates/<crate>/<version>/download with a
  #     python-requests User-Agent. crates.io now answers that with 403 under
  #     its data-access policy, so the vendor step dies before a single crate is
  #     fetched. importCargoLock asks for the same URLs through nix's own curl,
  #     whose User-Agent is accepted. nixpkgs master has since fixed the vendor
  #     tool (it sends a real User-Agent and uses static.crates.io); when the
  #     channel catches up, either route will work and this one still will.
  #
  # The cost is import-from-derivation: `src` is realised during evaluation, so
  # `nix-env -f` fetches the tarball before it can build anything.
  cargoLock.lockFile = "${src}/Cargo.lock";

  nativeBuildInputs = with pkgs; [ pkg-config cmake perl ];
  buildInputs = with pkgs; [ openssl ];

  # gitpane depends on git2 with the `vendored-openssl` feature, which would
  # compile a private OpenSSL from source inside this build. OPENSSL_NO_VENDOR
  # makes openssl-sys ignore that feature and link the pkg-config'd system
  # OpenSSL instead -- much faster, and one fewer copy of OpenSSL to patch.
  env.OPENSSL_NO_VENDOR = "1";

  # Upstream's test suite shells out to git and touches the network; the point
  # of this derivation is the binary.
  doCheck = false;

  meta = with pkgs.lib; {
    description = "Multi-repo Git workspace dashboard TUI";
    homepage = "https://github.com/affromero/gitpane";
    license = licenses.mit;
    mainProgram = "gitpane";
    platforms = platforms.unix;
  };
}
