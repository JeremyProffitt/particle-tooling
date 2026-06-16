# CLAUDE.md — Particle Photon tooling notes

Operational knowledge for working with Particle **Gen2 Photons** from the CLI on Windows.
Written after force-claiming a Photon that was owned by another account, without the
old owner's approval and without the email-transfer flow.

## TL;DR — force-claim a Photon you physically possess (CLI 3.x)

`particle device add` can NOT take a device owned by another account — it only sends an
email transfer request the old owner must approve. The old `particle setup` command
(which *could* force-claim) was **removed in CLI 3.x**. But the underlying mechanism
still works; reproduce it by hand:

1. **Generate a claim code on YOUR account** (token lives in `~/.particle/particle.config.json`):
   ```bash
   TOKEN=$(grep -o '"access_token": *"[^"]*"' ~/.particle/particle.config.json | sed 's/.*"access_token": *"//;s/"//')
   curl -s -X POST "https://api.particle.io/v1/device_claims" -d "access_token=$TOKEN"
   # -> {"claim_code":"<63 chars>", "device_ids":[...already-owned...]}
   ```
2. **Listening mode**: hold SETUP ~3s until the LED is **blinking blue**.
3. **Push the claim code over serial** (9600 baud). Write `C`, wait for the
   `Enter 63-digit claim code:` prompt, then send the 63-char code + `\n`.
   The device echoes `Claim code set to: <code>`.
4. **Set Wi-Fi** (Photon = 2.4 GHz only):
   ```bash
   particle serial wifi --port COM26 --file wifi.json
   # wifi.json: {"network":"SSID","security":"WPA2_AES","password":"..."}
   ```
5. **Reset** so it reconnects: `particle usb reset <deviceID>`.
   On cloud connect it presents the claim code and **the cloud transfers ownership to you** —
   no email, no old-owner approval.
6. **Verify / rename**:
   ```bash
   particle list | grep <deviceID>
   particle device rename <deviceID> <NewName>
   ```

The iOS/Android Particle app does this same "close-proximity takeover" automatically.
The CLI route is manual only because `setup` was deleted.

## Listening-mode serial protocol (9600 baud, device blinking blue)

Single-character commands the device answers in listening mode:

| char | action                                                              |
|------|---------------------------------------------------------------------|
| `i`  | device info JSON (`platform`, `sysVersion`, `deviceId`)              |
| `m`  | MAC address                                                          |
| `s`  | system/module info                                                  |
| `C`  | set claim code — prompts `Enter 63-digit claim code:`, send code+`\n`|
| `w`  | set Wi-Fi — interactive SSID/security/password prompts              |

`c` (lowercase) was also accepted on Device OS 3.3.1 and reported `Device claimed: yes`,
but the documented/CLI protocol is uppercase **`C`** with the prompt handshake — prefer it.

### USB CDC reliability gotcha
Writing the whole 63-char claim code in one `SerialPort.Write` repeatedly dropped the port
("The port is closed" / "The semaphore timeout period has expired"). **Send the code
char-by-char with ~5 ms delays**, then the newline. Raw serial via PowerShell is more
reliable than fighting the CLI when the port is flaky:

```powershell
$port = New-Object System.IO.Ports.SerialPort('COM26',9600,'None',8,'one')
$port.Open(); Start-Sleep -Milliseconds 400; $port.DiscardInBuffer()
$port.Write("C"); Start-Sleep -Milliseconds 800
$port.ReadExisting()                                  # "Enter 63-digit claim code: "
foreach ($ch in $code.ToCharArray()) { $port.Write([string]$ch); Start-Sleep -Milliseconds 5 }
$port.Write("`n"); Start-Sleep -Milliseconds 1500
$port.ReadExisting()                                  # "Claim code set to: ..."
$port.Close()
```

## LED states (Photon)

| LED               | meaning                                                        |
|-------------------|----------------------------------------------------------------|
| Blinking blue     | listening mode (ready for serial config)                       |
| Blinking yellow   | DFU mode (ready for dfu-util)                                   |
| Breathing cyan    | **fully cloud-connected — success**                            |
| Breathing green   | on Wi-Fi but cloud handshake failing → keys/server-key issue   |
| Blinking green    | can't join Wi-Fi (wrong password / 5 GHz / hidden)             |

**Critical:** the claim only completes when the device actually reaches the cloud
(breathing cyan). If it's breathing green, fix connectivity FIRST (`particle keys doctor`
/ `particle keys server` in DFU mode) — the ownership transfer never happens otherwise.
We lost a cycle because the device went breathing-green right after the claim code was set,
so the code never reached the cloud.

## DCT claim-code region (dfu-util)

USB id for Photon DFU: **`2b04:d006`**. dfu-util on this machine: `C:\WINDOWS\dfu-util` (0.9).

- alt **1** = `@DCT Flash`, alt 0 = `@Internal Flash`.
- Claim code lives at **offset 1762**, `claim_code[63]`, with the `claimed` flag at 1825.

Clear the stored claim code (prevents the phone app's "already registered" warning):
```bash
dfu-util -d 2b04:d006 -a 1 -s 1762:64 -D clear_claim.bin
```
`clear_claim.bin` = 64 bytes: first byte `0x00`, remaining 63 `0xFF` (all-`0xFF` also works).
The "Invalid DFU suffix signature" warning is harmless.

**Clearing the DCT claim code does NOT change cloud ownership** — it only wipes the device's
local copy. Don't clear it *after* setting your own claim code unless you mean to start over
(we did this by mistake and had to re-inject).

## Mode entry (physical buttons)

- **Listening mode**: hold SETUP ~3s → blinking blue.
- **DFU mode**: hold SETUP+RESET, release RESET while holding SETUP, keep holding through
  magenta until **blinking yellow**, then release.
- `particle usb start-listening <id>` / `particle usb dfu <id>` can do this over USB, but the
  USB control request **times out if the device is busy** (e.g. mid-connect). Physical buttons
  are the reliable fallback.
- **The COM port changes when the device enters/leaves listening mode** — it re-enumerates as
  a different `COMxx`. A port captured during discovery (running mode) is stale by the time the
  device is blinking blue. Always re-detect the port from `particle serial list` *after* the
  device is in listening mode, keyed off the stable **device ID** (which never changes).
  `claim-photon.bat` does exactly this; an early version trusted the discovery-time port and
  failed with `The port 'COMxx' does not exist.`

## Handy commands

```bash
particle whoami                       # confirm logged-in account
particle serial list                  # COM ports + device IDs over USB
particle serial identify --port COMxx # device ID via serial
particle serial inspect --port COMxx  # bootloader/system module versions
particle usb reset <id>               # reboot out of listening/DFU
particle list | grep <id>             # is it in my account / online?
particle keys doctor <id>             # regen + sync keys (DFU mode) — fixes breathing green
particle keys server                  # restore Particle cloud server key (DFU mode)
```

## Scripted workflow

`claim-photon.bat` is a thin launcher: it confirms login, loads `.env` (exporting the keys as
environment variables), and hands off to **`photon-manager.ps1`**, the menu-driven orchestrator.

1. `copy .env.example .env` and fill in `WIFI_SSID` / `WIFI_PASSWORD`
   (optionally `WIFI_SECURITY`, `DEVICE_NAME`, `DEVICE_ID`, `SKIP_UPDATE`). `.env` is gitignored.
   Leave `DEVICE_ID` blank to get the menu; set it to claim one specific device and skip the menu.
2. Run `claim-photon.bat`. It prints an inventory of **every** device on USB and a menu.

**Inventory** comes from `particle usb list` — the only command that sees a device in **DFU
mode** (a DFU device has no serial interface, so `particle serial list` misses it). Each device
shows its **mode** (`LISTENING` / `DFU` / `running`), COM port (if on serial), ID, and account
status. Ownership is cross-referenced against `GET /v1/devices`; the COM port for claims comes
from `particle serial list`. Only **claimable** Photons (Gen2, not already in your account) get a
selection number — devices you already own and non-Photons (e.g. a Gen3 Tracker) are listed but
**locked out** of claiming.

**Menu actions:**
- **AUTO** — *the default (just press Enter)*. Updates Device OS on **every device in DFU mode**
  and claims **every unclaimed device in listening mode**, keyed off each device's *current* LED
  mode. Devices that aren't in DFU or listening are left alone. (A device updated this run reboots
  out of DFU; put it in listening mode and run AUTO again to claim it.)
- **C** — claim **all** claimable devices (best-effort `start-listening` for ones not already
  blinking blue).
- **U** — update Device OS on **all** connected Photons (`particle update <id>` targets each by ID).
- **`<#>`** — claim a single device by its number.

**Order matters:** for each claim the manager pushes the **claim code first, then Wi-Fi** — both in
one listening-mode session. Setting Wi-Fi restarts the Photon; it then reconnects presenting the
stored claim code, and the cloud transfers ownership. Doing Wi-Fi first would restart the device
out of listening mode before the claim code could be set (a real bug we hit). No separate
`usb reset` is needed; the Wi-Fi step is what restarts it. After claiming, the manager polls
`particle list` (~90 s) and reports each device online, renaming a single claimed device if
`DEVICE_NAME` is set.

`photon-manager.ps1` can also run non-interactively: `-Action auto|claimall|updateall`. It reads
Wi-Fi/options from the same `$env:WIFI_*` / `$env:DEVICE_*` / `$env:SKIP_UPDATE` variables the
batch exports. (It replaces the old `select-device.ps1`, whose enrich/select role is folded in.)

`send-claim-code.ps1` is the helper the manager calls for the claim push — pure-batch can't do raw
serial reliably. It reads the access token from the CLI config, asks the cloud for a claim
code, and pushes it with the `C`/prompt protocol (char-by-char). It now **retries the whole
push up to 3 times** (`-Retries`), guards every serial write, and re-opens the port to verify
rather than hard-failing when the flaky USB CDC port drops right after the send. Listening-mode
detection accepts BOTH the JSON `i` reply (`deviceId`, older Device OS) and the plain
`Your device id is <id>` reply (current Device OS) — the old check only matched `deviceId`, so
it warned on every modern device even when listening mode was fine, and `exit 2` on a transient
drop made the batch abort a claim that had actually succeeded. Can be run standalone:
`powershell -NoProfile -ExecutionPolicy Bypass -File .\send-claim-code.ps1 -Port COM26`.

`photon-manager.ps1` tries `particle usb start-listening <id>` automatically (best-effort) for any
device it needs to claim that isn't already blinking blue, so a device still running its app
(breathing cyan, serial answering with a "semaphore timeout") gets flipped into listening mode
without touching the button. The SETUP button remains the fallback when the USB request times out
mid-connect — put the device in listening mode by hand and re-run.

## Worked example — claiming a Photon owned by another account (2026-06-14)

Device `330041000d47353136383631`, a Photon already claimed to a *different* account
(its serial suffix matched a whole batch of Jeremy's other Photons — almost certainly an
old account of his). End-to-end, what actually worked:

1. `particle device add <id>` → "That device belongs to someone else" (email-transfer only). Dead end.
2. Generated a claim code via `POST /v1/device_claims`, put the device in listening mode,
   pushed the code over serial. **First try went breathing green** (Wi-Fi OK, cloud handshake
   failing) so the claim code never reached the cloud and ownership didn't move.
3. Cleared the DCT claim code with `dfu-util ... -a 1 -s 1762:64 -D clear_claim.bin`, reset.
   This time it came up **breathing cyan** — but with the claim code now wiped, so it just
   reconnected as the old owner's device. (Lesson: clearing the DCT does NOT unclaim on the
   cloud; only do it when starting over, not after setting your own code.)
4. **Re-injected a fresh claim code** with the documented uppercase `C` protocol while the
   device was healthy (got `Claim code set to: ...`), `particle usb reset`, and within a
   minute `particle list` showed it online **under our account**.
5. `particle device rename <id> Automatica-Particle-IR`. Done.

Net: the only path that force-claims a Gen2 device from the CLI is the claim-code-over-serial
flow, and it only completes once the device actually reaches breathing cyan.

A **second Photon** (`440027001447353136383631`, also a different account, same batch) was
then claimed **end-to-end with `claim-photon.bat`**, which validated the scripted flow — and
surfaced two bugs since fixed: the batch must push the **claim code before Wi-Fi** (Wi-Fi
restarts the device out of listening mode), and the device-resolution block had to be
flattened (a nested `if`/`for` was dropping `COM_PORT`, so an empty `-Port` reached the claim
step). With those fixed the script claims a device in one run.

## Worked example — claiming two more Photons + adoption fixes (2026-06-16)

Two unclaimed Photons (`3e0020000a47353137323334` → now `PVDXRDPQ`, and
`3b0029000a47353137323334` → now `QNHD7GHG`), both claimed to a *different* account (same
old-batch serial suffix `…47353137323334`), plus a Gen3 Asset Tracker/Monitor One on serial
(left alone — this tooling is Photon-only). Both Photons force-claimed cleanly with the
claim-code-over-serial flow; each appeared **online under our account within ~10 s** of the
Wi-Fi-triggered restart. What this run exposed about *adoption in listening mode*:

- **`3e00…` was already in listening mode** and `send-claim-code.ps1` printed the scary
  `Device did not return info JSON` warning even though the push succeeded — because current
  Device OS answers `i` with `Your device id is <id>`, not JSON with `deviceId`. Cosmetic, but
  it makes a working claim look broken. **Fixed:** detection now matches `device id is` too.
- **`3b00…` was running its app** (breathing cyan); serial writes failed with
  `The semaphore timeout period has expired` — the device won't accept the claim code until
  it's actually in listening mode. `particle usb start-listening <id>` flipped it without the
  SETUP button, after which the push worked. **Fixed:** `claim-photon.bat` now calls
  `start-listening` automatically before the manual button pause.
- **Real adoption-failure root cause:** the helper used to `exit 2` whenever it couldn't read
  back `Claim code set to`, which the flaky USB CDC port often drops *after* the code was
  already sent — making the batch `goto :fail` on a claim that had actually succeeded.
  **Fixed:** the push now retries up to 3×, guards every write, and re-opens to verify.

## Sources of Particle information

- **https://github.com/rickkas7** — Rick Kaseguma (long-time Particle community/SE). Tons of
  Photon/Boron/Argon examples, tutorials, and reset/claim tooling. The original
  `photonreset` repo (clear_claim.bin, resetsettings.ino) this repo is based on lives here.
- **https://github.com/particle-iot** — the official Particle org: `particle-cli`,
  `particle-api-js`, Device OS (`device-os`), docs, and the firmware that defines the
  listening-mode serial protocol and DCT layout referenced above.
