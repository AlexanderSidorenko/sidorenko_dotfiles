# NixOS module: install this repo's package set for EVERY user on the machine.
#
# The companion to ./home.nix, and the smaller half of the pair by a long way.
# ./home.nix owns everything that lives in a $HOME — the symlinks, the shell
# rc wiring, the git includes, the gsettings unit — and it installs the
# package set into ONE user's profile. This module installs that same list into
# `environment.systemPackages` instead, which is the only way NixOS makes a
# program available to root and to every other account.
#
# WHY THAT MATTERS, concretely. With `home-manager.useUserPackages = true` the
# package set lands in /etc/profiles/per-user/$USER, so `sudo -i`, a systemd
# unit, a rescue shell and any second account all get a machine without jq,
# without rg, without nvim — on a box whose owner installed all three. The
# tools are not a personal preference at that point, they are the toolchain the
# machine is administered with, and root is exactly who needs them when
# something is wrong.
#
# THE SAME LIST, READ THE SAME WAY. Nothing here restates packages.txt or
# re-implements its tag logic: it calls the same reader ./home.nix does, with
# `nixos = true`, so the `no-nixos` rows (coreutils, nix — where a second copy
# would shadow what NixOS itself provides) stay excluded and a row added to the
# manifest reaches both paths at once.
#
# PAIR IT WITH `managePackages = false`. Importing this module does not stop
# ./home.nix installing the same closure into the user profile as well; the
# derivations are identical, so nothing breaks, but the user profile then
# SHADOWS the system one on PATH and a future divergence between the two would
# be invisible. ./home.nix has `managePackages` for exactly this, and
# ../nix/INTERFACE.md documents the pairing.
#
# WHAT IS DELIBERATELY NOT HERE: the dotfiles themselves. Root does not get
# ~/.zshrc, ~/.gitconfig or ~/.tmux.conf, and that is a decision rather than an
# omission. `livePath` is a working tree owned by an unprivileged user, so
# wiring root's shell to source a file out of it would let that user run
# arbitrary code as root at the next root login — a local privilege escalation
# in exchange for a nicer prompt. Programs are shared; a user's configuration
# is not.
#
# The same reasoning excludes ../bin (clip, mem, ram-health, the pr-* helpers).
# They reach a PATH only because shrc prepends the working tree, and a
# user-writable directory on root's PATH is the same escalation by a shorter
# route. Anything in there that root genuinely needs should become a package or
# a systemd unit in the consuming repo, where the store makes it immutable.
{ config, lib, pkgs, ... }:

let
  cfg = config.sidorenkoDotfiles;

  manifest = import ./manifest.nix { inherit lib; };

  ctx = {
    gui = cfg.gui;
    nixos = true;
    platform = "linux";
  };

in
{
  # These names sit in the NIXOS option tree. ./home.nix declares
  # `sidorenkoDotfiles` too, in home-manager's tree, and the two never meet —
  # a consumer sets this one at top level and that one under
  # `home-manager.users.<name>`. Setting either in the wrong place is an
  # unknown-option error rather than a silent no-op, which is the behaviour to
  # want here.
  options.sidorenkoDotfiles = {
    enable = lib.mkEnableOption "the sidorenko_dotfiles system package set" // {
      default = true;
    };

    gui = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Whether this machine has a graphical session. Gates the `gui`-tagged
        rows of packages.txt, and the Nerd Font below. Keep it equal to the
        `gui` passed to the home-manager module on the same host: one machine,
        one answer.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = manifest.packagesFrom pkgs ctx;

    # The Nerd Font system-wide rather than in a profile. ./home.nix puts it in
    # home.packages, which is enough for one user's fontconfig; `fonts.packages`
    # is what makes it visible to a login manager and to every account, which is
    # the same argument as the package list above.
    fonts.packages = lib.optionals cfg.gui [ pkgs.nerd-fonts.droid-sans-mono ];
  };
}
