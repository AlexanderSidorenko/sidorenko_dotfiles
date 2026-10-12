# home-manager module: install these dotfiles on a NixOS machine.
#
# This is the Nix-side face of the repo, and it is DELIBERATELY the only thing
# a Nix consumer needs to know about. It reads ../manifests/, so a consumer
# never learns this repo's internal layout — the dependency points one way and
# stays shallow:
#
#     it_infra  ---(pinned flake input)--->  sidorenko_dotfiles
#
# never the reverse. An earlier arrangement had the manifests living in the
# it_infra repo and install.sh reaching INTO it, which made this repo
# non-standalone: a fresh Ubuntu box needed two clones before install.sh could
# place a single file. Standalone use is a hard requirement, so the facts live
# here and Nix consumers import them.
#
# Nothing here is specific to one machine or one user. Everything that varies
# is an option below.
#
# PINNED FOR PACKAGES, LIVE FOR LINKS. The two manifests are read at two
# different moments, on purpose:
#
#   home.packages   at EVALUATION, from the pinned flake input. A rebuild is
#                   then reproducible and cannot be changed by an uncommitted
#                   edit in somebody's working tree.
#   the link table  at ACTIVATION, from the LIVE working tree named by
#                   `livePath`. So the symlinks point at files you can edit and
#                   see take effect immediately, exactly as on Ubuntu.
#
# Those two can disagree when the working tree has moved past the pinned rev.
# That is not hidden: the activation script compares them and says so.
{ config, lib, pkgs, ... }:

let
  cfg = config.sidorenkoDotfiles;

  manifest = import ./manifest.nix { inherit lib; };

  ctx = {
    gui = cfg.gui;
    nixos = true;
    platform = "linux";
  };

  # The manifests and their appliers as a store directory, preserving layout:
  # the scripts locate manifest-lib.sh and the .txt files relative to their own
  # path, so they must stay siblings.
  tools = ../manifests;

  # Package list, resolved at evaluation time against the consumer's nixpkgs.
  # Throws naming the offending attribute rather than failing deep inside a
  # module; ../manifests/validate.sh catches it earlier still.
  dotfilePackages = manifest.packagesFrom pkgs ctx;

  # Which file is the shell rc, and which rcs source it, both read from
  # links.txt so "shrc is the shell rc" is stated in exactly one place.
  shellRow = manifest.singleLinkOfKind "shell-source" ctx;

  shellInit = ''
    # >>> sidorenko_dotfiles >>>
    # Managed by the sidorenko_dotfiles home-manager module
    # (links.txt: shell-source). Do not edit by hand.
    export SIDORENKO_DOTFILES="${cfg.livePath}"
    if [ -r "$SIDORENKO_DOTFILES/${shellRow.source}" ]; then
      . "$SIDORENKO_DOTFILES/${shellRow.source}"
    fi
    # <<< sidorenko_dotfiles <<<
  '';

  gitIncludes =
    map (r: { path = "${cfg.livePath}/${r.source}"; })
      (manifest.linksOfKind "git-include" ctx);

  # Tools the appliers shell out to. Activation runs with a deliberately small
  # PATH, so anything not named here is simply absent.
  scriptPath = lib.makeBinPath (with pkgs; [
    bash coreutils gnugrep gnused gawk diffutils findutils glib git
  ]);

in
{
  options.sidorenkoDotfiles = {
    enable = lib.mkEnableOption "the sidorenko_dotfiles configuration" // {
      default = true;
    };

    livePath = lib.mkOption {
      type = lib.types.str;
      default = "${config.home.homeDirectory}/.sidorenko_dotfiles";
      description = ''
        Where the dotfiles working tree lives on the target machine, as a
        STRING rather than a Nix path. A path would copy the whole repo into
        the store and make every symlink point at an immutable copy — the
        opposite of the live-edit behaviour this module is built around.
      '';
    };

    gui = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this machine has a graphical session. Gates the `gui`-tagged
        rows of packages.txt and links.txt, so a headless host does not pull in
        wl-clipboard or try to place Firefox prefs.
      '';
    };

    manageGnomeSettings = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Install the user unit that applies gsettings.txt at graphical-session
        start. Turn off on a host where something else owns GNOME preferences.
      '';
    };

    sourceRev = lib.mkOption {
      type = lib.types.str;
      default = "unknown";
      description = ''
        The revision of this repo that the consumer pinned. Used only to warn
        at activation when the live working tree has moved past it, since the
        package list comes from the pin while the links come from the tree.
        Consumers should pass `self.rev or "dirty"`.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = dotfilePackages
      ++ lib.optionals cfg.gui [
        # The Nerd Font, natively. The Ubuntu path copies the .otf out of the
        # repo into ~/.local/share/fonts (links.txt `copy` row, tagged
        # no-nixos); here the packaged font is strictly better — fontconfig
        # finds it in the profile with no cache step to get wrong.
        pkgs.nerd-fonts.droid-sans-mono
      ];

    fonts.fontconfig.enable = cfg.gui;

    # shrc reads this to locate its own repo; exported so non-interactive
    # shells, which never source .bashrc, still find it.
    home.sessionVariables.SIDORENKO_DOTFILES = cfg.livePath;

    # --- Shells -------------------------------------------------------------
    # home-manager owns ~/.bashrc and ~/.zshrc here, which is exactly why
    # apply-links.sh does NOT handle the shell-source row: those files are
    # read-only symlinks into the store and cannot be appended to.
    #
    # shrc does its own zsh-plugin loading, so the home-manager plugin options
    # are left OFF — enabling them would load each plugin twice.
    #
    # This comment used to add "home.packages populates ~/.nix-profile just as
    # nix-env does on Ubuntu, so that keeps working untouched". That was FALSE,
    # and it cost both plugins. `useUserPackages = true` installs into
    # /etc/profiles/per-user/$USER and does NOT populate ~/.nix-profile, which
    # on this host still points at the empty nix-env profile. shrc looked only
    # under ~/.nix-profile/share, found nothing, and zsh-autosuggestions and
    # zsh-syntax-highlighting were installed and loaded by nobody.
    #
    # Nothing caught it: both are tagged `nobin` in packages.txt precisely
    # because they put no command on PATH, so the package check skips them, and
    # a plugin that fails to load is invisible to a shell that still starts.
    # shrc now searches every layout we use, and verify-applied.sh asserts the
    # plugins are actually resident rather than merely installed.
    programs.bash = {
      enable = true;
      initExtra = shellInit;
    };

    programs.zsh = {
      enable = true;
      autosuggestion.enable = false;
      syntaxHighlighting.enable = false;
      initContent = shellInit;
    };

    # --- Git ----------------------------------------------------------------
    # Only the includes are declared. The identity, aliases and everything else
    # stay in the repo's own gitconfig, so this is a pointer rather than a
    # second copy of the configuration.
    programs.git = {
      enable = true;
      includes = gitIncludes;
    };

    # --- SSH ----------------------------------------------------------------
    # programs.ssh is deliberately NOT enabled. It would make home-manager own
    # ~/.ssh/config, replacing whatever per-host blocks and IdentityFile lines
    # the machine already has — on the host this was written for, that file
    # names the deploy key its own git remote uses, so owning it would break
    # `git fetch` on the machine doing the rebuild. apply-links.sh appends an
    # Include instead, and keeps it last so per-host blocks still win.

    # --- Apply the manifests ------------------------------------------------
    home.activation.sidorenkoDotfileLinks =
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        export PATH="${scriptPath}:$PATH"
        export SIDORENKO_DOTFILES="${cfg.livePath}"

        if [ ! -d "${cfg.livePath}" ]; then
          echo "[sidorenko_dotfiles] ${cfg.livePath} is not present — skipping links."
          echo "[sidorenko_dotfiles] Clone it with:"
          echo "[sidorenko_dotfiles]   git clone https://github.com/AlexanderSidorenko/sidorenko_dotfiles ${cfg.livePath}"
        else
          # Links come from the LIVE tree, packages from the PIN. Say so when
          # the two have diverged, because the symptom otherwise is a link
          # whose source is missing, or a tool that is on PATH but unconfigured.
          live_rev="$(git -C "${cfg.livePath}" rev-parse HEAD 2>/dev/null || echo unknown)"
          if [ "${cfg.sourceRev}" != unknown ] && [ "$live_rev" != unknown ] &&
             [ "$live_rev" != "${cfg.sourceRev}" ]; then
            echo "[sidorenko_dotfiles] NOTE: the pinned rev and the working tree differ."
            echo "[sidorenko_dotfiles]   packages came from ${cfg.sourceRev}"
            echo "[sidorenko_dotfiles]   links come from     $live_rev (live)"
            echo "[sidorenko_dotfiles]   Bump the flake input to match once the tree is pushed."
          fi

          # The appliers come from the PINNED store copy, not the live tree:
          # an activation must run code that was reviewed as part of the system
          # closure, not whatever happens to be checked out right now. Only the
          # link TABLE is read live, via --links.
          #
          # on-conflict=skip: an activation must never silently replace a real
          # file in $HOME. Exit 3 means "applied, but something was skipped" —
          # a warning. Anything else is reported loudly but still does not
          # abort activation: a dotfile problem must not make the system
          # un-rebuildable.
          rc=0
          ${pkgs.bash}/bin/bash ${tools}/apply-links.sh \
            --dotdir "${cfg.livePath}" \
            --links "${cfg.livePath}/manifests/links.txt" \
            --nixos --on-conflict skip --quiet \
            ${if cfg.gui then "--gui" else "--no-gui"} || rc=$?
          case "$rc" in
            0) : ;;
            3) echo "[sidorenko_dotfiles] some links were skipped (see above)." ;;
            *) echo "[sidorenko_dotfiles] WARNING: apply-links.sh failed (exit $rc)." ;;
          esac
        fi
      '';

    # GSettings needs a live session bus, which does not exist during
    # activation (a rebuild can happen over SSH with no graphical session at
    # all). So this runs as a user unit tied to the graphical session, where
    # the bus is guaranteed. Idempotent, so running it at every login is cheap
    # and self-healing if something changes a key by hand.
    systemd.user.services.sidorenko-gsettings = lib.mkIf (cfg.gui && cfg.manageGnomeSettings) {
      Unit = {
        Description = "Apply sidorenko_dotfiles GSettings preferences";
        After = [ "graphical-session.target" ];
        PartOf = [ "graphical-session.target" ];
      };
      Service = {
        Type = "oneshot";
        ExecStart = "${pkgs.bash}/bin/bash ${tools}/apply-gsettings.sh --nixos --quiet";
        Environment = [ "PATH=${scriptPath}" ];
      };
      Install.WantedBy = [ "graphical-session.target" ];
    };
  };
}
