# AGENTS.md

Setup guide for coding agents. Windows only. Read README.md only if you need the rationale.

## Files

- `CamOffload.ps1` – WinForms GUI (PowerShell 5.1). Paths/defaults at the top.
- `worker.ps1` – copy → encode → upload pipeline, started by the GUI on every Start.
- `build/Launcher.cs` – tiny `.exe` launcher (no console). `build/make_icon.ps1` – regenerates `CamOffload.ico`.
- Runtime (gitignored): `einstellungen.json`, `logs/`, `temp/`, `*.exe`.

## Setup

1. Check prerequisites; stop and tell the user if one fails:
   ```powershell
   $PSVersionTable.PSVersion.Major                                   # 5
   (Get-CimInstance Win32_VideoController).Name                      # needs an AMD Radeon
   ffmpeg -hide_banner -encoders | Select-String hevc_amf            # must list hevc_amf
   ffprobe -version | Select-Object -First 1
   ```
   Missing ffmpeg: suggest `winget install Gyan.FFmpeg` (ask before installing), then reopen the shell.
2. Smoke-test the encoder (any 10-bit or 8-bit video works as input):
   ```powershell
   ffmpeg -hide_banner -loglevel error -y -hwaccel d3d11va -t 3 -i IN.MP4 -map 0:v:0 -c:v hevc_amf -quality balanced -rc cqp -qp_i 33 -qp_p 33 -bf 0 -profile:v main10 -pix_fmt p010le "$env:TEMP\amf-test.mp4"
   ```
   Exit code 0 = OK. Delete the test file afterwards.
3. Ask the user for their backup and compressed destinations, then set `$BatchSrc` / `$BatchDst` at the top
   of `CamOffload.ps1`. Leave `$BatchState` empty (it only feeds the author's separate batch script).
4. Build the launcher (optional):
   ```powershell
   & "$env:WINDIR\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /win32icon:CamOffload.ico /r:System.Windows.Forms.dll /out:CamOffload.exe build\Launcher.cs
   ```
5. Verify the GUI loads without opening it interactively:
   ```powershell
   powershell -NoProfile -STA -ExecutionPolicy Bypass -File CamOffload.ps1 -SelfTest
   ```
   Prints `GUI OK -> …selftest.png`; delete `selftest.png` and any `einstellungen.json` it created.
6. Optional desktop shortcut pointing to `CamOffload.exe` (working directory = repo folder).

## Rules

- Never delete or modify files on the camera/SD card or the backup destination unless the user asks.
- Keep `-bf 0` and do not add `-hwaccel_output_format` (causes corrupted frames on AMF).
- `.ps1` files must stay UTF-8 **with BOM** (German umlauts in PowerShell 5.1).
- Do not commit `einstellungen.json`, `logs/`, `temp/` or `*.exe`.
