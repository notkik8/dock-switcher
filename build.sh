#!/bin/bash
set -euo pipefail

cd -- "$(dirname -- "$0")"
project_dir=$(pwd)
output_dir="$project_dir/build"
app="$output_dir/Dock Switcher.app"
contents="$app/Contents"
icon_dir="$output_dir/AppIcon.iconset"

mkdir -p "$contents/MacOS" "$contents/Resources" "$icon_dir"
cp Info.plist "$contents/Info.plist"

for size in 16 32 128 256 512; do
    sips -z "$size" "$size" AppIcon.png --out "$icon_dir/icon_${size}x${size}.png" >/dev/null
    retina_size=$((size * 2))
    sips -z "$retina_size" "$retina_size" AppIcon.png --out "$icon_dir/icon_${size}x${size}@2x.png" >/dev/null
done
# An ICNS file contains a header followed by tagged, length-prefixed PNGs.
/usr/bin/perl - "$icon_dir" "$contents/Resources/AppIcon.icns" <<'PERL'
use strict;
use warnings;

my ($icon_dir, $destination) = @ARGV;
my @variants = (
    ['icp4', '16x16'], ['ic11', '16x16@2x'],
    ['icp5', '32x32'], ['ic12', '32x32@2x'],
    ['ic07', '128x128'], ['ic13', '128x128@2x'],
    ['ic08', '256x256'], ['ic14', '256x256@2x'],
    ['ic09', '512x512'], ['ic10', '512x512@2x'],
);
my $entries = '';
foreach my $variant (@variants) {
    my ($tag, $size) = @$variant;
    my $path = "$icon_dir/icon_$size.png";
    open my $image, '<:raw', $path or die "$path: $!";
    local $/;
    my $png = <$image>;
    $entries .= pack('a4N', $tag, 8 + length($png)) . $png;
}

open my $icon, '>:raw', $destination or die "$destination: $!";
print {$icon} pack('a4N', 'icns', 8 + length($entries)), $entries;
close $icon or die "$destination: $!";
PERL

xcrun swiftc -module-cache-path "$output_dir/ModuleCache" \
    -target "$(uname -m)-apple-macos13.0" DockSwitcher.swift -o "$contents/MacOS/DockSwitcher"
codesign --force --sign - "$app"
codesign --verify --strict "$app"
"$contents/MacOS/DockSwitcher" --self-test

archive="$output_dir/DockSwitcher.zip"
temporary_archive="$output_dir/.DockSwitcher-new.zip"
rm -f -- "$temporary_archive"
ditto -c -k --norsrc --noextattr --keepParent "$app" "$temporary_archive"
mv -f -- "$temporary_archive" "$archive"
printf 'App: %s\nZIP: %s\n' "$app" "$archive"
