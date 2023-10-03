#!/bin/bash

# user must run "xcrun notarytool  store-credentials" once and use xLights as the profile name

VER=$1
shift

rm -f xLights-$VER.dmg
rm -f xLights.dmg

#build the final dmg
hdiutil create -size 192m -fs HFS+ -volname "xLights-$VER" xLights.dmg
hdiutil attach xLights.dmg

for var in "$@"
do
    if [ -e "$var" ]; then
        cp -a "$var" /Volumes/xLights-$VER
    fi
done
ln -s /Applications /Volumes/xLights-$VER/Applications

DEVS=$(hdiutil attach xLights.dmg | cut -f 1)
DEV=$(echo $DEVS | cut -f 1 -d ' ')
 
# Unmount the disk image
hdiutil detach $DEV
 
# Convert the disk image to read-only and compress
hdiutil convert xLights.dmg -format UDZO -o xLights-$VER.dmg

# Sign the DMG
codesign --force --sign "Developer ID Application: Daniel Kulp" xLights-$VER.dmg
spctl -a -t open --context context:primary-signature -v xLights-$VER.dmg

if [ "${NOTARIZE_PWD}x" != "x" ]; then
    # Now send the final DMG off to apple to notarize.  This DMG has the notarized .app's
    # so it's different than the previous DMG
    xcrun notarytool submit --keychain-profile "xLights" --wait  xLights-$VER.dmg

    # staple the DMG's notarization to the dmg
    xcrun stapler staple -v xLights-$VER.dmg
fi
