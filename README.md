# Restoring a Photon to factory clean state

> **See also [CLAUDE.md](CLAUDE.md)** for terse operational notes, the listening-mode
> serial protocol, LED-state table, and the USB/CDC gotchas hit while doing this for real.

## Taking ownership of a Photon owned by another account (CLI 3.x)

The instructions further down ("Resetting ownership (from another user)") were written for
the phone app and the old CLI. **`particle setup` was removed in CLI 3.x**, and
`particle device add` only sends an *email transfer request* the old owner must approve —
it cannot force-claim. The phone app can still take ownership in close proximity, but if you
want to do it from the CLI, reproduce what `setup` used to do by hand. This is the legitimate
Gen2 "physical-possession" takeover — **no email, no old-owner approval**:

1. **Generate a claim code on your account** (your token is in `~/.particle/particle.config.json`):
   ```bash
   TOKEN=$(grep -o '"access_token": *"[^"]*"' ~/.particle/particle.config.json | sed 's/.*"access_token": *"//;s/"//')
   curl -s -X POST "https://api.particle.io/v1/device_claims" -d "access_token=$TOKEN"
   # -> {"claim_code":"<63-char code>", ...}
   ```
2. Put the Photon in **listening mode** (hold SETUP until blinking blue).
3. **Push the claim code over serial** (9600 baud): write `C`, wait for
   `Enter 63-digit claim code:`, then send the 63-char code + newline. The device replies
   `Claim code set to: <code>`. (See CLAUDE.md for a ready-to-run PowerShell snippet — send the
   code char-by-char or the USB serial port tends to drop.)
4. **Set Wi-Fi** (Photon is 2.4 GHz only):
   ```bash
   particle serial wifi --port COM26 --file wifi.json
   # wifi.json: {"network":"SSID","security":"WPA2_AES","password":"..."}
   ```
5. **Reset** so it reconnects: `particle usb reset <deviceID>`. When it reaches the cloud
   (breathing cyan) it presents the claim code and **ownership transfers to you**.
6. Verify and rename:
   ```bash
   particle list | grep <deviceID>
   particle device rename <deviceID> <NewName>
   ```

**Gotcha:** the transfer only completes once the device is actually cloud-connected
(breathing cyan). If it's *breathing green* (Wi-Fi OK, cloud handshake failing), fix the keys
first — see "Resetting keys" below — or the claim never lands. And note that clearing the DCT
claim code (next section) does **not** unclaim it on the cloud; it only wipes the device's
local copy, so don't clear it *after* you've set your own code.

### Scripted: `claim-photon.bat`

The steps above are automated in **`claim-photon.bat`** (Windows). It updates Device OS
(optional), sets Wi-Fi, generates + pushes a claim code, then resets, verifies, and renames:

```bat
copy .env.example .env       :: then edit WIFI_SSID / WIFI_PASSWORD / COM_PORT
claim-photon.bat
```

`.env` (gitignored) holds the Wi-Fi settings and options:

```
WIFI_SSID=YourNetwork
WIFI_PASSWORD=yourpassword
WIFI_SECURITY=WPA2_AES
COM_PORT=COM26
DEVICE_ID=            # optional, auto-detected from COM_PORT
DEVICE_NAME=          # optional, renames after a successful claim
SKIP_UPDATE=          # optional, set to 1 to skip the Device OS update step
```

If `COM_PORT` is left blank, the script first runs **device discovery** (`select-device.ps1`)
and shows every connected device with its ID, cloud name, Device OS version, and online
status, letting you pick which to work with (a single device is auto-selected):

```
  #  Port   Device ID                  Name                         OS         Status
  1  COM16  3c0025001947333438373833   garage-door-lights           3.3.1      online
  2  COM26  330041000d47353136383631   Automatica-Particle-IR       3.3.1      online
  3  COM27  440027001447353136383631   (not in your account)        ?          -
```

The batch then prompts you to put the device into the right LED mode between steps
(blinking yellow for the update, blinking blue for Wi-Fi + claim). The actual claim-code
serial push is done by the companion **`send-claim-code.ps1`** (pure batch can't do reliable
serial I/O). See [CLAUDE.md](CLAUDE.md) for the protocol details and a real worked example.

> **Verified:** `claim-photon.bat` claimed a Photon (`440027001447…`) end-to-end in a single
> run — discovery menu → claim code → Wi-Fi → online and claimed.
>
> **Real run (2026-06-14):** first did this flow by hand to take a Photon
> (`330041000d47…`) off an old account onto the current one. The one snag worth knowing:
> if the device goes *breathing green* after Wi-Fi setup, the claim code never reaches the
> cloud — fix connectivity (keys) first; the transfer only completes at breathing cyan.
> And clearing the DCT claim code does **not** unclaim on the cloud, so don't wipe it after
> you've set your own code.

## Resetting settings

Run this program to reset the antenna, IP configuration, Wi-Fi credentials and EEPROM:

```
#include "Particle.h"

STARTUP(WiFi.selectAntenna(ANT_INTERNAL));

void setup() {
    EEPROM.clear();

    WiFi.useDynamicIP();
    WiFi.clearCredentials();

    // So you can tell the operations have completed
    pinMode(D7, OUTPUT);
    digitalWrite(D7, HIGH);
}

void loop() {
}
```

One way to do this is to download the [resetsettings.ino](https://github.com/rickkas7/photonreset/blob/master/resetsettings.ino?raw=true) file. 

Put the Photon in DFU mode (blinking yellow), by pressing RESET and SETUP, releasing RESET and continuing to hold down SETUP while it blinks magenta until it blinks yellow, then release. 

Then run the commands:

```
particle compile photon --target 0.4.9 resetsettings.ino --saveTo resetsettings.bin
particle flash --usb resetsettings.bin
```

In many cases, it's sufficient to just clear the Wi-Fi credentials by holding down SETUP until it blinks blue, then keep holding it down until it blinks blue rapidly, about 10 more seconds.

## Resetting firmware

Put the device in DFU mode (blinking yellow) and flash Tinker.

```
particle flash --usb tinker
```

If you want to set the system firmware back to the factory default of 0.4.9 (optional):

Download [system-part1-0.4.9-photon.bin](https://github.com/spark/firmware/releases/download/v0.4.9-rc.3/system-part1-0.4.9-photon.bin) and [system-part2-0.4.9-photon.bin](https://github.com/spark/firmware/releases/download/v0.4.9-rc.3/system-part2-0.4.9-photon.bin) from the [github release site](https://github.com/spark/firmware/releases/tag/v0.4.9-rc.3).

Put the Photon in DFU mode and issue the commands:

```
particle flash --usb system-part1-0.4.9-photon.bin
particle flash --usb system-part2-0.4.9-photon.bin
```

## Resetting ownership (from your own account)

Unclaim the device from your account. If the device is claimed to your account you can use the command line, the Particle Build (Web IDE). Here’s the command line version (insert your device ID):

```
particle device remove 0123456789abcdef123
```

If you don't know your device ID, hold down the SETUP button until it blinks blue (if not already blinking blue) and use the command:

```
particle identify
```

## Resetting ownership (from another user)

If the device was used in a classroom or hackathon situation, you may want to restore ownership without having to email the (temporary) owner. You can do this using the Particle phone apps.

With Photons only (not Core or Electron), you have the ability to take ownership in close proximity, as long as the device was not part of a product creator product. If it was part of a product, it must first be removed from a product from the [product console](https://console.particle.io) for security reasons.

Put the Photon in listening mode (blinking blue) if it is not already in that state. Hold down the SETUP button until the Photon blinks blue, then release.

Now use the iOS or Android Particle app to add the device to your account. You will be prompted that it is owned by someone else, but you should be able to take ownership immediately if you say Yes.

If you use the CLI instead of the phone app, a different process is used that sends an email to the owner. This is because the CLI method can be invoked from anywhere on the Internet, whereas the phone app in listening mode requires that you have the device in your possession and be able to press the SETUP button to enter listening mode.

After successfully taking ownership of the device you can then unclaim it from your account. 

## Resetting keys (optional)

Reset server key in case it was changed to a local server:

While still in DFU mode:

```
particle keys server
```

Generate new keys:

```
particle keys new
particle keys load device.der
```

## Resetting the claim code (optional)

The part that is often missed is clearing the claim code. You need a file that’s 64 bytes long and consists of 0xff bytes, except for the first byte, which is 0x00, most easily done by downloading [clear_claim.bin](https://github.com/rickkas7/photonreset/blob/master/clear_claim.bin?raw=true).

Then you flash this to the device in DFU mode:

```
dfu-util -d 2b04:d006 -a 1 -s 1762:64 -D clear_claim.bin
```

Be very careful with that command, typing one wrong number can cause massive headaches by corrupting the configuration! That’s the step that’s necessary to prevent the phone app from saying that the device has already been registered. 

If you skip this step, users can still claim the device, but they'll get a warning that it has been claimed, even though it's no longer claimed, when using the phone apps.

Now reset your device and you should be able to claim it with a different user with no warnings, as if it was fresh from the factory.

