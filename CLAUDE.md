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
