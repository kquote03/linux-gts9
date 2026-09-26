# Ordered patch list for a component, read from its specs/<component>/series
# file -- the same file scripts/lib/downstream.sh (Fedora/Debian builders, kernel
# build) consumes, so a patch added to a series reaches every distro at once.
# See docs/downstream-patches.md.
#
#   seriesPatches (specsSrc + "/libcamera-x716b")  ->  [ <path> <path> ... ]
{ lib }:
dir:
let
  clean = line: lib.strings.trim (builtins.head (lib.splitString "#" line));
  names = lib.filter (l: l != "") (map clean (lib.splitString "\n" (builtins.readFile (dir + "/series"))));
in
map (n: dir + "/patches/${n}") names
