# Arbeits-Teil von CamOffload: läuft im Hintergrund, spricht ueber $S (synchronisierte Hashtable) mit dem Fenster.
# Ablauf pro Datei: von der Quelle lokal holen -> komprimieren (GPU) -> ins Ziel schreiben.
# Während Datei N komprimiert wird, wird Datei N+1 schon geholt und Datei N-1 hochgeladen.
param($S)
$ErrorActionPreference = 'Stop'
$Inv  = [Globalization.CultureInfo]::InvariantCulture
$Temp = $S.TempDir
$script:enc    = $null
$script:swEnc  = [Diagnostics.Stopwatch]::StartNew()
$script:swCopy = [Diagnostics.Stopwatch]::StartNew()

function Log($t) { $S.Log.Enqueue(('[{0:HH:mm:ss}] {1}' -f (Get-Date), $t)) }
function ToD($x) { $v = 0.0; if ([double]::TryParse([string]$x, [Globalization.NumberStyles]::Float, $Inv, [ref]$v)) { $v } else { 0.0 } }
function Q($a) { '"' + $a + '"' }
function GB($b) { '{0:N2} GB' -f ($b / 1GB) }
function Fmt-Dur([double]$s) { $t = [TimeSpan]::FromSeconds([math]::Max(0, $s)); if ($t.TotalHours -ge 1) { '{0}h {1:00}min' -f [int][math]::Floor($t.TotalHours), $t.Minutes } else { '{0}min {1:00}s' -f $t.Minutes, $t.Seconds } }
function Frames($p) { $n = 0; [void][int]::TryParse(((& ffprobe -v error -select_streams v:0 -show_entries stream=nb_frames -of csv=p=0 $p) -join '').Trim(), [ref]$n); $n }
function Dur($p) { ToD ((& ffprobe -v error -show_entries format=duration -of csv=p=0 $p) -join '') }
function Set-Times($path, $job) { $i = [IO.FileInfo]$path; $i.CreationTime = $job.CT; $i.LastWriteTime = $job.WT }
function Remove-Quiet($p) { if ($p) { try { [IO.File]::Delete($p) } catch {} } }

function Poll-Encode {
    $e = $script:enc
    if (-not $e -or $script:swEnc.ElapsedMilliseconds -lt 700) { return }
    $script:swEnc.Restart()
    try {   # nur Anzeige: darf nie die eigentliche Arbeit abbrechen
        if (-not (Test-Path -LiteralPath $e.Prog)) { return }
        $pl = @(Get-Content -LiteralPath $e.Prog -Tail 12 -ErrorAction SilentlyContinue)
        $us = ([string]($pl | Where-Object { $_ -like 'out_time_us=*' } | Select-Object -Last 1)) -replace 'out_time_us=', ''
        $sp = ToD ((([string]($pl | Where-Object { $_ -like 'speed=*' } | Select-Object -Last 1)) -replace 'speed=', '' -replace 'x', '').Trim())
        if ($us -match '^\d+$' -and $e.Dur -gt 0) {
            $pos = [double]$us / 1e6; $pct = [math]::Min(100, 100 * $pos / $e.Dur)
            $eta = if ($sp -gt 0) { ($e.Dur - $pos) / $sp } else { 0 }
            $e.Job.Status = 'wird komprimiert {0:N0} %' -f $pct
            $S.TxtEnc = '{0}   {1:N0} %   {2:N2}x   noch {3}' -f $e.Job.Name, $pct, $sp, (Fmt-Dur $eta)
        }
    } catch {}
}

# Kopiert mit Fortschritt; schreibt erst "<ziel>.part" und benennt erst nach Größenprüfung um.
function Copy-WithProgress($from, $to, $stage, $job) {
    $part = "$to.part"
    $src = [IO.File]::OpenRead($from)
    try {
        $dst = [IO.File]::Create($part)
        try {
            $buf = New-Object byte[] 4194304; $total = $src.Length; $done = 0
            while (($n = $src.Read($buf, 0, $buf.Length)) -gt 0) {
                if ($S.Cancel) { throw 'Abgebrochen' }
                $dst.Write($buf, 0, $n); $done += $n
                if ($script:swCopy.ElapsedMilliseconds -ge 500) {
                    $script:swCopy.Restart()
                    $S[$stage] = '{0}   {1:N0} %   ({2} von {3})' -f $job.Name, (100.0 * $done / [math]::Max([double]1, [double]$total)), (GB $done), (GB $total)
                }
                Poll-Encode
            }
        } finally { $dst.Dispose() }
    } catch { Remove-Quiet $part; throw } finally { $src.Dispose() }
    if (([IO.FileInfo]$part).Length -ne ([IO.FileInfo]$from).Length) { Remove-Quiet $part; throw "Kopie unvollständig: $to" }
    if ([IO.File]::Exists($to)) { [IO.File]::Delete($to) }
    [IO.File]::Move($part, $to)
    $S[$stage] = ''
}

function Fetch($job) {
    $job.Local = Join-Path $Temp ('{0:0000}_{1}' -f $job.Index, $job.Name)
    $job.Status = 'wird geholt'
    Copy-WithProgress $job.Src $job.Local 'TxtCopy' $job
    $job.Fetched = $true; $job.Status = 'geholt, wartet'
}

function Start-Work($job) {
    $job.Started = $true; $job.T0 = Get-Date
    $job.Result = $job.Local; $job.Mode = 'kopiert'; $job.Grund = ''
    if ($job.OnlyBackup) { $job.Grund = 'nur sichern'; return }
    $encode = $false; $dur = 0
    try {
        $j = ((& ffprobe -v error -select_streams v:0 -show_entries stream=codec_name,r_frame_rate -show_entries format=duration,bit_rate:format_tags=encoder -of json $job.Local) -join '') | ConvertFrom-Json
        $vs = $j.streams[0]; $fps = 0
        if ($vs.r_frame_rate) { $p = $vs.r_frame_rate -split '/'; if ((ToD $p[1]) -gt 0) { $fps = (ToD $p[0]) / (ToD $p[1]) } }
        $mbps = (ToD $j.format.bit_rate) / 1e6; $dur = ToD $j.format.duration
        $isCam = ([string]$j.format.tags.encoder) -like 'DJI*'
        $encode = $isCam -and $mbps -ge $S.MinMbps -and $vs.codec_name -in @('hevc', 'h264') -and $fps -gt 0 -and $dur -gt 0
        if (-not $encode) { $job.Grund = if (-not $isCam) { 'kein Kamera-Original' } elseif ($mbps -lt $S.MinMbps) { 'niedrige Bitrate' } else { 'Format' } }
    } catch { $job.Grund = 'kein Video' }
    if (-not $encode) { return }

    $job.Out = Join-Path $Temp ('{0:0000}_out.mp4' -f $job.Index)
    $prog = Join-Path $Temp ('{0:0000}_progress.txt' -f $job.Index)
    $gop = [int][math]::Round($fps)
    $a = @('-hide_banner', '-nostdin', '-y', '-loglevel', 'error', '-progress', (Q $prog), '-hwaccel', 'd3d11va', '-i', (Q $job.Local),
        '-map', '0:v:0', '-map', '0:a:0?', '-c:v', 'hevc_amf', '-quality', $S.Preset, '-rc', 'cqp', '-qp_i', $S.QP, '-qp_p', $S.QP, '-bf', '0', '-g', $gop,
        '-profile:v', 'main10', '-pix_fmt', 'p010le', '-tag:v', 'hvc1', '-c:a', 'copy', '-map_metadata', '0', '-movflags', '+faststart', (Q $job.Out)) -join ' '
    $psi = New-Object Diagnostics.ProcessStartInfo 'ffmpeg', $a
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.EnvironmentVariables['FFREPORT'] = 'file=' + ((Join-Path $S.LogDir ([IO.Path]::GetFileNameWithoutExtension($job.Name) + '.log')) -replace '\\', '/' -replace ':', '\:') + ':level=16'
    $proc = [Diagnostics.Process]::Start($psi)
    try { $proc.PriorityClass = 'AboveNormal' } catch {}
    $script:enc = @{ Proc = $proc; Job = $job; Prog = $prog; Dur = $dur }
    $job.Status = 'wird komprimiert 0 %'
}

function Wait-Work($job) {
    $e = $script:enc
    if (-not $e -or -not [object]::ReferenceEquals($e.Job, $job)) { return }
    while (-not $e.Proc.WaitForExit(500)) {
        if ($S.Cancel) { try { $e.Proc.Kill() } catch {}; throw 'Abgebrochen' }
        Poll-Encode
    }
    $e.Proc.WaitForExit()
    $script:enc = $null; $S.TxtEnc = ''
    Remove-Quiet $e.Prog
    if ($e.Proc.ExitCode -ne 0) { throw "ffmpeg Exitcode $($e.Proc.ExitCode) (Log in logs\)" }
    $fi = Frames $job.Local; $fo = Frames $job.Out
    $ok = if ($fi -gt 0 -and $fo -gt 0) { $fi -eq $fo } else { [math]::Abs((Dur $job.Out) - $e.Dur) -lt 0.1 }
    if (-not $ok) { throw "Frame-Anzahl stimmt nicht ($fo statt $fi)" }
    if (([IO.FileInfo]$job.Out).Length -lt $job.Size) { $job.Result = $job.Out; $job.Mode = 'komprimiert' }
    else { $job.Grund = 'Encode nicht kleiner'; Remove-Quiet $job.Out }
}

# Trägt die Datei in die Liste des Stapel-Skripts ein, damit es sie nicht noch mal komprimiert.
function Record-Batch($job) {
    if (-not $S.BatchState -or -not $S.Backup -or $job.OnlyBackup) { return }
    $root = $S.BatchSrc.TrimEnd('\'); $b = $S.BackupDir.TrimEnd('\')
    if (-not ($b -eq $root -or $b.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase))) { return }
    $sub = $b.Substring($root.Length).TrimStart('\')
    $expect = if ($sub) { Join-Path $S.BatchDst $sub } else { $S.BatchDst }
    if ($S.CompDir.TrimEnd('\') -ne $expect.TrimEnd('\')) { return }
    $rel = if ($sub) { "$sub\$($job.Name)" } else { $job.Name }
    $rec = [ordered]@{ rel = $rel; modus = $job.Mode; grund = $job.Grund; src_bytes = $job.Size; out_bytes = $job.OutBytes; dauer_video_s = 0; sekunden = [math]::Round(((Get-Date) - $job.T0).TotalSeconds, 1); qp = [int]$S.QP; preset = $S.Preset; fertig = (Get-Date).ToString('s'); quelle = 'CamOffload' }
    New-Item -ItemType Directory -Force (Split-Path $S.BatchState) | Out-Null
    [IO.File]::AppendAllText($S.BatchState, ($rec | ConvertTo-Json -Compress) + "`r`n", (New-Object Text.UTF8Encoding $false))
}

function Finish($job) {
    $job.Status = 'wird hochgeladen'
    if ($S.Backup) {
        New-Item -ItemType Directory -Force $S.BackupDir | Out-Null
        $t = Join-Path $S.BackupDir $job.Name
        Copy-WithProgress $job.Local $t 'TxtUp' $job; Set-Times $t $job
    }
    if ($job.OnlyBackup) { $job.OutBytes = $job.Size }
    else {
        New-Item -ItemType Directory -Force $S.CompDir | Out-Null
        $t = Join-Path $S.CompDir $job.Name
        Copy-WithProgress $job.Result $t 'TxtUp' $job; Set-Times $t $job
        $job.OutBytes = ([IO.FileInfo]$t).Length
        Record-Batch $job
    }
    Remove-Quiet $job.Out; Remove-Quiet $job.Local
    $job.Done = $true
    $how = if ($job.OnlyBackup) { 'gesichert' } elseif ($job.Mode -eq 'komprimiert') { 'komprimiert' } else { "kopiert ($($job.Grund))" }
    $job.Status = 'fertig: {0}  {1} -> {2}' -f $how, (GB $job.Size), (GB $job.OutBytes)
    $S.BytesDone += $job.Size; $S.BytesOut += $job.OutBytes; $S.CountDone++
    Log ('{0}: {1}, {2} -> {3} in {4}' -f $job.Name, $how, (GB $job.Size), (GB $job.OutBytes), (Fmt-Dur ((Get-Date) - $job.T0).TotalSeconds))
}

function Fail($job, $err) {
    if ($S.Cancel) { throw $err }
    $msg = if ($err -is [Management.Automation.ErrorRecord]) { $err.Exception.Message } else { [string]$err }
    $job.Failed = $true; $job.Status = 'FEHLER: ' + $msg
    Log "FEHLER bei $($job.Name): $msg"
    if ($script:enc -and [object]::ReferenceEquals($script:enc.Job, $job)) { try { $script:enc.Proc.Kill() } catch {}; $script:enc = $null; $S.TxtEnc = '' }
    Remove-Quiet $job.Out; Remove-Quiet $job.Local
    $S.CountFail++
}

# ---------------- Hauptablauf ----------------
if (-not ('DjiImport.Power' -as [type])) {
    Add-Type -Namespace DjiImport -Name Power -MemberDefinition '[DllImport("kernel32.dll")] public static extern uint SetThreadExecutionState(uint f);'
}
[void][DjiImport.Power]::SetThreadExecutionState([uint32]'0x80000001')   # PC bleibt wach, solange es läuft
New-Item -ItemType Directory -Force $Temp, $S.LogDir | Out-Null
Get-ChildItem -LiteralPath $Temp -File -Force | ForEach-Object { Remove-Quiet $_.FullName }

$jobs = @()
foreach ($job in $S.Jobs) {
    $target = if ($job.OnlyBackup) { Join-Path $S.BackupDir $job.Name } else { Join-Path $S.CompDir $job.Name }
    if ([IO.File]::Exists($target)) { $job.Status = 'schon vorhanden, übersprungen'; $job.Done = $true; $S.CountSkip++; $S.BytesDone += $job.Size; continue }
    $job.Status = 'wartet'; $jobs += $job
}
Log ("{0} Dateien zu bearbeiten ({1}), {2} schon vorhanden. QP {3}, Preset {4}" -f $jobs.Count, (GB ($jobs | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum), $S.CountSkip, $S.QP, $S.Preset)

$completed = $false
try {
    for ($i = 0; $i -lt $jobs.Count; $i++) {
        $job = $jobs[$i]
        $next = if ($i + 1 -lt $jobs.Count) { $jobs[$i + 1] } else { $null }
        if (-not $job.Failed -and -not $job.Started) { try { if (-not $job.Fetched) { Fetch $job }; Start-Work $job } catch { Fail $job $_ } }
        if ($next -and -not $S.Pause) { try { Fetch $next } catch { Fail $next $_ } }          # läuft parallel zum Encode
        if (-not $job.Failed) { try { Wait-Work $job } catch { Fail $job $_ } }
        if ($next -and $next.Fetched -and -not $next.Failed -and -not $S.Pause) { try { Start-Work $next } catch { Fail $next $_ } }
        if (-not $job.Failed) { try { Finish $job } catch { Fail $job $_ } }                  # läuft parallel zum nächsten Encode
        if ($S.Pause -and -not ($next -and $next.Started)) {
            if ($next -and $next.Fetched -and -not $next.Done) { Remove-Quiet $next.Local; $next.Fetched = $false; $next.Status = 'wartet (pausiert)' }
            Log 'Pausiert. Mit "Start" geht es weiter.'
            break
        }
    }
    if (-not $S.Pause) { $completed = $true }
} catch {
    Log 'Abgebrochen. Angefangene Datei wird beim nächsten Start neu gemacht.'
    foreach ($j in $jobs) { if (-not $j.Done -and -not $j.Failed) { $j.Status = 'wartet (abgebrochen)' } }
} finally {
    if ($script:enc) { try { $script:enc.Proc.Kill() } catch {}; $script:enc = $null }
    Start-Sleep -Milliseconds 300
    Get-ChildItem -LiteralPath $Temp -File -Force -ErrorAction SilentlyContinue | ForEach-Object { Remove-Quiet $_.FullName }
    $S.TxtCopy = ''; $S.TxtEnc = ''; $S.TxtUp = ''
    [void][DjiImport.Power]::SetThreadExecutionState([uint32]'0x80000000')
}

if ($completed -and $S.DeleteList.Count -gt 0) {
    $n = 0
    foreach ($p in $S.DeleteList) { try { [IO.File]::Delete($p); $n++ } catch { Log "Konnte nicht löschen: $p" } }
    Log "$n ausgeschlossene Dateien von der Quelle gelöscht."
}
Log ("Fertig: {0} erledigt, {1} übersprungen, {2} Fehler. {3} -> {4}" -f $S.CountDone, $S.CountSkip, $S.CountFail, (GB ($S.BytesDone - 0)), (GB $S.BytesOut))
$S.Done = $true
