{
  description = "Alexander Sidorenko's dotfiles — shell, editors, terminal, and the manifests that place them";

  # WHY THIS FILE EXISTS, and what it deliberately does NOT change.
  #
  # This repo's primary install path is ./install.sh on Ubuntu and macOS, run
  # by hand, and that stays true: nothing below is required for it, and a
  # machine with no Nix at all still works exactly as before. This flake is
  # ADDITIVE — it exists so that a NixOS host can consume the dotfiles
  # declaratively without reaching into this repo's internals.
  #
  # THE DEPENDENCY POINTS ONE WAY. A consumer (it_infra's desktop host) takes
  # this repo as a pinned input and imports `homeModules.default`:
  #
  #     it_infra  ---(pinned flake input)--->  sidorenko_dotfiles
  #
  # and never the reverse. An earlier arrangement had the manifests living in
  # it_infra with install.sh reaching INTO that repo, which made THIS repo
  # non-standalone — a fresh Ubuntu box needed two clones before install.sh
  # could place a single file. Standalone use is a hard requirement, so the
  # facts live here and Nix consumers import them.
  #
  # WHAT A CONSUMER GETS:
  #
  #   homeModules.default   a home-manager module: packages from
  #                         manifests/packages.txt, links from
  #                         manifests/links.txt, GNOME keys from
  #                         manifests/gsettings.txt. Options in nix/home.nix.
  #   lib.manifests         the manifest reader itself, for anything that wants
  #                         the lists without the module (needs a `lib`).
  #   packages.gitpane      the one tool not in nixpkgs, which install.sh also
  #                         builds via NIX_LOCAL_DERIVATIONS.
  #   checks.manifests      `nix flake check` validates the manifests.

  inputs = {
    # Pinned to an exact rev rather than a moving branch, matching the policy
    # the consuming repo sets for all of its inputs. This pin only affects the
    # dev shell and the checks below — a CONSUMER's module evaluation uses the
    # consumer's own nixpkgs, which is what keeps one nixpkgs in their closure
    # instead of two glibcs.
    nixpkgs.url = "github:NixOS/nixpkgs/f4f698677b11021a8f84f452e23ae9ef2427bec3";
  };

  outputs = { self, nixpkgs, ... }:
    let
      systems = [ "x86_64-linux" "aarch64-linux" "aarch64-darwin" "x86_64-darwin" ];
      forAllSystems = f:
        nixpkgs.lib.genAttrs systems (system: f nixpkgs.legacyPackages.${system});
    in
    {
      # The home-manager module. Consumers import this and set, at most, the
      # options in nix/home.nix — livePath, gui, manageGnomeSettings, sourceRev.
      #
      # Only `homeModules` is exported, not the older `homeManagerModules`
      # spelling: nix does not recognise the latter as a flake output and warns
      # about it on every evaluation, and a warning nobody can act on is worse
      # than an alias nobody asked for. `import "${input}/nix/home.nix"` works
      # for any consumer that wants the module by path instead.
      homeModules.default = import ./nix/home.nix;

      # The manifest reader, independent of home-manager. Takes { lib; }.
      lib.manifests = { lib }: import ./nix/manifest.nix { inherit lib; };

      # Built once and aliased, rather than `default` reaching back through
      # `self.packages.<system>` — that self-reference needed `pkgs.system`,
      # which nixpkgs now warns is renamed to stdenv.hostPlatform.system.
      packages = forAllSystems (pkgs:
        let gitpane = import ./gitpane.nix { inherit pkgs; };
        in {
          inherit gitpane;
          default = gitpane;
        });

      # `nix flake check` validates the manifests: every package name resolves
      # against the pinned nixpkgs, every links.txt source exists, and the bash
      # and Nix readers agree on the same files. That last one is the important
      # one — the format is necessarily implemented twice (manifest-lib.sh for
      # bash, nix/manifest.nix for Nix) and this is what stops the two
      # implementations from becoming two sources of truth.
      checks = forAllSystems (pkgs: {
        manifests = pkgs.runCommand "sidorenko-dotfiles-manifests"
          {
            nativeBuildInputs = with pkgs; [
              bash coreutils gnugrep gnused gawk diffutils findutils nix
            ];
          } ''
          cp -r ${./manifests} ./manifests
          cp -r ${./nix} ./nix
          chmod -R +w ./manifests ./nix

          # --quick skips the nixpkgs name resolution, which would need network
          # and a nixpkgs inside the sandbox. The names are checked instead by
          # the Nix reader below: packagesFrom throws on any attribute that
          # does not exist, so evaluating it IS the existence check.
          bash ./manifests/validate.sh --quick --dotdir "${./.}" | tee $out

          echo "resolving every package name against nixpkgs..." >>$out
          echo "${
            toString (map (p: p.name or "?")
              ((import ./nix/manifest.nix { inherit (pkgs) lib; }).packagesFrom pkgs {
                gui = true;
                nixos = true;
                platform = "linux";
              }))
          }" >>$out
          echo "OK: all names resolved" >>$out
        '';
      });

      devShells = forAllSystems (pkgs: {
        default = pkgs.mkShell {
          name = "sidorenko-dotfiles";
          # The tools AGENTS.md's "Validating changes" section tells you to run.
          packages = with pkgs; [ shellcheck shfmt bash zsh nixfmt ];
          shellHook = ''
            echo "sidorenko_dotfiles dev shell"
            echo "  ./manifests/validate.sh      check the manifests"
            echo "  shellcheck -x install.sh     lint (AGENTS.md)"
            echo "  nix flake check              validate manifests via Nix"
          '';
        };
      });

      formatter = forAllSystems (pkgs: pkgs.nixfmt);
    };
}
