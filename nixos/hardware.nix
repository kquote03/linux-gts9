# SM-X716B hardware support -- everything needed to boot and talk to this
# exact device's silicon. Don't edit this unless you know the hardware
# reason behind a line; user-facing choices (desktop, browser, Bluetooth
# on/off, etc.) belong in ./configuration.nix instead, which imports this
# module as a fixed foundation.
#
# Covers: the prebuilt kernel + module tree, disabling the bootloader/
# initrd (ABL boots the Android `boot` partition directly -- see
# ../docs/boot-strategy.md), mounting the rootfs by label (one image
# serves both the microSD and userdata-partition deploy targets), vendor
# firmware/partitions, and the translated rootfs/overlay-systemd +
# overlay-common device overlay (ADSP/sensor/USB-gadget units).
#
# Source of truth for the ported gts9wifi-* units' ordering: each unit
# file's own comments under ../rootfs/overlay-systemd/ (several encode
# hardware-ordering fixes found on real hardware). Source of truth for
# what auto-starts: ../rootfs/overlay-systemd/usr/lib/systemd/
# system-preset/85-gts9wifi.preset -- the ADSP chain
# (hexagonrpcd-adsp-sensorspd + gts9wifi-adsp-boot) is deliberately
# manual-start (its start can SSR / freeze the SoC).
{ config, lib, pkgs, modulesPath, ... }:

let
  x = pkgs.x716b;
  lx = "${x.libexec}/libexec";

  # A gts9wifi-* oneshot backed by one of the ported libexec scripts.
  oneshot = { desc, exec, extra ? { }, unitExtra ? { }, wantedBy ? [ "multi-user.target" ] }:
    lib.recursiveUpdate {
      description = desc;
      inherit wantedBy;
      serviceConfig = {
        Type = "oneshot";
        ExecStart = exec;
        RemainAfterExit = true;
      } // (extra.serviceConfig or { });
    } (builtins.removeAttrs extra [ "serviceConfig" ] // unitExtra);
in
{
  nixpkgs.hostPlatform = lib.mkDefault "aarch64-linux";

  # This is a full, user-reconfigurable desktop now, not a stripped
  # appliance -- profiles/minimal.nix (dropped) turns off man/info pages,
  # MIME associations, xdg autostart/icons/sounds and udisks2 automount,
  # all things a real desktop with Firefox/Krita/file management wants on.

  # Self-rebuildable from /etc/nixos: `sudo nixos-rebuild switch` auto-
  # detects /etc/nixos/flake.nix once it exists (see
  # ./packages/etc-nixos.nix) and needs flakes enabled to do it.
  nix.settings.experimental-features = [ "nix-command" "flakes" ];

  ############################################################
  # Kernel + modules: the prebuilt tree from ./vendor/kernel  #
  ############################################################

  boot.kernelPackages = pkgs.linuxPackagesFor pkgs.x716b.kernel;

  # This port builds everything it needs into the Image or ships it as a
  # matching prebuilt module; NixOS should not try to (cross-)build any
  # kernel module of its own.
  nix.settings.system-features = lib.mkDefault [ ];
  boot.extraModulePackages = lib.mkForce [ ];

  #############################################
  # No NixOS-managed bootloader and no initrd #
  #############################################

  # ABL loads /dev/block/by-name/boot (the Android boot-image-v4 bundle
  # from ../scripts/build-android-v4-bundle.sh); NixOS's stage-1 and any
  # bootloader are dead weight here.
  boot.loader.grub.enable = false;
  boot.loader.generic-extlinux-compatible.enable = false;
  # Escape hatch so `nixos-rebuild switch` / activation don't assert on a
  # missing bootloader installer.
  system.build.installBootLoader = lib.mkForce "${pkgs.coreutils}/bin/true";

  # The Android bundle carries its own busybox switch_root initramfs
  # (../scripts/build-real-root-initramfs.sh). NixOS's own initrd is
  # never loaded, so don't spend a build on it.
  boot.initrd.enable = false;

  # The real kernel command line lives in the Android bundle; nothing to
  # add here.
  boot.kernelParams = [ ];

  ##################################
  # Root + vendor partition mounts #
  ##################################

  # Labelled so ../scripts/build-real-root-initramfs.sh's /init finds it
  # whether it lives on the microSD partition or on `userdata`.
  fileSystems."/" = {
    device = "/dev/disk/by-label/X716B_ROOT";
    fsType = "ext4";
    autoResize = true;
  };
  boot.growPartition = true;

  # mnt-vendor-persist.mount: normal rw mount, sensor + Wi-Fi calibration.
  fileSystems."/mnt/vendor/persist" = {
    device = "/dev/disk/by-partlabel/persist";
    fsType = "ext4";
    options = [ "rw" "nosuid" "nodev" "noexec" "nofail" "x-systemd.device-timeout=5s" ];
  };

  # vendor-dsp.mount / vendor-firmware_mnt.mount: DefaultDependencies=no,
  # ro, only unmounted at shutdown. Kept as raw units to preserve that.
  # The preset only ever enabled these three partition mounts; the full
  # /vendor erofs needs a dynamic-partition mapper this port has not
  # implemented.
  systemd.mounts = [
    {
      description = "Stock DSP libraries partition";
      what = "/dev/disk/by-partlabel/dsp";
      where = "/vendor/dsp";
      type = "ext4";
      options = "ro";
      unitConfig = { DefaultDependencies = "no"; Conflicts = "umount.target"; Before = "umount.target"; };
      wantedBy = [ "multi-user.target" ];
    }
    {
      description = "Stock modem/DSP firmware partition (apnhlos)";
      what = "/dev/disk/by-partlabel/apnhlos";
      where = "/vendor/firmware_mnt";
      type = "vfat";
      options = "ro";
      unitConfig = { DefaultDependencies = "no"; Conflicts = "umount.target"; Before = "umount.target"; };
      wantedBy = [ "multi-user.target" ];
    }
  ];

  #############################################################
  # Packages that ship their own systemd units / udev / dbus  #
  #############################################################

  systemd.packages = [ x.hexagonrpcd x.pd-mapper x.iio-sensor-proxy-ssc ];
  services.udev.packages = [ x.udevRules x.hexagonrpcd x.iio-sensor-proxy-ssc ];

  environment.systemPackages = [
    x.libssc            # ssccli
    x.pd-mapper
    x.hexagonrpcd
    x.iio-sensor-proxy-ssc
    x.hexagonfs
  ];

  # Vendor firmware blobs (WiFi/BT/GPU/ADSP + PDR registry + AudioReach
  # topology), merged into one /lib/firmware search tree.
  hardware.firmware = [ pkgs.x716b.firmware ];
  hardware.enableRedistributableFirmware = true;

  # ALSA UCM2: nixpkgs' tree + the GTS9 configs from overlay-common,
  # merged in x716b.ucm. Set for services and login sessions both;
  # gts9wifi-audio-init.service (below) is the belt-and-suspenders
  # BootSequence trigger on top.
  environment.variables.ALSA_CONFIG_UCM2 = "${x.ucm}/share/alsa/ucm2";
  environment.sessionVariables.ALSA_CONFIG_UCM2 = "${x.ucm}/share/alsa/ucm2";

  # Compat symlink so userspace tools that scan the FHS /lib/firmware
  # path directly (not via the kernel's request_firmware(), which finds
  # hardware.firmware fine on its own) -- e.g. pd-mapper's PDR .jsn scan
  # -- see something instead of nothing. NixOS ships no /lib at all.
  systemd.tmpfiles.rules = [
    "d /lib 0755 root root -"
    "L+ /lib/firmware - - - - /run/current-system/firmware"
  ];

  ##############################################
  # Device RAM/storage constraints and quirks  #
  ##############################################

  # zram-generator.conf: zram-size = ram. This tablet is RAM-constrained;
  # lower memoryPercent in ./configuration.nix if you'd rather trade swap
  # for flash wear.
  zramSwap = { enable = true; memoryPercent = 100; };

  # 10-gts9wifi-journal-cap.conf -- a long debug session must not fill the
  # rootfs and crash the display manager.
  services.journald.extraConfig = ''
    SystemMaxUse=64M
    RuntimeMaxUse=32M
    SystemMaxFileSize=16M
  '';

  # 10-gts9wifi-lid.conf -- the book cover is a direct SW_LID; no docking
  # topology, so no holdoff.
  services.logind.settings.Login = {
    HandleLidSwitch = "suspend";
    HandleLidSwitchExternalPower = "suspend";
    HandleLidSwitchDocked = "suspend";
    HoldoffTimeoutSec = 0;
  };

  # gts9wifi-chronyd.service is a full vendor-unit override whose only
  # reason to exist is that namespaced sandboxing fails on this kernel
  # (226/NAMESPACE). NixOS ships its own chronyd (enabled in
  # ./configuration.nix); strip the sandbox off it here instead of
  # porting the override wholesale.
  #
  # CapabilityBoundingSet is special: unlike RestrictAddressFamilies/
  # SystemCallFilter (where an empty assignment means "no restriction"),
  # an empty CapabilityBoundingSet= means the OPPOSITE -- the empty
  # capability set, i.e. deny everything. Confirmed live: `mkForce ""`
  # here made chronyd fail chown()'ing /run/chrony with "Operation not
  # permitted" even as root. `~` is systemd's "full set" token.
  systemd.services.chronyd.serviceConfig = {
    PrivateTmp = lib.mkForce false;
    ProtectHome = lib.mkForce false;
    ProtectSystem = lib.mkForce false;
    PrivateDevices = lib.mkForce false;
    RestrictNamespaces = lib.mkForce false;
    RestrictAddressFamilies = lib.mkForce "";
    SystemCallFilter = lib.mkForce "";
    CapabilityBoundingSet = lib.mkForce "~";
  };

  # The kernel lacks a netfilter match ("Extension pkttype revision 0 not
  # supported, missing kernel module?") nixos-fw's default ruleset needs
  # -- confirmed live, firewall.service fails outright rather than
  # degrading. Needs CONFIG_NETFILTER_XT_MATCH_PKTTYPE in
  # kernel/config/config-x716.fragment + a kernel rebuild (tracked as a
  # follow-up, not done here). Override `networking.firewall.enable` in
  # ./configuration.nix once that lands, or sooner if you've rebuilt the
  # kernel yourself.
  networking.firewall.enable = lib.mkDefault false;

  # Serial console fallback on the USB gadget tty. NOT systemd's
  # serial-getty@.service template: it carries BindsTo=dev-ttyGS0.device,
  # never satisfied for this gadget tty (the Fedora build documents the
  # same dead-getty symptom) -- a plain unit with no device dependency.
  systemd.services."x716b-serial-getty" = {
    description = "Serial getty on ttyGS0 (USB gadget console, no device-unit dependency)";
    after = [ "multi-user.target" ];
    wantedBy = [ "multi-user.target" ];
    # The USB gadget composite function in use right now is network-only
    # (RNDIS/ECM) -- no /dev/ttyGS0 -- confirmed live: agetty exits
    # 208/STDIN opening a path that doesn't exist, restart-loops to
    # start-limit-hit. Skip cleanly instead; this is a console fallback,
    # not load-bearing now that SSH is the primary channel.
    unitConfig.ConditionPathExists = "/dev/ttyGS0";
    serviceConfig = {
      ExecStart = "-${pkgs.util-linux}/sbin/agetty --keep-baud 115200 ttyGS0 $TERM";
      Type = "idle";
      Restart = "always";
      RestartSec = 1;
      StandardInput = "tty";
      StandardOutput = "tty";
      TTYPath = "/dev/ttyGS0";
      TTYReset = true;
      TTYVHangup = true;
    };
  };

  ####################################################
  # Ported gts9wifi-* services (85-gts9wifi.preset)  #
  ####################################################

  systemd.services = {

    # --- enabled by the preset ---

    gts9wifi-usb-net = oneshot {
      desc = "Static USB gadget network for gts9wifi debug access";
      exec = "${lx}/gts9wifi-usb-gadget";
      unitExtra = { after = [ "NetworkManager.service" ]; wants = [ "NetworkManager.service" ]; };
    };

    gts9wifi-wifi-recover = oneshot {
      desc = "Recover the WCN Wi-Fi endpoint when power-on raced the PCIe scan";
      exec = "${lx}/gts9wifi-wifi-recover";
      extra.serviceConfig = { RemainAfterExit = lib.mkForce false; TimeoutStartSec = 120; };
    };

    # Both of these call bare `mount` (and bt-provision also `fdtget`/
    # `fdtput`) -- not on a systemd service's default PATH (confirmed
    # live: "mount: command not found" / FileNotFoundError). `path`
    # below is how NixOS services ask for extra PATH entries.
    gts9wifi-bt-provision = oneshot {
      desc = "Provision the native Samsung Bluetooth address into the boot DTBs";
      exec = "${lx}/gts9wifi-bt-provision";
      extra = {
        serviceConfig.RemainAfterExit = lib.mkForce false;
        path = [ pkgs.util-linux pkgs.dtc ];
      };
    };

    gts9wifi-sensor-registry-perms = oneshot {
      desc = "Make the Samsung sensor registry writable for hexagonrpcd";
      exec = "${lx}/gts9wifi-sensor-registry-perms";
      extra.path = [ pkgs.util-linux ];
      unitExtra = {
        requires = [ "mnt-vendor-persist.mount" ];
        after = [ "mnt-vendor-persist.mount" ];
        before = [ "hexagonrpcd-adsp-sensorspd.service" ];
      };
    };

    gts9wifi-audio-init = oneshot {
      desc = "Apply mixer routing/volume the sound card needs for audible output";
      exec = "${lx}/gts9wifi-audio-init";
      unitExtra.after = [ "sound.target" ];
    };

    gts9wifi-panel-coldboot-recover = oneshot {
      desc = "Recover the panel after a cold boot";
      exec = "${lx}/gts9wifi-panel-coldboot-recover";
      wantedBy = [ "graphical.target" ];
      unitExtra = {
        after = [ "local-fs.target" ];
        before = [ "display-manager.service" ];
        unitConfig.ConditionPathExists = "/sys/power/pm_test";
      };
      extra.serviceConfig = { ExecStartPre = "${pkgs.coreutils}/bin/sleep 2"; TimeoutStartSec = 30; };
    };

    gts9wifi-wait-sensor-proxy = oneshot {
      desc = "Recover Qualcomm SSC and start the desktop sensor proxy";
      exec = "${lx}/gts9wifi-sensors-resume";
      unitExtra = {
        after = [ "gts9wifi-panel-coldboot-recover.service" "hexagonrpcd-adsp-sensorspd.service" ];
        before = [ "display-manager.service" ];
      };
      extra.serviceConfig = { ExecStartPre = "${pkgs.coreutils}/bin/sleep 2"; TimeoutStartSec = 210; };
    };

    # --- manual-start (NOT in the preset enable list) ---

    gts9wifi-adsp-boot = {
      description = "Boot the ADSP remoteproc once the rootfs firmware is reachable";
      wantedBy = [ ]; # manual: the ADSP start can hang / reset the SoC
      after = [ "local-fs.target" "gts9wifi-panel-coldboot-recover.service" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        TimeoutStartSec = 45;
        ExecStartPre = "${pkgs.coreutils}/bin/sleep 25";
        ExecStart = "${pkgs.runtimeShell} -c \"grep -q running /sys/class/remoteproc/remoteproc0/state || echo start > /sys/class/remoteproc/remoteproc0/state\"";
        # remoteproc start returns before fastrpc probes; wait for it.
        ExecStartPost = "${pkgs.runtimeShell} -c 'i=0; while [ $i -lt 60 ] && [ ! -e /dev/fastrpc-adsp ]; do ${pkgs.coreutils}/bin/sleep 1; i=$((i+1)); done'";
      };
    };

    gts9wifi-bt-revive = {
      description = "Revive the WCN6855 Bluetooth controller after a power sequencer cycle";
      wantedBy = [ ]; # manual: run when hci0 has disappeared
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${lx}/gts9wifi-bt-revive";
        TimeoutStartSec = 120;
      };
    };

    # --- drop-ins onto package-provided units ---

    # hexagonrpcd-adsp-rootpd: enabled; must wait for the ADSP.
    hexagonrpcd-adsp-rootpd = {
      wantedBy = [ "multi-user.target" ];
      after = [ "gts9wifi-adsp-boot.service" ];
    };

    # hexagonrpcd-adsp-sensorspd: manual; Samsung -R path; no crash loop.
    #
    # ExecStart as a *list* with a leading "" is required, not
    # `lib.mkForce "<cmd>"` -- the base unit (from systemd.packages)
    # already has its own ExecStart=, and a drop-in ExecStart= line
    # without first emptying it APPENDS a second command rather than
    # replacing the first. Two ExecStart= lines on a Type=simple service
    # (no Type= here means simple) is invalid and systemd refused the
    # whole unit with "has a bad unit file setting" (confirmed live).
    # The leading "" emits a reset line before the real command.
    hexagonrpcd-adsp-sensorspd = {
      wantedBy = lib.mkForce [ ];
      requires = [ "gts9wifi-adsp-boot.service" ];
      after = [ "gts9wifi-adsp-boot.service" "pd-mapper.service" ];
      serviceConfig = {
        ExecStart = [ "" "${x.hexagonrpcd}/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s -R ${x.hexagonfs}/share/qcom/sm8550/Samsung/gts9-5g" ];
        Restart = lib.mkForce "no";
      };
    };

    pd-mapper.wantedBy = [ "multi-user.target" ];
  };

  system.stateVersion = "26.05";
}
