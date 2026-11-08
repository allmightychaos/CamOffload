# CamOffload: Dateien von der Kamera auswählen, Originale auf den NAS sichern und komprimiert ablegen.
param([switch]$SelfTest, [string]$SelfTestFolder)
Add-Type -AssemblyName System.Windows.Forms, System.Drawing
[Windows.Forms.Application]::EnableVisualStyles()

$App      = $PSScriptRoot
$CfgFile  = Join-Path $App 'einstellungen.json'
$BatchSrc = 'D:\Videos\Camera'
$BatchDst = 'D:\Videos\Camera (compressed)'
$BatchState = ''   # optional: JSONL-Liste eines separaten Stapel-Skripts, leer = aus

$cfg = @{ quelle = ''; ausschliessen = '*.LRF'; loeschen = $false; sichern = $true; sichernNach = $BatchSrc; kompNach = $BatchDst; qp = 33; preset = 'balanced' }
if (Test-Path $CfgFile) { try { (Get-Content $CfgFile -Raw | ConvertFrom-Json).PSObject.Properties | ForEach-Object { $cfg[$_.Name] = $_.Value } } catch {} }
if (-not $cfg.quelle -or -not (Test-Path $cfg.quelle)) {
    $cam = Get-Volume -ErrorAction SilentlyContinue | Where-Object { $_.DriveLetter -and $_.FileSystemLabel -match 'OsmoAction|SD_Card|DJI' } | Select-Object -First 1
    if ($cam) { $cfg.quelle = "$($cam.DriveLetter):\" }
}

function P($x, $y) { New-Object Drawing.Point($x, $y) }
function Sz($w, $h) { New-Object Drawing.Size($w, $h) }
function Ctl($type, $x, $y, $w, $h, $anchor, $props = @{}) {
    $c = New-Object "Windows.Forms.$type"
    $c.Location = P $x $y; $c.Size = Sz $w $h; $c.Anchor = $anchor
    foreach ($k in $props.Keys) { $c.$k = $props[$k] }
    $form.Controls.Add($c); $c
}
function Auto-Comp($s) {
    $s = $s.Trim().TrimEnd('\')
    if ($s -match '\\DJI Action 5 Pro(\\|$)') { return ($s -replace '\\DJI Action 5 Pro(\\|$)', '\DJI Action 5 Pro (komprimiert)$1') }
    $null
}

$form = New-Object Windows.Forms.Form
$form.Text = 'CamOffload'; $form.ClientSize = Sz 964 800; $form.MinimumSize = Sz 820 640
$form.StartPosition = 'CenterScreen'; $form.Font = New-Object Drawing.Font('Segoe UI', 9)
try { $form.Icon = New-Object Drawing.Icon((Join-Path $App 'CamOffload.ico'), 32, 32) } catch {}
$TL = 'Top,Left'; $TLR = 'Top,Left,Right'; $BL = 'Bottom,Left'; $BLR = 'Bottom,Left,Right'; $BR = 'Bottom,Right'; $ALL = 'Top,Bottom,Left,Right'
$bold = New-Object Drawing.Font('Segoe UI', 9, [Drawing.FontStyle]::Bold)

# --- Quelle ---
[void](Ctl Label 12 12 300 20 $TL @{ Text = '1. Quelle (Kamera oder Karte)'; Font = $bold })
$btnFolder = Ctl Button 12 36 140 28 $TL @{ Text = 'Ordner wählen…' }
$btnFiles  = Ctl Button 158 36 140 28 $TL @{ Text = 'Dateien wählen…' }
$lblSrc    = Ctl Label 308 42 644 20 $TLR @{ Text = 'Noch nichts gewählt'; AutoEllipsis = $true }
[void](Ctl Label 12 76 90 20 $TL @{ Text = 'Ausschließen:' })
$tbEx  = Ctl TextBox 104 72 170 24 $TL @{ Text = $cfg.ausschliessen }
[void](Ctl Label 280 76 120 20 $TL @{ Text = 'z. B. *.LRF;*.JPG'; ForeColor = [Drawing.SystemColors]::GrayText })
$cbDel = Ctl CheckBox 404 73 548 24 $TLR @{ Text = 'Ausgeschlossene Dateien nach dem Durchlauf von der Quelle löschen (endgültig)'; Checked = [bool]$cfg.loeschen }

# --- Dateiliste ---
$lv = Ctl ListView 12 104 940 300 $ALL @{ View = 'Details'; CheckBoxes = $true; FullRowSelect = $true; HideSelection = $false }
[void]$lv.Columns.Add('Datei', 250); [void]$lv.Columns.Add('Ordner', 170); [void]$lv.Columns.Add('Größe', 80, 'Right'); [void]$lv.Columns.Add('Aktion', 110); [void]$lv.Columns.Add('Status', 300)
$lblSum   = Ctl Label 12 412 530 20 $BLR @{ Text = '' }
$btnOnlyBk = Ctl Button 548 408 164 26 $BR @{ Text = 'Markierte → nur sichern' }
$btnComp   = Ctl Button 716 408 166 26 $BR @{ Text = 'Markierte → komprimieren' }
$btnAll    = Ctl Button 886 408 66 26 $BR @{ Text = 'Alle an' }

# --- Ziel ---
[void](Ctl Label 12 444 300 20 $BL @{ Text = '2. Ziel'; Font = $bold })
$cbBk  = Ctl CheckBox 12 468 170 24 $BL @{ Text = 'Originale sichern nach:'; Checked = [bool]$cfg.sichern }
$tbBk  = Ctl TextBox 186 468 690 24 $BLR @{ Text = $cfg.sichernNach }
$btnBk = Ctl Button 882 466 70 26 $BR @{ Text = '...' }
[void](Ctl Label 12 502 170 20 $BL @{ Text = 'Komprimiert nach:' })
$tbComp  = Ctl TextBox 186 498 690 24 $BLR @{ Text = $cfg.kompNach }
$btnComp2 = Ctl Button 882 496 70 26 $BR @{ Text = '...' }

# --- Einstellungen + Steuerung ---
[void](Ctl Label 12 540 30 20 $BL @{ Text = 'QP:' })
$numQP = Ctl NumericUpDown 44 536 52 24 $BL @{ Minimum = 20; Maximum = 45; Value = [int]$cfg.qp }
[void](Ctl Label 108 540 48 20 $BL @{ Text = 'Preset:' })
$cbPreset = Ctl ComboBox 158 536 100 24 $BL @{ DropDownStyle = 'DropDownList' }
[void]$cbPreset.Items.AddRange(@('quality', 'balanced', 'speed')); $cbPreset.SelectedItem = $cfg.preset
[void](Ctl Label 266 540 260 20 $BL @{ Text = 'empfohlen: QP 33 + balanced'; ForeColor = [Drawing.SystemColors]::GrayText })
$btnStart  = Ctl Button 600 532 110 30 $BR @{ Text = 'Start'; Font = $bold }
$btnPause  = Ctl Button 716 532 120 30 $BR @{ Text = 'Pause'; Enabled = $false }
$btnCancel = Ctl Button 842 532 110 30 $BR @{ Text = 'Abbrechen'; Enabled = $false }

# --- Fortschritt ---
$pb = Ctl ProgressBar 12 572 940 18 $BLR @{ Maximum = 1000 }
$lblCopy = Ctl Label 12 596 940 20 $BLR @{ Text = 'Holen:'; AutoEllipsis = $true }
$lblEnc  = Ctl Label 12 616 940 20 $BLR @{ Text = 'Komprimieren:'; AutoEllipsis = $true }
$lblUp   = Ctl Label 12 636 940 20 $BLR @{ Text = 'Hochladen:'; AutoEllipsis = $true }
$tbLog = Ctl TextBox 12 660 940 128 $BLR @{ Multiline = $true; ScrollBars = 'Vertical'; ReadOnly = $true; Font = New-Object Drawing.Font('Consolas', 8.5) }

$script:running = $false; $script:bulk = $false; $script:lastAuto = Auto-Comp $tbBk.Text
$gray = [Drawing.SystemColors]::GrayText; $normal = [Drawing.SystemColors]::WindowText

function Update-Summary {
    if ($script:bulk) { return }
    $items = @($lv.Items)
    foreach ($it in $items) { Show-Action $it }
    $sel = @($items | Where-Object { $_.Checked }); $ex = @($items | Where-Object { $_.Tag.Excluded })
    $selGB = ($sel | ForEach-Object { $_.Tag.File.Length } | Measure-Object -Sum).Sum / 1GB
    $exGB  = ($ex | ForEach-Object { $_.Tag.File.Length } | Measure-Object -Sum).Sum / 1GB
    $lblSum.Text = '{0} ausgewählt ({1:N1} GB)   |   {2} ausgeschlossen ({3:N2} GB)   |   {4} Dateien insgesamt' -f $sel.Count, $selGB, $ex.Count, $exGB, $items.Count
}
function Show-Action($it) {
    if (-not $it -or $it.SubItems.Count -lt 5 -or -not $it.Tag) { return }
    $it.SubItems[3].Text = $(if (-not $it.Checked) { '–' } elseif ($it.Tag.OnlyBackup) { 'nur sichern' } else { 'komprimieren' })
    if ($it.Tag.Excluded -and -not $script:running) { $it.SubItems[4].Text = $(if ($it.Checked) { '' } else { 'ausgeschlossen' }) }
}
function Set-Action($it, $onlyBackup) { $it.Tag.OnlyBackup = $onlyBackup; if (-not $it.Checked) { $it.Checked = $true }; Show-Action $it }
function Apply-Exclude {
    $pats = @($tbEx.Text -split '[;,]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $script:bulk = $true
    foreach ($it in $lv.Items) {
        $m = $false; foreach ($p in $pats) { if ($it.Tag.File.Name -like $p) { $m = $true; break } }
        if ($it.Tag.Excluded -ne $m) {
            $it.Tag.Excluded = $m; $it.Checked = -not $m
            $it.ForeColor = $(if ($m) { $gray } else { $normal })
            $it.SubItems[4].Text = $(if ($m) { 'ausgeschlossen' } else { '' })
        }
    }
    $script:bulk = $false; Update-Summary
}
function Load-Files($files, $base) {
    $lv.BeginUpdate(); $script:bulk = $true; $lv.Items.Clear()
    foreach ($f in ($files | Sort-Object FullName)) {
        $it = New-Object Windows.Forms.ListViewItem($f.Name)
        $rel = if ($base) { $f.DirectoryName.Substring($base.TrimEnd('\').Length).TrimStart('\') } else { $f.DirectoryName }
        [void]$it.SubItems.Add($rel); [void]$it.SubItems.Add(('{0:N2} GB' -f ($f.Length / 1GB))); [void]$it.SubItems.Add('komprimieren'); [void]$it.SubItems.Add('')
        $it.Tag = @{ File = $f; Excluded = $false; OnlyBackup = $false }
        $it.Checked = $true
        [void]$lv.Items.Add($it)
    }
    $script:bulk = $false; $lv.EndUpdate(); Apply-Exclude
}
function Pick-Folder($desc, $start) {
    $d = New-Object Windows.Forms.FolderBrowserDialog
    $d.Description = $desc; $d.ShowNewFolderButton = $true
    if ($start -and (Test-Path -LiteralPath $start)) { $d.SelectedPath = $start }
    if ($d.ShowDialog($form) -eq 'OK') { $d.SelectedPath } else { $null }
}
function Load-Folder($path) {
    $files = @(Get-ChildItem -LiteralPath $path -Recurse -File -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -notmatch '\\(System Volume Information|\$RECYCLE\.BIN)\\' })
    $cfg.quelle = $path; $lblSrc.Text = "$path   ($($files.Count) Dateien)"
    Load-Files $files $path
}

$btnFolder.Add_Click({ $p = Pick-Folder 'Ordner auf der Kamera wählen (z. B. DCIM). Unterordner werden mitgenommen.' $cfg.quelle; if ($p) { Load-Folder $p } })
$btnFiles.Add_Click({
    $d = New-Object Windows.Forms.OpenFileDialog
    $d.Multiselect = $true; $d.Filter = 'Videos (*.mp4;*.mov)|*.mp4;*.mov|Alle Dateien (*.*)|*.*'
    if ($cfg.quelle -and (Test-Path -LiteralPath $cfg.quelle)) { $d.InitialDirectory = $cfg.quelle }
    if ($d.ShowDialog($form) -eq 'OK') {
        $files = @($d.FileNames | ForEach-Object { Get-Item -LiteralPath $_ })
        $base = Split-Path $d.FileNames[0]; $cfg.quelle = $base
        $lblSrc.Text = "$($files.Count) einzelne Dateien aus $base"
        Load-Files $files $base
    }
})
$tbEx.Add_TextChanged({ Apply-Exclude })
$lv.Add_ItemCheck({ if ($script:running) { $_.NewValue = $_.CurrentValue } })
$lv.Add_ItemChecked({ if (-not $script:bulk) { Show-Action $_.Item }; Update-Summary })
$btnOnlyBk.Add_Click({ foreach ($it in @($lv.SelectedItems)) { Set-Action $it $true } })
$btnComp.Add_Click({ foreach ($it in @($lv.SelectedItems)) { Set-Action $it $false } })

# Rechtsklick-Menü auf der Liste
$menu = New-Object Windows.Forms.ContextMenuStrip
$miBk   = $menu.Items.Add('Nur sichern (Original, nicht komprimieren)')
$miComp = $menu.Items.Add('Komprimieren')
[void]$menu.Items.Add((New-Object Windows.Forms.ToolStripSeparator))
$miOn   = $menu.Items.Add('Haken setzen')
$miOff  = $menu.Items.Add('Haken entfernen (wird nicht angefasst)')
$miBk.Add_Click({ foreach ($it in @($lv.SelectedItems)) { Set-Action $it $true } })
$miComp.Add_Click({ foreach ($it in @($lv.SelectedItems)) { Set-Action $it $false } })
$miOn.Add_Click({ foreach ($it in @($lv.SelectedItems)) { $it.Checked = $true } })
$miOff.Add_Click({ foreach ($it in @($lv.SelectedItems)) { $it.Checked = $false } })
function Update-Menu {
    # Nur anbieten, was bei mindestens einer markierten Datei etwas ändert; der Rest bleibt sichtbar, aber grau.
    $sel = @($lv.SelectedItems)
    $miOn.Enabled   = @($sel | Where-Object { -not $_.Checked }).Count -gt 0
    $miOff.Enabled  = @($sel | Where-Object { $_.Checked }).Count -gt 0
    $miBk.Enabled   = @($sel | Where-Object { -not ($_.Checked -and $_.Tag.OnlyBackup) }).Count -gt 0
    $miComp.Enabled = @($sel | Where-Object { -not ($_.Checked -and -not $_.Tag.OnlyBackup) }).Count -gt 0
}
$menu.Add_Opening({ if ($script:running -or $lv.SelectedItems.Count -eq 0) { $_.Cancel = $true; return }; Update-Menu })
$lv.ContextMenuStrip = $menu
$btnAll.Add_Click({ $script:bulk = $true; foreach ($it in $lv.Items) { if (-not $it.Tag.Excluded) { $it.Checked = $true } }; $script:bulk = $false; Update-Summary })
$tbBk.Add_TextChanged({
    $auto = Auto-Comp $tbBk.Text
    if ($auto -and (-not $tbComp.Text.Trim() -or $tbComp.Text.Trim().TrimEnd('\') -eq ([string]$script:lastAuto).TrimEnd('\'))) { $tbComp.Text = $auto }
    $script:lastAuto = $auto
})
$cbBk.Add_CheckedChanged({ $tbBk.Enabled = $cbBk.Checked; $btnBk.Enabled = $cbBk.Checked })
$btnBk.Add_Click({ $p = Pick-Folder 'Ordner für die Originale auf dem NAS (z. B. ...\2026\11 November\Radfahren)' $tbBk.Text; if ($p) { $tbBk.Text = $p } })
$btnComp2.Add_Click({ $p = Pick-Folder 'Ordner für die komprimierten Dateien' $tbComp.Text; if ($p) { $tbComp.Text = $p } })

function Set-Running($on) {
    $script:running = $on
    foreach ($c in @($btnFolder, $btnFiles, $tbEx, $cbDel, $btnOnlyBk, $btnComp, $btnAll, $cbBk, $tbBk, $btnBk, $tbComp, $btnComp2, $numQP, $cbPreset, $btnStart)) { $c.Enabled = -not $on }
    if (-not $on) { $tbBk.Enabled = $cbBk.Checked; $btnBk.Enabled = $cbBk.Checked }
    $btnPause.Enabled = $on; $btnCancel.Enabled = $on; $btnPause.Text = 'Pause'
}
function Save-Cfg {
    $cfg.ausschliessen = $tbEx.Text; $cfg.loeschen = $cbDel.Checked; $cfg.sichern = $cbBk.Checked
    $cfg.sichernNach = $tbBk.Text.Trim(); $cfg.kompNach = $tbComp.Text.Trim(); $cfg.qp = [int]$numQP.Value; $cfg.preset = [string]$cbPreset.SelectedItem
    try { $cfg | ConvertTo-Json | Set-Content -LiteralPath $CfgFile -Encoding UTF8 } catch {}
}
function Msg($t, $icon = 'Information', $btn = 'OK') { [Windows.Forms.MessageBox]::Show($form, $t, 'CamOffload', $btn, $icon) }

$btnStart.Add_Click({
    $sel = @($lv.Items | Where-Object { $_.Checked })
    if (-not $sel) { [void](Msg 'Keine Dateien ausgewählt.' 'Warning'); return }
    $comp = $tbComp.Text.Trim(); $bk = $tbBk.Text.Trim()
    if (-not $comp) { [void](Msg 'Bitte einen Ordner für die komprimierten Dateien angeben.' 'Warning'); return }
    if ($cbBk.Checked -and -not $bk) { [void](Msg 'Bitte einen Ordner für die Originale angeben.' 'Warning'); return }
    if ($cbBk.Checked -and $bk.TrimEnd('\') -eq $comp.TrimEnd('\')) { [void](Msg 'Originale und komprimierte Dateien brauchen verschiedene Ordner.' 'Warning'); return }
    if (-not $cbBk.Checked -and @($sel | Where-Object { $_.Tag.OnlyBackup })) { [void](Msg '"Nur sichern" braucht den Haken bei "Originale sichern nach".' 'Warning'); return }
    $dupes = @($sel | Group-Object { $_.Tag.File.Name } | Where-Object Count -gt 1)
    if ($dupes) { [void](Msg ("Gleicher Dateiname mehrfach ausgewählt (alles landet in einem Ordner):`n`n" + (($dupes | ForEach-Object Name) -join "`n")) 'Warning'); return }
    try { foreach ($d in @($comp) + @(if ($cbBk.Checked) { $bk })) { New-Item -ItemType Directory -Force -Path $d -ErrorAction Stop | Out-Null } }
    catch { [void](Msg "Zielordner nicht erreichbar:`n$($_.Exception.Message)" 'Error'); return }

    $del = @()
    if ($cbDel.Checked) {
        $ex = @($lv.Items | Where-Object { $_.Tag.Excluded -and -not $_.Checked })
        if ($ex) {
            $gb = ($ex | ForEach-Object { $_.Tag.File.Length } | Measure-Object -Sum).Sum / 1GB
            $names = ($ex | Select-Object -First 12 | ForEach-Object { $_.Tag.File.Name }) -join "`n"
            if ($ex.Count -gt 12) { $names += "`n... und $($ex.Count - 12) weitere" }
            $r = Msg ("Nach einem vollständigen Durchlauf werden {0} ausgeschlossene Dateien ({1:N2} GB) ENDGÜLTIG von der Quelle gelöscht (kein Papierkorb):`n`n{2}`n`nFortfahren?" -f $ex.Count, $gb, $names) 'Warning' 'YesNo'
            if ($r -ne 'Yes') { return }
            $del = @($ex | ForEach-Object { $_.Tag.File.FullName })
        }
    }

    $jobs = New-Object Collections.ArrayList
    foreach ($it in $sel) {
        $f = $it.Tag.File
        [void]$jobs.Add(@{ Index = $it.Index; Name = $f.Name; Src = $f.FullName; Size = $f.Length; CT = $f.CreationTime; WT = $f.LastWriteTime; OnlyBackup = [bool]$it.Tag.OnlyBackup; Status = 'wartet' })
        $it.SubItems[4].Text = 'wartet'
    }
    foreach ($it in $lv.Items) { if (-not $it.Checked -and -not $it.Tag.Excluded) { $it.SubItems[4].Text = 'nicht ausgewählt' } }
    Save-Cfg
    $script:S = [hashtable]::Synchronized(@{
        Jobs = $jobs; Log = New-Object 'Collections.Concurrent.ConcurrentQueue[string]'
        TempDir = (Join-Path $App 'temp'); LogDir = (Join-Path $App 'logs')
        Backup = $cbBk.Checked; BackupDir = $bk; CompDir = $comp; QP = [int]$numQP.Value; Preset = [string]$cbPreset.SelectedItem; MinMbps = 50
        DeleteList = $del; BatchSrc = $BatchSrc; BatchDst = $BatchDst; BatchState = $BatchState
        Pause = $false; Cancel = $false; Done = $false; TxtCopy = ''; TxtEnc = ''; TxtUp = ''
        BytesTotal = [double](($jobs | ForEach-Object { $_.Size } | Measure-Object -Sum).Sum); BytesDone = 0.0; BytesOut = 0.0; CountDone = 0; CountSkip = 0; CountFail = 0
    })
    $tbLog.Clear()
    $script:ps = [PowerShell]::Create()
    [void]$script:ps.AddScript((Get-Content -LiteralPath (Join-Path $App 'worker.ps1') -Raw)).AddArgument($script:S)
    $script:handle = $script:ps.BeginInvoke()
    Set-Running $true; $timer.Start()
})
$btnPause.Add_Click({
    $script:S.Pause = -not $script:S.Pause
    $btnPause.Text = $(if ($script:S.Pause) { 'Weiter' } else { 'Pause' })
    $tbLog.AppendText($(if ($script:S.Pause) { "Pause angefordert: das aktuelle Video wird noch fertig gemacht.`r`n" } else { "Pause aufgehoben.`r`n" }))
})
$btnCancel.Add_Click({
    if ((Msg 'Sofort abbrechen? Die gerade bearbeitete Datei wird beim nächsten Start neu gemacht.' 'Question' 'YesNo') -eq 'Yes') { $script:S.Cancel = $true }
})

$timer = New-Object Windows.Forms.Timer; $timer.Interval = 500
$timer.Add_Tick({
    $S = $script:S; if (-not $S) { return }
    $line = $null; while ($S.Log.TryDequeue([ref]$line)) { $tbLog.AppendText($line + "`r`n") }
    foreach ($j in $S.Jobs) { $sub = $lv.Items[$j.Index].SubItems[4]; if ($sub.Text -ne $j.Status) { $sub.Text = $j.Status } }
    $pb.Value = [int][math]::Min(1000, 1000.0 * $S.BytesDone / [math]::Max([double]1, [double]$S.BytesTotal))
    $lblCopy.Text = 'Holen:            ' + $S.TxtCopy
    $lblEnc.Text  = 'Komprimieren:  ' + $S.TxtEnc
    $lblUp.Text   = 'Hochladen:       ' + $S.TxtUp
    $form.Text = 'CamOffload  -  {0}/{1} fertig' -f ($S.CountDone + $S.CountSkip), $S.Jobs.Count
    if ($S.Done -or $script:handle.IsCompleted) {
        $timer.Stop()
        while ($S.Log.TryDequeue([ref]$line)) { $tbLog.AppendText($line + "`r`n") }
        foreach ($e in $script:ps.Streams.Error) { $tbLog.AppendText("FEHLER (intern): $e`r`n") }
        $script:ps.Dispose(); $script:running = $false
        Set-Running $false
        $form.Text = 'CamOffload'
        $lblCopy.Text = 'Holen:'; $lblEnc.Text = 'Komprimieren:'; $lblUp.Text = 'Hochladen:'
        if (-not $S.Pause -and -not $S.Cancel) { [Media.SystemSounds]::Asterisk.Play() }
    }
})
$form.Add_FormClosing({
    if ($script:running) {
        if ((Msg 'Es läuft noch. Abbrechen und schließen?' 'Question' 'YesNo') -ne 'Yes') { $_.Cancel = $true; return }
        $script:S.Cancel = $true
        $sw = [Diagnostics.Stopwatch]::StartNew()
        while (-not $script:handle.IsCompleted -and $sw.Elapsed.TotalSeconds -lt 20) { Start-Sleep -Milliseconds 200; [Windows.Forms.Application]::DoEvents() }
    }
    Save-Cfg
})

if ($SelfTest) {
    if ($SelfTestFolder) {
        Load-Folder $SelfTestFolder
        $tbEx.Text = '*.LRF;*slow_motion_001*'
        if ($lv.Items.Count -gt 1) { $lv.Items[1].Selected = $true; Set-Action $lv.Items[1] $true }
        if ($lv.Items.Count -gt 5) { $lv.Items[5].Checked = $false }
    }
    $form.StartPosition = 'Manual'; $form.Location = P -3000 -3000; $form.Show(); [Windows.Forms.Application]::DoEvents()
    Update-Summary
    if ($SelfTestFolder -and $lv.Items.Count -gt 5) {
        foreach ($case in @(@(0), @(1), @(2), @(5), @(0, 1), @(0, 5))) {
            foreach ($it in $lv.Items) { $it.Selected = $false }; foreach ($n in $case) { $lv.Items[$n].Selected = $true }; Update-Menu
            "Zeilen {0,-5} [{1}]  -> Haken setzen:{2,-5} Haken entfernen:{3,-5} nur sichern:{4,-5} komprimieren:{5}" -f ($case -join ','), (($case | ForEach-Object { $i = $lv.Items[$_]; '{0}/{1}' -f $(if ($i.Checked) { 'an' } else { 'aus' }), $i.SubItems[3].Text }) -join ' '), $miOn.Enabled, $miOff.Enabled, $miBk.Enabled, $miComp.Enabled
        }
    }    $bmp = New-Object Drawing.Bitmap($form.Width, $form.Height); $form.DrawToBitmap($bmp, (New-Object Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
    $out = Join-Path $App 'selftest.png'; $bmp.Save($out); $bmp.Dispose(); $form.Close(); "GUI OK -> $out"; return
}
if ($cfg.quelle -and (Test-Path -LiteralPath $cfg.quelle)) { $lblSrc.Text = "Vorschlag: $($cfg.quelle)  (mit 'Ordner wählen' laden)" }
[void]$form.ShowDialog()
