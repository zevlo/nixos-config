# ThinkPad L480 (i5-8350U) — NixOS + GNOME Management Workstation

> Sibling to the T14s: a second homelab ops laptop, this time on NixOS + Intel instead of Arch + AMD. Same GNOME daily-driver / manage-the-cluster-from-here role; same toolchain where it makes sense, deliberately trimmed where it doesn't. Companion to [`thinkpad-t14s-setup.md`](thinkpad-t14s-setup.md), [`mac-mini-setup.md`](mac-mini-setup.md), and [`cluster-build.md`](cluster-build.md).
>
> Drafted August 2026; revised August 2026 to trim to a true minimal build — dropped cloud IaC (`aws-cli`/`terraform`/`ansible`), the C toolchain, `helm`, and the base AI CLI; added **Zed** as the IDE, plus `nil`/`alejandra` (nix LSP + formatter) and `nix-ld` (runs prebuilt binaries). Where the T14s is an imperative Arch runbook (pacstrap / pacman / yay), this is a **declarative Nix** runbook — the whole system is defined in `flake.nix` + `configuration.nix`, installed with `nixos-install --flake`. Read each command before running; verify output matches the notes.

---

## Role & scope

**The L480 is a co-equal daily-driver + homelab ops laptop.** Full ops parity with the T14s, lighter on the dev-languages and GUI-app layer.

| Is | Is NOT |
|----|--------|
| NixOS (flakes) + GNOME workstation; bash / vim / tmux core; **Zed** IDE | Encrypted — plaintext disk, keep physical control |
| Dev box: **Python + Node.js via nix** (no `mise`, no C toolchain) — system-managed, no version manager | A Kubernetes node — manage the cluster *from* here, don't join it |
| k8s CLIs (kubectl / k9s / argocd / kubeseal) + **Docker** — backup-management set (argocd renders Helm) | A media/gaming rig — desktop-only graphics (Intel UHD 620) |
| Browser = LibreWolf; notes = Obsidian; IDE = Zed (all nixpkgs — no AUR/yay, no flakes) | A polyglot dev box — **no Go / Rust / Zig, no cloud IaC** (deliberate) |
| AI CLI = none in base (`opencode` + `agy` both in nixpkgs; add one line when wanted) | Running Gemini CLI — it was sunset 2026-06-18 (see "Deliberately omitted") |

---

## What changed vs. the T14s (read this first)

Two deltas drive every difference below:

- **Arch → NixOS.** `pacstrap`/`pacman`/`yay` → one declarative flake. `systemctl enable foo` → `services.foo.enable = true`. `ufw` → `networking.firewall`. The `dd` swapfile dance → a `swapDevices` line. Most apps that were **AUR-only** on the T14s (LibreWolf, Obsidian) are plain `nixpkgs` here. The T14s "GNOME app cleanup" phase disappears entirely — on NixOS you only install what you declare, so the bloat never lands.
- **T14s (AMD) → L480 (Intel).** `amd-ucode` → `intel-ucode` (`hardware.cpu.intel.updateMicrocode`). `vulkan-radeon` / `mesa` → `mesa` + `intel-media-driver` (UHD 620 / `i915` VAAPI decode). CPU governor `amd-pstate-epp` → Intel `intel_pstate`. Wi-Fi is Intel (`iwlwifi`), so `hardware.enableRedistributableFirmware = true` matters. fwupd/LVFS and the F1/F12 BIOS keys are identical to the T14s. (Power differs: the T14s uses TLP + a `tlp-pd` shim; the L480 uses stock GNOME power-profiles-daemon — see the note in configuration.nix.)

---

## Hardware & assumptions

- **Lenovo ThinkPad L480**, Intel **i5-8350U** (4C/8T, Kaby Lake-R / Gen 9.5), **16 GB DDR4**, **512 GB SSD**.
- **SSD is SATA (`/dev/sda`)** — this L480 is the SATA variant (an NVMe L480 would appear as `/dev/nvme0n1` with `nvme0n1p1`/`nvme0n1p2` partitions).
- **No full-disk encryption.** Plain GPT: 1 GB EFI + ext4 root + 16 GB swapfile (now declarative).
- **GNOME** desktop (gdm, Wayland); **kitty** is the only terminal.
- **systemd-boot** (NixOS default), not GRUB. **Suspend only** (no hibernation).
- This guide **wipes the 512 GB SSD.**

---

## Phase 0 — Pre-flight (Windows PC + balenaEtcher)

Prepare the install USB on a **Windows PC** (the L480 isn't needed yet):

1. Download the **minimal x86_64 ISO** (matches this manual flake install) and its hash:
   - `https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso`
   - `https://channels.nixos.org/nixos-26.05/latest-nixos-minimal-x86_64-linux.iso.sha256`
2. **Verify** (PowerShell): `Get-FileHash latest-nixos-minimal-x86_64-linux.iso -Algorithm SHA256` → compare to the `.sha256` file opened in Notepad. (cmd alt: `certutil -hashfile latest-nixos-minimal-x86_64-linux.iso SHA256`.)
3. **Flash** with [balenaEtcher](https://etcher.balena.io/): pick the ISO → pick the USB → Flash. Etcher validates the write automatically.
4. **Gotcha:** if Windows pops *"You need to format the disk in drive X: before you can use it"* after flashing — **Cancel** it. That's the NixOS ESP partition; formatting would break the USB.

You also need the L480, an **Ethernet cable** (preferred — wired DHCP is zero-config on the installer and makes `nixos-install` fast), and the Mac on the same LAN for the Phase 7 `scp` of `~/.kube` / `~/.config/k9s`. The flake is written inline in Phase 3 below; nothing else to prep.

---

## Phase 1 — Boot the installer & get online

1. Plug in the USB, power on, press **F12** repeatedly for the boot menu. If it refuses the USB, press **F1** → BIOS → **disable Secure Boot** (and put USB first), save, retry.
2. At the root prompt, get online. **Ethernet (preferred):** DHCP auto-configures — skip to step 3. **Wi-Fi** (only if no wired):
   ```bash
   nmtui                     # or: nmcli device wifi connect "YourNetworkName" password "..."
   ```
3. Time + sanity:
   ```bash
   timedatectl set-ntp true
   ping -c 3 nixos.org
   ```
4. Confirm the SSD device node before partitioning:
   ```bash
   lsblk                     # this L480 shows /dev/sda (SATA variant)
   ```
   This guide uses **`/dev/sda`** (SATA). An NVMe L480 would instead be `/dev/nvme0n1` with `nvme0n1p1`/`nvme0n1p2` partitions.

---

## Phase 2 — Partition the SSD (no encryption)

1 GB EFI + rest root; swap is **declarative** (Phase 3), so no `dd` here.

```bash
parted /dev/sda -- mklabel gpt          # destroys existing sda1/sda2 — parted will prompt, confirm yes
parted /dev/sda -- mkpart ESP fat32 1MiB 1025MiB
parted /dev/sda -- set 1 esp on
parted /dev/sda -- mkpart primary 1025MiB 100%

mkfs.fat -F32 /dev/sda1
mkfs.ext4 /dev/sda2

mount /dev/sda2 /mnt
mount --mkdir /dev/sda1 /mnt/boot
```

---

## Phase 3 — Generate the config & author the flake

### 3a. Generate the hardware skeleton

```bash
nixos-generate-config --root /mnt
```

This writes `/mnt/etc/nixos/configuration.nix` (a commented-out sample — we replace it) and `/mnt/etc/nixos/hardware-configuration.nix` (**keep this as-is**: it has the correct file-system UUIDs and kernel modules for this machine). Then:

```bash
cd /mnt/etc/nixos
```

### 3b. Write `flake.nix`

We track the **whole system in git like code**, pinning `nixpkgs` via `flake.lock`. Input is **`nixos-26.05`** (stable), not `nixos-unstable` — the L480 is a minimal, set-and-forget box, so less churn and fewer surprise breakages on `nixos-rebuild` beat chasing the latest point releases. The one tradeoff: `zed-editor` lands at **v1.3.6** on 26.05 (vs v1.13.x on unstable) and `opencode` at **v1.15.10** — both perfectly usable. `flake.lock` still pins a reproducible build regardless.

```nix
# /mnt/etc/nixos/flake.nix
{
  description = "Lenovo ThinkPad L480 — NixOS + GNOME ops workstation";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
    nixos-hardware.url = "github:NixOS/nixos-hardware";
  };

  outputs = { self, nixpkgs, nixos-hardware, ... }@inputs: {
    nixosConfigurations.l480 = nixpkgs.lib.nixosSystem {
      system = "x86_64-linux";
      modules = [
        ./configuration.nix
        inputs.nixos-hardware.nixosModules.lenovo-thinkpad   # generic ThinkPad tweaks (TrackPoint, etc.)
      ];
    };
  };
}
```

> `nixos-hardware` has model-specific modules under `lenovo/thinkpad/…`; there isn't a documented L480 one, so we use the generic `lenovo-thinkpad` module. If a `lenovo-thinkpad-l480` path appears later, swap it in.

### 3c. Write `configuration.nix`

Replace the generated sample with this. This is the entire system definition — bootloader, Intel/firmware, graphics, GNOME, audio, firewall, SSH, Docker, Tailscale, GNOME power-profiles-daemon, the full package list, fonts, and `nix-ld` (escape hatch for running prebuilt binaries later).

```nix
# /mnt/etc/nixos/configuration.nix
{ config, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix   # generated by nixos-generate-config — leave as-is
  ];

  # ---- Bootloader: systemd-boot (no GRUB, no LUKS) ----
  boot.loader.systemd-boot.enable = true;
  boot.loader.systemd-boot.configurationLimit = 10;   # 10 generations fit comfortably in the 1 GB ESP (~50 MB each)
  boot.loader.efi.canTouchEfiVariables = true;
  # boot.loader.timeout = 5;   # default is fine

  # ---- Kernel + firmware ----
  hardware.enableRedistributableFirmware = true;   # iwlwifi Wi-Fi firmware, etc.
  hardware.cpu.intel.updateMicrocode   = true;     # intel-ucode (needs the line above)

  # ---- Swap: 16 GB swapfile, declarative (no dd) ----
  swapDevices = [ { device = "/swapfile"; size = 16 * 1024; } ];   # size is in MB

  # ---- Networking ----
  networking.hostName = "nix";                     # (T14s is "arch")
  networking.networkmanager.enable = true;

  # Firewall (NixOS-native; replaces ufw from the T14s)
  networking.firewall = {
    enable = true;
    # SSH is opened via services.openssh.openFirewall below.
    # When you `tailscale up`, uncomment to allow its UDP:
    # allowedUDPPorts = [ 41641 ];
  };

  # ---- Time / locale (parity with T14s) ----
  time.timeZone = "America/New_York";
  i18n.defaultLocale = "en_US.UTF-8";
  i18n.extraLocaleSettings = {
    LC_ADDRESS       = "en_US.UTF-8";
    LC_IDENTIFICATION= "en_US.UTF-8";
    LC_MEASUREMENT   = "en_US.UTF-8";
    LC_MONETARY      = "en_US.UTF-8";
    LC_NAME          = "en_US.UTF-8";
    LC_NUMERIC       = "en_US.UTF-8";
    LC_PAPER         = "en_US.UTF-8";
    LC_TELEPHONE     = "en_US.UTF-8";
    LC_TIME          = "en_US.UTF-8";
  };

  # ---- Graphics: Intel UHD 620 (i915 loads automatically) ----
  hardware.graphics.enable      = true;
  hardware.graphics.enable32Bit = true;
  hardware.graphics.extraPackages = with pkgs; [ intel-media-driver intel-vaapi-driver ];   # VAAPI decode, Gen 8+ (media-driver = newer codecs, vaapi-driver = older MPEG/JPEG paths)

  # ---- GNOME desktop (Wayland, gdm) ----
  services.xserver.enable = true;                       # umbrella + libinput path
  services.libinput.enable = true;              # ThinkPad TrackPoint + Touchpad
  services.displayManager.gdm.enable = true;
  services.desktopManager.gnome.enable = true;
  # (Older nixpkgs used services.xserver.{displayManager.gdm,desktopManager.gnome} — those
  #  still work as aliases; the lines above are the current namespace.)

  # Don't pull the GNOME apps we won't use (kitty is the only terminal; LibreWolf is the browser).
  environment.gnome.excludePackages = with pkgs.gnome; [
    epiphany             # GNOME Web
    geary                # mail
    gnome-console        # kitty is the only terminal
    gnome-contacts
    gnome-initial-setup
    gnome-music
    gnome-software       # no GUI store — we use nix
    gnome-tour
    gnome-calendar
    gnome-weather
    gnome-maps
    gnome-characters
    simple-scan
    totem                # video player
    yelp                 # help browser
  ];

  # ---- Audio: PipeWire (replaces PulseAudio) ----
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    alsa.support32Bit = true;
    pulse.enable = true;
  };

  # ---- Bluetooth (the L480 has it; enable if you use it) ----
  hardware.bluetooth.enable = false;   # off — not used; GNOME hides the toggle when no daemon

  # ---- Firmware updates via LVFS ----
  services.fwupd.enable = true;

  # ---- Power: GNOME's power-profiles-daemon (ppd) ----
  # GNOME enables ppd by default — it owns the Balanced / Power-saver /
  # Performance slider in gnome-control-center. TLP is NOT enabled: NixOS
  # hard-asserts that TLP and ppd are mutually exclusive (a failed assertion,
  # not just one disabling the other), and ppd is the GNOME-integrated choice.
  # (The T14s uses TLP + a `tlp-pd` shim; the L480 keeps it simple with stock ppd.)

  # ---- Docker (parity with T14s — manage containers directly) ----
  virtualisation.docker.enable = true;
  # user `zev` is added to the docker group via extraGroups below.

  # ---- Tailscale: daemon enabled; `tailscale up` login is deferred (see Install later) ----
  services.tailscale.enable = true;

  # ---- SSH: enabled + locked to keys ----
  services.openssh = {
    enable = true;
    openFirewall = true;                       # opens 22/tcp
    settings = {
      PermitRootLogin = "no";
      PasswordAuthentication = false;
      X11Forwarding = false;
    };
  };

  # ---- User (password set interactively during install via `nixos-enter` —
  # see Phase 4; no password material lives in this file or git) ----
  users.users.zev = {
    isNormalUser = true;
    description  = "zev";
    extraGroups  = [ "wheel" "docker" "audio" "video" "networkmanager" ];
  };
  security.sudo.enable = true;            # wheel has sudo
  security.sudo.wheelNeedsPassword = false;   # passwordless sudo (any process as zev → instant root; deliberate)

  # ---- Unfree: needed for Obsidian (LibreWolf + Zed are free) ----
  nixpkgs.config.allowUnfree = true;

  # ---- Nix: flakes on, plus weekly GC / auto-optimise ----
  nix.settings.experimental-features = [ "nix-command" "flakes" ];
  nix.gc = {
    automatic = true;
    dates = "weekly";
    options = "--delete-older-than 30d";
  };
  nix.optimise.automatic = true;

  # ---- nix-ld: restore the FHS dynamic linker NixOS omits, so curl-downloaded
  # prebuilt binaries run without patchelf. opt-in escape hatch for tools not in
  # nixpkgs (everything in the package list above doesn't need it). ----
  programs.nix-ld.enable = true;

  # ---- Fonts: JetBrains Mono Nerd Font (for starship / tmux / kitty glyphs) ----
  fonts.packages = with pkgs; [ nerd-fonts.jetbrains-mono ];   # monolithic `nerdfonts` was removed from nixpkgs; the split attr is the only option now

  # ---- Packages ----
  environment.systemPackages = with pkgs; [
    # core CLI / shell
    vim bash-completion tmux git starship kitty fastfetch
    jq tree shellcheck dnsutils rsync curl wget man-pages just
    # media
    ffmpeg
    # Python + Node (no mise, no C toolchain — see "Deliberately omitted")
    # pipx omitted: derivation fails to build on nixos-26.05 (2026-08); ad-hoc via `nix-shell -p pipx`.
    python3 nodejs
    # IDE — Zed (free software, built from source; renders via Vulkan/Mesa on UHD 620)
    zed-editor
    # k8s / homelab ops — backup-management set for the Mac Mini's GitOps role
    # (argocd renders Helm in-cluster → no helm CLI; kubeseal stays so this box
    #  can run kubeseal --fetch-cert + seal secrets when the Mac Mini is down)
    kubectl k9s argocd kubeseal github-cli
    # networking / VPN
    tailscale
    # GUI apps (librewolf = free; obsidian = unfree)
    librewolf obsidian
    # nix tooling — LSP + formatter so Zed autocompletes/formats configuration.nix
    nil alejandra
  ];

  # ---- Don't touch after install ----
  system.stateVersion = "26.05";   # set to the release you installed with; never change it
}
```

Notes on the package list:
- **No `mise`, no Go / Rust / Zig, no `gopls` / `rust-analyzer`, no C toolchain.** Languages are Python + Node only, both nix-managed. On NixOS there's no Arch PEP-668 "externally-managed" story to work around — `python3` is just another nix package; use `python -m venv` for project envs. (`pipx` is omitted — its derivation fails to build on nixos-26.05 as of 2026-08; run it ad-hoc via `nix-shell -p pipx`, or re-add to the package list once the binary cache catches up.) Add `gcc` / `gdb` / `cmake` / `binutils` / `pkg-config` back as one line if a project needs to compile C.
- **No cloud IaC** (`awscli2` / `terraform` / `ansible`) — you manage the homelab with kubectl / argocd, not IaC. Each is a one-line nixpkgs add later.
- **No `helm`** — argocd renders Helm charts in-cluster, so the local CLI has no job here. Add only if you start running `helm upgrade` by hand outside argocd.
- **No AI CLI in the base** — `opencode` and `antigravity-cli` (`agy`) are both in nixpkgs; add either as one line when wanted (see "Install later"). `gemini-cli` is sunset, don't install it.
- `dnsutils` gives `dig` / `host` / `nslookup` (the Arch box installed `bind` for the same).
- `github-cli` provides `gh`; `zed-editor` provides `zed`.
- **`nil` + `alejandra`** are nix tooling: the nix LSP and formatter, so Zed gives autocomplete + format-on-save while you edit `configuration.nix` / `flake.nix`.
- The T14s `yq` caveat carries over: NixOS's `yq` is the **kislyuk** Python/jq build, not Mike Farah's Go build — omitted. If a real need appears, grab the Go binary from `github.com/mikefarah/yq/releases` and drop it in `~/.local/bin`; `nix-ld` will run it.

---

## Phase 4 — Install & reboot

```bash
nixos-install --flake /mnt/etc/nixos#l480
```

Set the **root** password when prompted (or add `--no-root-passwd` to skip — root login is blocked in sshd anyway). Then set `zev`'s password inside the installed system before rebooting — no password lives in the flake:

```bash
nixos-enter --root /mnt -c 'passwd zev'     # type zev's real password, twice
reboot                                      # pull the USB when the screen goes black
```

> `nixos-enter` chroots into `/mnt` and writes the installed system's `/etc/shadow`, so the password persists into first boot. Change it later with `passwd` as `zev` — no config change.

> If `nixos-install` complains about flakes being disabled (older ISOs), the modern NixOS ISO already enables `nix-command` + `flakes`; otherwise prefix with `--option experimental-features 'nix-command flakes'`.

**First boot:** the gdm login screen appears — sign in as **`zev`** with the password you set via `nixos-enter` in Phase 4. **GNOME top bar → connect Wi-Fi** if you're on wireless (Ethernet users are already online). This box isn't finished over SSH the way the T14s was — the whole system is already declared in the flake, so just log in at the keyboard.

> **Applying changes later** (the NixOS equivalent of re-running pacman): edit `flake.nix` / `configuration.nix`, then from `/etc/nixos`:
> ```bash
> sudo nixos-rebuild switch --flake .#l480
> ```
> Keep `flake.nix`, `configuration.nix`, and `hardware-configuration.nix` under version control — the whole machine is those three files.

---

## Phase 5 — Harden (already mostly done declaratively)

Unlike the T14s, the firewall and sshd hardening landed with the install (Phase 3), so there's no separate "enable ufw before you lock yourself out" dance. Verify:

```bash
sudo iptables -S | grep -i drop        # networking.firewall is up
sudo sshd -T | grep -Ei 'permitroot|passwordauth|X11'   # no / no / no
```

SSH is locked to keys (`PasswordAuthentication no`). AppArmor / Secure Boot stay off (same posture as the T14s).

---

## Phase 6 — Verify the Intel / ThinkPad base

```bash
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver   # expect: intel_pstate
sudo fwupdmgr refresh && sudo fwupdmgr update             # Lenovo BIOS/firmware via LVFS
powerprofilesctl get                                      # GNOME power profile (Balanced/Power-saver/Performance)
cat /sys/class/power_supply/BAT0/capacity                 # battery %
vainfo                                                    # VAAPI video decode (needs libva-utils — see note)
```

`vainfo` needs `libva-utils` — not in the base list; install on demand with `nix-shell -p libva-utils --run vainfo` (or add `libva-utils` to the package list and rebuild). Same for a quick GL check: `nix-shell -p mesa-demos --run glxinfo`, and to confirm Zed will get hardware Vulkan on the UHD 620: `nix-shell -p vulkan-tools --run vulkaninfo --summary` (expect an Intel driver entry).

---

## Phase 7 — Dotfiles & carry-over from the Mac

Same repo, same manual-copy workflow as the T14s (**not** GNU Stow), adapted for "no mise":

```bash
gh auth login                                  # if not already authenticated
git clone git@github.com:zevlo/dotfiles.git ~/dotfiles
```

What actually lands on the L480 (mirror of the T14s table, minus mise):

| File | Status on L480 |
|---|---|
| `~/.config/starship.toml` | copied as-is from `starship/` |
| `~/.config/kitty/{kitty.conf,current-theme.conf}` | copied as-is from `kitty/` |
| `~/.bashrc` | copied from `bash/.bashrc` then edited — drop Homebrew / `eza` / `bat`; **drop the `eval "$(mise activate bash)"` line and the `export PATH="$HOME/go/bin:$PATH"` line** (no mise, no Go); keep `eval "$(starship init bash)"`, `export TERMINAL=kitty`, history opts, kubectl completion, `ls`/`grep` aliases |
| `~/.bash_profile` | hand-written clean version (`[[ -f ~/.bashrc ]] && . ~/.bashrc`) — same as T14s |
| `~/.gitconfig` | hand-written minimal `[user]` block — same as T14s |
| `mise/config.toml` | **not carried** — no mise on the L480 |
| `~/.vimrc`, `~/.tmux.conf` | same status as T14s (tracked in repo, place when ready) |
| `ghostty/` | inert (Mac terminal) |

**Zed + nix tooling:** `nil` and `alejandra` are installed but Zed won't auto-format with them. Add to `~/.config/zed/settings.json` so `nil` delegates formatting to `alejandra` (Zed auto-detects `nil` for Nix files):

```json
{
  "lsp": {
    "nil": {
      "initialization_options": { "formatting": { "command": ["alejandra"] } }
    }
  }
}
```

Reconnect the homelab state and accounts (the `scp` options below assume you've first added your Mac pubkey to `~/.ssh/authorized_keys` at this laptop's keyboard — sshd is keys-only):
- **`gh`:** authed (`zevlo`) — `gh auth login` on a fresh box.
- **`~/.kube`:** regenerate with `kubectl`, or `scp -r ~/.kube zev@<ip>:~/` from the Mac when the cluster is reachable.
- **`~/.config/k9s`:** `scp -r ~/.config/k9s zev@<ip>:~/.config/` from the Mac.
- **1Password:** install the "1Password in the browser" extension in LibreWolf → sign in. (Desktop app intentionally not installed, so no SSH-agent / OS integration — you use standalone SSH keys instead.)

---

## Phase 8 — GNOME setup

- **Font:** open **GNOME Tweaks** → set **Monospace → JetBrainsMono Nerd Font** so starship / tmux / kitty glyphs render.
  - GNOME Tweaks is in the GNOME module by default. If missing, add `gnome-tweaks` to the package list and rebuild.
- **Default terminal:** the `$TERMINAL=kitty` env var in `~/.bashrc` covers most cases; kitty is the only terminal (gnome-console was excluded in Phase 3).
- **App cleanup:** nothing to do — the GNOME bloat was never installed (see `environment.gnome.excludePackages` in Phase 3).

---

## Day-2 — living with NixOS (updating, adding packages, rebuild cadence)

The install is one-time; this is the recurring workflow. The shift from Arch: **you edit a config file, then "compile" the system** — there's no imperative per-package install in the persistent path.

### What rebuilds touch (and don't)

`nixos-rebuild switch` writes only to `/nix/store/...` and swaps the system profile (`/run/current-system` + a new boot generation). It **never touches `$HOME`** — so `~/.bashrc`, `~/.config/{kitty,starship,k9s}/`, `~/.kube/`, GNOME dconf keys, etc. are frozen across every rebuild, upgrade, and rollback. Your dotfiles are rebuild-safe.

The flip side: NixOS declares the *user* (`users.users.zev`) but not the *contents* of `/home/zev`. A rebuild brings back the system + binaries; it does **not** bring back dotfiles — those live in `github.com/zevlo/dotfiles`, not the flake.

### Command map: Arch → NixOS

| You want | Arch | NixOS (flake) |
|---|---|---|
| Install a package, persistently | `pacman -S foo` | add `foo` to `environment.systemPackages` → `sudo nixos-rebuild switch --flake .#l480` |
| Try a package, throwaway | — | `nix-shell -p foo` (or `nix run nixpkgs#foo`) |
| Update everything | `pacman -Syu` | `nix flake update` → `sudo nixos-rebuild switch --flake .#l480` |
| Remove a package | `pacman -Rs foo` | delete it from the list → rebuild |
| Roll back | (hard) | pick an older generation at the systemd-boot menu, or `sudo nixos-rebuild switch --rollback` |

> Avoid `nix profile install` — it's the imperative path that fights the declarative model. On NixOS, permanent = a line in `configuration.nix`.

### When to rebuild

Two triggers, only:

1. **You changed `configuration.nix` / `flake.nix`** (added a package, toggled a service, tweaked a setting).
2. **You want to upgrade packages** (below).

Rebuilds are always deliberate. The `nix.gc` block (weekly, `--delete-older-than 30d`) only garbage-collects the store — it does **not** upgrade anything.

### Adding a package (persistent)

```bash
vim /etc/nixos/configuration.nix      # add the name to environment.systemPackages
cd /etc/nixos
sudo nixos-rebuild switch --flake .#l480
git add -A && git commit -m "l480: add foo"
```

> `/etc/nixos` is a git repo (`git init` it after first boot) — the rebuild + commit loop assumes that. The whole machine is those three files.

Ad-hoc / non-persistent: `nix-shell -p foo` (a shell with `foo`, gone on exit) or `nix run nixpkgs#foo` (runs once without installing).

### Upgrading packages (the `pacman -Syu` equivalent)

`nixos-rebuild` alone does **not** upgrade — it rebuilds against whatever `flake.lock` is pinned to. To actually pull newer versions along the `nixos-26.05` branch:

```bash
cd /etc/nixos
nix flake update                              # bumps flake.lock → latest commit of nixos-26.05
git diff flake.lock                           # see what moved (recommended)
sudo nixos-rebuild switch --flake .#l480
git add flake.lock && git commit -m "l480: bump nixpkgs"
```

Upgrades are **atomic and whole-system**, not per-package. You will not jump to 27.05 automatically — that's a deliberate one-line change to the `nixpkgs.url` input when you choose to.

> **Upgrades stay manual by design.** `system.autoUpgrade` is deliberately OFF so you review the `flake.lock` diff before applying — that control is the whole point of choosing NixOS over Arch here.

### Generations & rollback

Every `switch` creates a bootable **generation** (capped at 10 by `boot.loader.systemd-boot.configurationLimit`). The systemd-boot menu at boot lists them — that's the universal undo.

```bash
sudo nixos-rebuild switch --rollback          # flip to the previous generation now
nixos-rebuild list-generations                # history
```

Roll back a bad upgrade: `git checkout flake.lock` + rebuild (persistent), or just boot an older generation (temporary, until the next rebuild). Either way, `$HOME` is unaffected.

---

## Install later (when a real need appears)

On NixOS "install later" usually means **add a line to `environment.systemPackages` → `sudo nixos-rebuild switch --flake .#l480`**, not a one-off command. `nix-shell -p <pkg>` is the ad-hoc, non-persistent way to try something first.

```bash
# Tailscale login (daemon is already enabled in the config)
sudo tailscale up                    # follow the URL, then `tailscale status`

# AI CLI — both are in nixpkgs (add to environment.systemPackages and rebuild):
#   opencode            # SST's agent CLI
#   antigravity-cli     # Google's agy (successor to the sunset gemini-cli)

# C toolchain (if a project needs to compile C / debug with gdb):
#   gcc gdb gnumake cmake binutils pkg-config

# Cloud IaC (if the homelab grows into it):
#   awscli2 terraform ansible
#   terraform companions: tflint terraform-docs

# Extra container tooling
#   add to environment.systemPackages: podman-compose buildah

# GitHub Actions local runner (dry-run workflows before pushing)
#   add to environment.systemPackages: act
```

---

## Deliberately omitted

- **Cloud IaC (`awscli2` / `terraform` / `ansible`)** — your homelab is k3s + argocd, managed with kubectl / argocd, not IaC. The T14s carries these for parity; the L480 doesn't. One-line nixpkgs add if a cloud-targeting project starts.
- **C toolchain (`gcc` / `gdb` / `gnumake` / `cmake` / `binutils` / `pkg-config`)** — Python + Node cover the "ability to code" need; no C compile / debug workload planned. One-line add if needed.
- **`helm`** — argocd renders Helm charts in-cluster, so the local CLI has no job here. Add only if you start running `helm upgrade` by hand outside argocd.
- **AI CLI in base (`opencode`, `antigravity-cli`)** — neither is installed by default, but **both are in nixpkgs** (`opencode` v1.15.x, `agy` via `antigravity-cli`), so adding one is a single line + rebuild. The T14s runs both.
  - **`gemini-cli`** — do NOT install. Google **sunset it on 2026-06-18** for free-tier / Google AI Pro / Ultra users (it still serves paid Code Assist / Enterprise licenses); installing it installs a client that fails auth. See Google's post: *An important update: Transitioning Gemini CLI to Antigravity CLI* (developers.googleblog.com, 2026-05-19).
- **Cursor** — a VS Code fork like Zed, but Cursor needs a community flake on NixOS while `zed-editor` is plain nixpkgs. Zed wins on the minimal / declarative axis; Cursor wins if you specifically want its built-in AI. The T14s runs Cursor.
- **`mise`** — no version manager on the L480; Python / Node are nix-managed. (Active on the T14s, where it also owns Go / Rust / Zig.)
- **Go / Rust / Zig** (and `gopls` / `rust-analyzer`) — out of scope by design. (The T14s runs all five languages via mise.)
- **Disk encryption (LUKS)** — your choice; keep physical control of the laptop. (Same as T14s.)
- **Hibernation** — suspend-only. (Same as T14s.)
- **`yq`** — same caveat as the T14s: NixOS's `yq` is the kislyuk Python build, not Mike Farah's Go build. (If needed, grab the Go binary from `github.com/mikefarah/yq/releases`; `nix-ld` will run it.)
- **`ufw`** — NixOS-native `networking.firewall` replaces it (declarative).
- **Discord, modern Rust CLI replacements (`eza`/`bat`/`fd`/`ripgrep`/`btop`/`fzf`/`tealdeer`)** — stock coreutils, same posture as the T14s.
- **AppArmor / Secure Boot / auto-updates** — not minimal.
