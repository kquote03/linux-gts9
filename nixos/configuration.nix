# SM-X716B user-facing configuration -- edit this file freely. Desktop
# choice, installed apps, Bluetooth, networking, users, locale: anything
# here is yours to change. After editing: `sudo nixos-rebuild switch`
# (run from anywhere -- it auto-detects /etc/nixos/flake.nix).
#
# The non-negotiable device plumbing (kernel, firmware, the ADSP/sensor
# stack, USB gadget, vendor partitions) lives in ./hardware.nix instead --
# don't edit that one unless you know the hardware reason behind a line.
{ config, lib, pkgs, ... }:

let
  user = "x716b";
in
{
  ##############
  # Desktop    #
  ##############

  services.xserver.enable = false; # Wayland only
  services.displayManager.sddm = {
    enable = true;
    wayland.enable = true;
  };
  services.desktopManager.plasma6.enable = true;

  # Touch-first device: ship the on-screen keyboard + rotation bits, the
  # Bluetooth + graphics-tablet System Settings modules, and a browser
  # (also how you log into a WiFi captive portal before anything else on
  # the network works) + Krita (S Pen + the tablet KCM below are for
  # something).
  environment.plasma6.excludePackages = [ ];
  environment.systemPackages = with pkgs; [
    kdePackages.plasma-nm
    kdePackages.plasma-pa
    kdePackages.kscreen
    kdePackages.bluedevil
    kdePackages.wacomtablet # Graphics Tablet KCM + kded daemon
    maliit-keyboard
    firefox
    krita
    vim
    git
    usbutils
    pciutils
    alsa-utils
    iw
  ];

  ##############
  # Bluetooth  #
  ##############

  hardware.bluetooth.enable = true;
  hardware.bluetooth.powerOnBoot = true;
  # gts9wifi-bt-provision (provisions the Samsung EFS BT address) and
  # gts9wifi-bt-revive (recovers hci0 after the WCN power sequencer
  # cycles it) are defined in ./hardware.nix -- this just turns the
  # generic BlueZ stack + Plasma applet on.

  ##############
  # Audio      #
  ##############

  services.pulseaudio.enable = false;
  security.rtkit.enable = true;
  services.pipewire = {
    enable = true;
    alsa.enable = true;
    pulse.enable = true;
    wireplumber.enable = true;
  };

  ##############
  # Networking #
  ##############

  networking.hostName = "x716b";
  networking.networkmanager = {
    enable = true;
    wifi.powersave = false; # 72-gts9wifi-wifi-powersave-off.rules / conf.d
  };
  # gts9wifi-usb-net (./hardware.nix) brings usb0 up with a static debug
  # address; keep NM from fighting it.
  networking.networkmanager.unmanaged = [ "interface-name:usb0" ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
    settings.PermitRootLogin = "yes";
  };

  # Clock: gts9wifi-chronyd in the overlay; use the native option (the
  # sandbox-compat fix for this kernel lives in ./hardware.nix).
  services.chrony.enable = true;

  ##############
  # Users      #
  ##############

  users.mutableUsers = true;
  users.users.${user} = {
    isNormalUser = true;
    description = "SM-X716B user";
    extraGroups = [ "wheel" "networkmanager" "video" "audio" "input" "dialout" ];
    initialPassword = user;
  };
  users.users.root.initialPassword = user;
  security.sudo.wheelNeedsPassword = false;

  # Match the Fedora build: locale/timezone are unset-ish, user sets them.
  time.timeZone = lib.mkDefault "UTC";
  i18n.defaultLocale = lib.mkDefault "en_US.UTF-8";

  services.libinput.enable = true;

  ##################################
  # XWayland ownership-check fix   #
  ##################################

  # Re-assert root:root 1777 on /tmp/.X11-unix for XWayland ownership
  # checks: XWayland aborts if that dir isn't owned by root (or the
  # session user); if something recreates it per-uid mid-session, every
  # other uid's Plasma session aborts. A *timer*, not a .path unit (the
  # .path version re-fires continuously for as long as the path merely
  # exists and this oneshot never removes it -- an unbounded restart
  # loop, ~50 starts/sec on real hardware -- see docs/porting-log.md).
  systemd.tmpfiles.rules = [ "d /tmp/.X11-unix 1777 root root -" ];
  systemd.services.gts9wifi-x11-dir-fix = {
    description = "Re-assert root:root 1777 on /tmp/.X11-unix for XWayland ownership checks";
    serviceConfig = {
      Type = "oneshot";
      # Only touch the inode when actually wrong, so a no-op doesn't
      # needlessly wake anything watching the directory via inotify.
      ExecStart = "${pkgs.runtimeShell} -c '[ \"$(${pkgs.coreutils}/bin/stat -c %U:%a /tmp/.X11-unix 2>/dev/null)\" = root:1777 ] || { ${pkgs.coreutils}/bin/chown root:root /tmp/.X11-unix && ${pkgs.coreutils}/bin/chmod 1777 /tmp/.X11-unix; }'";
    };
    startLimitIntervalSec = 60;
    startLimitBurst = 20;
  };
  systemd.timers.gts9wifi-x11-dir-fix = {
    description = "Periodically re-assert /tmp/.X11-unix ownership";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "10s"; OnUnitActiveSec = "30s"; AccuracySec = "10s"; };
  };
}
