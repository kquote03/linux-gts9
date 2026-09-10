# SM-X716B device overlay, translated from rootfs/overlay-systemd/ +
# rootfs/overlay-common/ into idiomatic NixOS.
#
# Source of truth for ordering: each unit file's own comments (several
# encode hardware-ordering fixes found on real hardware). Source of truth
# for what auto-starts: rootfs/overlay-systemd/usr/lib/systemd/
# system-preset/85-gts9wifi.preset -- the ADSP chain
# (hexagonrpcd-adsp-sensorspd + gts9wifi-adsp-boot) is deliberately
# manual-start (its start can SSR / freeze the SoC).
{ config, lib, pkgs, ... }:

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
  ###################################################################
  # Packages that ship their own systemd units / udev rules / dbus  #
  ###################################################################

  systemd.packages = [ x.hexagonrpcd x.pd-mapper x.iio-sensor-proxy-ssc ];
  services.udev.packages = [ x.udevRules x.hexagonrpcd x.iio-sensor-proxy-ssc ];

  environment.systemPackages = [
    x.libssc            # ssccli
    x.pd-mapper
    x.hexagonrpcd
    x.iio-sensor-proxy-ssc
    x.hexagonfs
  ];

  ##########################
  # Vendor partition mounts #
  ##########################

  # mnt-vendor-persist.mount: normal rw mount, sensor + Wi-Fi calibration.
  fileSystems."/mnt/vendor/persist" = {
    device = "/dev/disk/by-partlabel/persist";
    fsType = "ext4";
    options = [ "rw" "nosuid" "nodev" "noexec" "nofail" "x-systemd.device-timeout=5s" ];
  };

  # vendor-dsp.mount / vendor-firmware_mnt.mount: DefaultDependencies=no,
  # ro, only unmounted at shutdown. Kept as raw units to preserve that.
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

  ##########################
  # zram / journald / lid  #
  ##########################

  # zram-generator.conf: zram-size = ram
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
  # (226/NAMESPACE). NixOS ships its own chronyd (services.chrony); strip
  # the sandbox off it instead of porting the override wholesale.
  systemd.services.chronyd.serviceConfig = {
    PrivateTmp = lib.mkForce false;
    ProtectHome = lib.mkForce false;
    ProtectSystem = lib.mkForce false;
    PrivateDevices = lib.mkForce false;
    RestrictNamespaces = lib.mkForce false;
    RestrictAddressFamilies = lib.mkForce "";
    SystemCallFilter = lib.mkForce "";
    CapabilityBoundingSet = lib.mkForce "";
  };

  # tmpfiles.d/gts9wifi-x11.conf
  systemd.tmpfiles.rules = [ "d /tmp/.X11-unix 1777 root root -" ];

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

    gts9wifi-bt-provision = oneshot {
      desc = "Provision the native Samsung Bluetooth address into the boot DTBs";
      exec = "${lx}/gts9wifi-bt-provision";
      extra.serviceConfig.RemainAfterExit = lib.mkForce false;
    };

    gts9wifi-sensor-registry-perms = oneshot {
      desc = "Make the Samsung sensor registry writable for hexagonrpcd";
      exec = "${lx}/gts9wifi-sensor-registry-perms";
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

    # x11-dir-fix: a *timer*, not a .path unit (the .path storms -- see
    # docs/porting-log.md). The oneshot only touches the inode when wrong.
    gts9wifi-x11-dir-fix = {
      description = "Re-assert root:root 1777 on /tmp/.X11-unix for XWayland ownership checks";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.runtimeShell} -c '[ \"$(${pkgs.coreutils}/bin/stat -c %U:%a /tmp/.X11-unix 2>/dev/null)\" = root:1777 ] || { ${pkgs.coreutils}/bin/chown root:root /tmp/.X11-unix && ${pkgs.coreutils}/bin/chmod 1777 /tmp/.X11-unix; }'";
      };
      startLimitIntervalSec = 60;
      startLimitBurst = 20;
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
    hexagonrpcd-adsp-sensorspd = {
      wantedBy = lib.mkForce [ ];
      requires = [ "gts9wifi-adsp-boot.service" ];
      after = [ "gts9wifi-adsp-boot.service" "pd-mapper.service" ];
      serviceConfig = {
        ExecStart = lib.mkForce "${x.hexagonrpcd}/bin/hexagonrpcd -f /dev/fastrpc-adsp -d adsp -s -R ${x.hexagonfs}/share/qcom/sm8550/Samsung/gts9-5g";
        Restart = lib.mkForce "no";
      };
    };

    pd-mapper.wantedBy = [ "multi-user.target" ];
  };

  systemd.timers.gts9wifi-x11-dir-fix = {
    description = "Periodically re-assert /tmp/.X11-unix ownership";
    wantedBy = [ "timers.target" ];
    timerConfig = { OnBootSec = "10s"; OnUnitActiveSec = "30s"; AccuracySec = "10s"; };
  };
}
