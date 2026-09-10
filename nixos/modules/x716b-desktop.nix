# KDE Plasma 6 (Wayland) desktop, networking, users. Mirrors the Fedora
# build's GNOME-target choices: a real GPU-accelerated desktop, SSH on,
# NetworkManager, first-boot user x716b / password x716b (override with
# the flake's specialArgs if desired).
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

  # Touch-first device: ship the on-screen keyboard + rotation bits.
  environment.plasma6.excludePackages = [ ];
  environment.systemPackages = with pkgs; [
    kdePackages.plasma-nm
    kdePackages.plasma-pa
    kdePackages.kscreen
    maliit-keyboard
    vim
    git
    usbutils
    pciutils
    alsa-utils
    iw
  ];

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
  # gts9wifi-usb-net brings usb0 up with a static debug address; keep NM
  # from fighting it.
  networking.networkmanager.unmanaged = [ "interface-name:usb0" ];

  services.openssh = {
    enable = true;
    settings.PasswordAuthentication = true;
    settings.PermitRootLogin = "yes";
  };

  # Clock: gts9wifi-chronyd in the overlay; use the native option.
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
}
