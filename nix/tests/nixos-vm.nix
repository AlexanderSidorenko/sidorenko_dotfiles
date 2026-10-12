# Boot a NixOS VM carrying this repo's home-manager module and measure the
# result with the SAME script ../../tests/ubuntu-vm.sh runs.
#
# WHY IT LIVES HERE AND NOT IN THE CONSUMING REPO. It tests ../home.nix — this
# repo's module — so it belongs to this repo. Keeping it in the consumer meant
# an edit here could break NixOS and `nix flake check` here would still pass:
# the breakage only surfaced in somebody else's repo, after a pin bump. Now
# both the Ubuntu path and the NixOS path are testable without leaving this
# checkout, which is the point — this repo must not be breakable by changes to
# this repo alone.
#
# The consumer still runs it: it_infra's flake re-exports this check, so it
# executes in both places, built against whichever nixpkgs the consumer pins
# (its `follows` reaches our nixpkgs input).
#
# WHY THIS SHAPE. The Ubuntu side has to boot a vanilla image and run a
# thousand lines of installer before anything can be measured. Here the
# configuration IS the installer, so the test is: build a VM from the module,
# boot it, and ask the same questions.
#
# What makes the pair worth having is that both run
# `manifests/verify-applied.sh` out of the dotfiles repo. The expectations are
# derived from the manifests on both sides, so neither platform can quietly
# grow its own idea of "configured" — and a row added to links.txt extends
# both tests at once, with no edit here.
#
# THE TWO HARNESSES READ DIFFERENT TREES, on purpose:
#
#   this test            the PINNED flake input — hermetic and reproducible,
#                        which is what a `nix flake check` entry has to be.
#                        A pure evaluation cannot read a working tree at all.
#   tests/ubuntu-vm.sh   the LIVE working tree, over a read-only 9p mount.
#
# So the Ubuntu harness is the one to iterate with: edit, re-run, repeat. This
# one only sees work that has been committed AND the input re-locked. That is a
# real cost and worth stating, because the symptom is confusing — the first run
# after adding verify-applied.sh failed with "no such file or directory",
# simply because the pinned rev predated the file. If this test cannot find
# something you just wrote, bump the pin:
#
#   nix flake lock --update-input sidorenko-dotfiles
#
# WHAT THIS DELIBERATELY DOES NOT DO: reuse any consumer's configuration.nix.
# A real host carries its own bootloader, disk layout and drivers, none of
# which a VM can honour and several of which will not even evaluate without the
# real hardware. The thing under test is THIS module, so the VM takes it plus
# the minimum to have a user and a graphical session.
#
# So "test as you fly" only partly holds: this proves the dotfiles layer, not
# any particular host. A consumer's own host-specific glue (which options it
# sets) is covered by its configuration evaluating at all, not by this.
#
# ARGUMENTS. `dotfiles` is the flake self-reference — the store copy of this
# repo that gets seeded into the guest. A consumer re-exporting this check
# passes its own `inputs.sidorenko-dotfiles`, which is the same tree.
#
# `systemScope` picks WHICH OF THE TWO SUPPORTED ARRANGEMENTS is under test,
# and both are exported as checks because both are real:
#
#   false  the module default. packages.txt goes into the user profile through
#          home.packages, so one account has the toolchain.
#   true   ../nixos.nix is imported as well and `managePackages = false`, so
#          packages.txt goes into environment.systemPackages and root plus
#          every other account have it too. This is what the desktop in
#          it_infra runs, so it is the "test as you fly" half.
#
# One file rather than two because only the wiring differs: the seeding, the
# session, and the measurement are identical, and a second copy of them would
# be a second thing to keep in step. In system scope the test additionally
# asserts the thing that arrangement exists for — that root and a second
# account with no dotfiles at all can still run every command.
{ pkgs, lib, dotfiles, homeManagerModule, systemScope ? false }:

let
  user = "tester";
  home = "/home/${user}";

  # A second account, only in system scope. It gets no dotfiles, no
  # home-manager generation and no shell wiring — which is the point: if it can
  # run the toolchain, the toolchain is genuinely on the machine rather than in
  # one profile.
  other = "bystander";

  # The dotfiles working tree must exist in the guest for the activation script
  # to link anything, and it must be WRITABLE and a git checkout — the module
  # reads `git rev-parse HEAD` for its staleness check. Copied from the store
  # at boot rather than symlinked, since the store is read-only.
  seedTree = pkgs.writeShellScript "seed-dotfiles-tree" ''
    set -eux
    export PATH=${lib.makeBinPath (with pkgs; [ coreutils git ])}:$PATH
    # git reads $HOME for its global config; in a system unit it is unset,
    # which makes git behave unpredictably rather than fail outright.
    export HOME=${home}
    export GIT_CONFIG_GLOBAL=/dev/null
    export GIT_CONFIG_SYSTEM=/dev/null

    mkdir -p ${home}
    rm -rf ${home}/.sidorenko_dotfiles
    cp -r ${dotfiles} ${home}/.sidorenko_dotfiles
    # The store copy is read-only, including its directories, so u+rwX (not
    # just u+w) is needed before anything can be written or traversed.
    chmod -R u+rwX ${home}/.sidorenko_dotfiles

    cd ${home}/.sidorenko_dotfiles
    # A throwaway repo so the module's rev check has something to read. Its rev
    # will differ from the pinned one, which is itself worth exercising: the
    # activation script must warn and carry on, not fail.
    #
    # ORDER MATTERS: all git work happens while the tree is still root-owned,
    # and the chown comes last. Doing it the other way round makes git run as
    # root inside a tester-owned repo, which it refuses outright with "detected
    # dubious ownership in repository" — the first run of this test failed
    # exactly there.
    git init -q -b master .
    git -c user.email=test@example.com -c user.name=Test add -A
    git -c user.email=test@example.com -c user.name=Test commit -qm seed

    chown -R ${user}:users ${home}/.sidorenko_dotfiles
  '';

  # Only in system scope: the assertions that distinguish it from the default
  # arrangement. A `let` binding interpolated on one properly-indented line
  # below, rather than a multi-line `${…}` inside testScript — that would put
  # a line at column zero inside the string, which is how Nix decides how much
  # indentation to strip, so every Python statement would arrive indented by
  # four. An IndentationError produced by a Nix detail, in a file that reads
  # fine.
  systemScopeTests = lib.optionalString systemScope ''
    # WHAT SYSTEM SCOPE EXISTS FOR. The run above proves the dotfiles user has
    # the toolchain, and it would pass just as happily with everything in that
    # one profile — which is the arrangement this scope replaces. So ask the
    # question that distinguishes them: can accounts that have NO dotfiles run
    # the same commands?
    #
    # root is the one that matters in practice (`sudo -i`, a unit, a rescue
    # shell), and ${other} is the control: a plain account that no part of this
    # repo has ever touched.
    with subtest("root and a plain account get the same package set as the user"):
        pkg_cmd = (
            "bash ${dotfiles}/manifests/verify-applied.sh "
            "--gui --nixos --platform linux --tsv "
            "--skip links,gsettings,shell,git,ssh"
        )

        # Only the `packages` category survives the --skip list, so these are
        # exactly "which commands resolve on this account's PATH".
        #
        # EVERY ACCOUNT GOES THROUGH `su -`, root included. Running it directly
        # with machine.execute() looks equivalent and is not: the test driver's
        # shell has no HOME, verify-applied.sh reads $HOME under `set -u`, and
        # so the script died on line 45 and emitted nothing at all. `su -`
        # gives each account the login environment a person would have.
        #
        # AND SILENCE IS CHECKED, because that failure was indistinguishable
        # from the one this subtest hunts: a verifier that never reached the
        # packages section reports zero commands, exactly like an account that
        # has none. The first run of this test duly accused root of missing all
        # 63 tools it could in fact run.
        def commands_for(who):
            rc, tsv = machine.execute("su - " + who + " -c " + shlex.quote(pkg_cmd))
            rows = [r.split("\t") for r in tsv.splitlines()
                    if r and not r.startswith("#")]
            assert rows, (
                f"verify-applied.sh produced no rows for {who} (rc={rc}), so it "
                f"did not run and this measured nothing:\n{tsv}"
            )
            ok = set(c[2] for c in rows if c[0] == "PASS" and c[1] == "packages")
            bad = set(c[2] for c in rows if c[0] == "FAIL" and c[1] == "packages")
            return ok, bad

        as_user, missing_user = commands_for("${user}")
        as_root, missing_root = commands_for("root")
        as_other, missing_other = commands_for("${other}")

        print(
            f"commands resolved: ${user}={len(as_user)} "
            f"root={len(as_root)} ${other}={len(as_other)}"
        )

        # A floor, so an empty manifest or a verifier that died early cannot
        # satisfy the equalities below by matching three empty sets.
        assert len(as_user) >= 40, (
            f"only {len(as_user)} commands resolved for ${user}; packages.txt "
            "cannot be that short, so this measured nothing"
        )
        assert not missing_user, (
            f"${user} cannot run: {sorted(missing_user)}. In this scope the "
            "user's own toolchain comes from the system profile too, so this "
            "is the same failure as root's."
        )
        assert not missing_root, (
            f"root cannot run: {sorted(missing_root)}. The package set did not "
            "reach environment.systemPackages."
        )
        assert not missing_other, (
            f"${other} cannot run: {sorted(missing_other)}"
        )
        # Stated as an equality rather than another threshold: nobody on this
        # machine is better equipped than anybody else.
        assert as_root == as_user, (
            "root and ${user} see different command sets; only root is missing "
            f"{sorted(as_user - as_root)}, only ${user} is missing "
            f"{sorted(as_root - as_user)}"
        )
        assert as_other == as_user, (
            f"${other} and ${user} see different command sets: "
            f"{sorted(as_user ^ as_other)}"
        )

    with subtest("the Nerd Font is system-wide, not inside one profile"):
        # fonts.packages, not home.packages. Asked of fontconfig the way the
        # accounts actually ask it, including the one with no dotfiles. The
        # family is "DroidSansM Nerd Font" — one word up to the M, so the
        # pattern has no space in it.
        font_probe = "fc-list | grep -qi droidsansm"
        for who in ["root", "${other}"]:
            machine.succeed("su - " + who + " -c " + shlex.quote(font_probe))
  '';

in
pkgs.testers.runNixOSTest {
  name = "sidorenko-dotfiles-nixos" + lib.optionalString systemScope "-system";

  nodes.machine = { config, pkgs, ... }: {
    imports = [ homeManagerModule ] ++ lib.optionals systemScope [
      dotfiles.nixosModules.default
      # The control account, as an inline module rather than another
      # `users.users.<name>` line below: two definitions of that path in one
      # attrset literal is a duplicate-attribute error, and `mkIf` cannot be
      # used because merely NAMING a key under users.users creates the account
      # (with the submodule's defaults, i.e. a system user) whether the
      # condition held or not.
      #
      # Deliberately plain: no dotfiles, no home-manager generation, no shell
      # wiring. If it can run the toolchain, the toolchain is on the machine
      # rather than in one profile.
      { users.users.${other} = { isNormalUser = true; password = "test"; }; }
    ];

    virtualisation = {
      memorySize = 4096;
      cores = 4;
      # The package set from the manifests is sizeable; the default 1024 MiB
      # image is not enough to hold the closure plus a GNOME session.
      diskSize = 16384;
    };

    users.users.${user} = {
      isNormalUser = true;
      home = home;
      extraGroups = [ "wheel" ];
      # Deterministic, and only ever exists inside a throwaway VM.
      password = "test";
      # zsh as the login shell, matching the real host. Set here rather than in
      # a second users.users.${user} block, which is a duplicate dynamic
      # attribute and a hard evaluation error.
      shell = pkgs.zsh;
    };

    # A graphical session, because the gui-tagged rows and the whole
    # gsettings layer are only in scope when one exists. GNOME, matching the
    # real host, and autologin so the user's systemd session (and therefore
    # the gsettings unit) actually starts.
    services.xserver.enable = true;
    services.displayManager = {
      gdm.enable = true;
      autoLogin = { enable = true; user = user; };
    };
    services.desktopManager.gnome.enable = true;

    # GNOME's own first-run wizard would sit in front of the session.
    services.gnome.gnome-initial-setup.enable = false;

    programs.zsh.enable = true;

    # Tools the verifier itself needs on PATH. fontconfig is for the
    # system-scope font assertion: asking fc-list is the real question (does
    # fontconfig SEE the font) rather than guessing which share/ directory
    # NixOS put it in.
    environment.systemPackages = with pkgs; [
      git glib coreutils gnugrep gnused gawk diffutils fontconfig
    ];

    # Seed the working tree before home-manager activates, since the
    # activation script links out of it.
    systemd.services."seed-dotfiles" = {
      wantedBy = [ "multi-user.target" ];
      before = [ "home-manager-${user}.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        ExecStart = "${seedTree}";
      };
    };

    home-manager.useGlobalPkgs = true;
    home-manager.useUserPackages = true;
    home-manager.users.${user} = {
      imports = [ dotfiles.homeModules.default ];
      home.stateVersion = "26.05";
      home.username = user;
      home.homeDirectory = home;
      sidorenkoDotfiles = {
        livePath = "${home}/.sidorenko_dotfiles";
        gui = true;
        manageGnomeSettings = true;
        sourceRev = dotfiles.rev or "dirty";
        # In system scope ../nixos.nix owns the package set, so the user
        # profile must not declare it as well — see that option's description.
        managePackages = !systemScope;
      };
    };
  };

  testScript = ''
    import os
    import shlex

    start_all()

    machine.wait_for_unit("multi-user.target")

    # Print the journal BEFORE asserting, for both of the units this test
    # depends on. A bare wait_for_unit raises with only "reached state failed",
    # which says nothing about why — the first run of this test died that way
    # and the reason (git refusing a root-run command in a user-owned repo)
    # was invisible until the journal was dumped by hand.
    def unit_journal(unit):
        _, out = machine.execute(f"journalctl -u {unit} --no-pager -o cat")
        print(f"----- journal: {unit} -----\n{out}")
        return out

    unit_journal("seed-dotfiles.service")
    machine.wait_for_unit("seed-dotfiles.service")

    # home-manager runs as a system service here (useUserPackages), so its
    # completion is the signal the dotfiles have been applied.
    unit_journal("home-manager-${user}.service")
    machine.wait_for_unit("home-manager-${user}.service")

    with subtest("the working tree was seeded and is a git checkout"):
        machine.succeed("test -d ${home}/.sidorenko_dotfiles/manifests")
        machine.succeed("su - ${user} -c 'git -C ${home}/.sidorenko_dotfiles rev-parse HEAD'")

    with subtest("home-manager activation reported no hard failure"):
        out = unit_journal("home-manager-${user}.service")
        assert "apply-links.sh failed" not in out, \
            "the dotfiles activation script failed; see the journal above"

    # The gsettings unit is bound to graphical-session.target, so it only runs
    # once the user session is up. Wait for the session rather than the unit:
    # on a headless-ish VM GDM can take a while to settle.
    with subtest("graphical session starts and the gsettings unit runs"):
        machine.wait_for_unit("display-manager.service")
        machine.wait_until_succeeds(
            "systemctl --user --machine=${user}@ is-active sidorenko-gsettings.service "
            "|| systemctl --user --machine=${user}@ show sidorenko-gsettings.service "
            "-p Result --value | grep -qx success",
            timeout=180,
        )
        print(machine.succeed(
            "journalctl --user-unit sidorenko-gsettings -M ${user}@ --no-pager || true"
        ))

    # The measurement, by the same script the Ubuntu VM runs.
    with subtest("verify-applied: everything the manifests imply is true"):
        cmd = (
            "cd ${home}/.sidorenko_dotfiles && "
            "./manifests/verify-applied.sh --gui --nixos --platform linux"
        )
        rc, out = machine.execute(f"su - ${user} -c {shlex.quote(cmd)}")
        print(out)

        # The TSV copy is the artefact the two platforms get compared on.
        tsv_cmd = (
            "cd ${home}/.sidorenko_dotfiles && "
            "./manifests/verify-applied.sh --gui --nixos --platform linux --tsv"
        )
        _, tsv = machine.execute(f"su - ${user} -c {shlex.quote(tsv_cmd)}")
        with open(f"{os.environ['out']}/verify.tsv", "w") as fh:
            fh.write(tsv)

        assert rc == 0, (
            "verify-applied.sh found failures on NixOS. Its output is above; "
            "the per-check rows are in $out/verify.tsv"
        )

        # SILENCE IS NOT SUCCESS. rc == 0 only means "no FAIL rows", which is
        # equally true of a run that checked NOTHING — a mistyped flag, a
        # verifier that died early, a manifest that parsed to zero rows would
        # all pass the assertion above. So require real evidence: a non-empty
        # artefact, and a floor on how many checks actually passed.
        #
        # This is not hypothetical. The first passing run wrote an EMPTY
        # verify.tsv (the script redirected to /dev/stdout, which yields
        # nothing when stdout is a pipe) and the test was perfectly happy.
        rows = [r for r in tsv.splitlines() if r and not r.startswith("#")]
        passes = [r for r in rows if r.startswith("PASS")]
        print(f"verify.tsv: {len(rows)} rows, {len(passes)} PASS")

        assert rows, (
            "verify-applied.sh --tsv produced no rows; the artefact is empty, so "
            "the run above proved nothing"
        )
        # A GNOME VM with the package set applied yields well over a hundred
        # checks. 50 is a floor that cannot be met by accident but will not
        # trip when a few rows legitimately become SKIP.
        assert len(passes) >= 50, (
            f"only {len(passes)} checks passed; expected 50+ on a GUI NixOS "
            "host. Something is not being measured."
        )

    ${systemScopeTests}
  '';
}
