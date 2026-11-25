# RE4 Remake ultrawide FOV snap fix

A REFramework Lua script for Resident Evil 4 (2023) that removes the camera
jump you get when closing the inventory or an item-pickup screen with
REFramework's ultrawide fix enabled. It also steadies the small FOV drift
around the map.

The jump is most visible at 32:9, where the ultrawide fix changes the camera
a lot. It was written and tested at 5120x1440.

## The problem

REFramework's **Ultrawide/FOV/Aspect Ratio Fix** widens the camera every
frame. RE4's inventory and pickup screens are built for the stock camera, so
REFramework pauses the fix while those screens are drawn, plus 100 ms after.

When such a screen closes, the camera is back in the game world immediately,
but the screen keeps fading out for 0.2 to 0.55 seconds. During that fade:

- the live game is drawn with the stock, zoomed-in camera, and
- on top of it the game fades out a frozen copy of the screen taken when the
  menu opened, which was captured with the wide camera.

So the picture cross-fades from wide to zoomed-in, then jumps back to wide
when the fix resumes. This is REFramework issue
[#1265](https://github.com/praydog/REFramework/issues/1265).

## What the script does

1. Applies the same wide camera REFramework would, as soon as the camera is
   back in the game world.
2. Enlarges the frozen screen copy (`AcBackGround`). The game places it as a
   quad in front of the camera, sized to fill the stock view; the script
   scales it to fill the wide view, so it still hides the scene settling
   after the camera cut and fades out as intended.
3. Skips the other camera-drawn menu panels during the fade (for example the
   grey smoke backdrop on pickups), which would otherwise shrink to a
   rectangle. Flat panels are untouched and fade normally.
4. Holds the FOV steady through the small nudges the game applies around
   menus and the map, and follows real FOV changes (aiming, sprinting) with
   a short glide.

It only acts when REFramework's ultrawide fix is enabled, and only around
menu and map transitions.

## Requirements

- Resident Evil 4 (2023) on PC.
- [REFramework](https://github.com/praydog/REFramework) with
  **Ultrawide/FOV/Aspect Ratio Fix** and **Ultrawide: Enable Vertical FOV**
  turned on, and **Ultrawide: Override FOV** off.

Tested with the game running on macOS through CrossOver (D3DMetal), using
the `realyxl/REFramework` fork, release `v0.2_beta`. It has not been tested
on Windows or with official REFramework builds.

## Install

Copy `reframework/autorun/uw_fov_snap_fix.lua` into the game folder at
`reframework/autorun/`, then restart the game or reset scripts from
REFramework's **ScriptRunner** section.

## Settings

Open the REFramework menu, then **Script Generated UI** and
**Ultrawide FOV snap fix**.

| Setting | Effect |
|---|---|
| Enabled (master switch) | When off, the script does nothing at all and you get plain REFramework behaviour. |
| Keep background during fade (resize it) | Enlarges the frozen screen copy. When off, the copy is skipped instead, which can show the scene settling. |
| Steady FOV when the map opens and closes | Holds the FOV steady around the map. |
| Diagnostics | Writes camera and GUI state to `re2_framework_log.txt` for troubleshooting. Off by default. |

Settings are saved to `reframework/data/uw_fov_snap_fix_v12.json`.

## Known limits

- On item pickups the grey smoke backdrop disappears at once instead of
  fading, because it is skipped rather than resized.
- Only the vertical-FOV mode of the ultrawide fix is handled.
- The panel names, the inventory scene position and the timings were
  measured on one game version and may need updating after a game patch.

## Uninstall

Delete `uw_fov_snap_fix.lua` from `reframework/autorun/`.
