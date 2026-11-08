# Zeichnet das App-Icon und schreibt eine .ico mit 16/32/48 (BMP) und 256 (PNG).
param([string]$Out = (Join-Path (Split-Path $PSScriptRoot) 'CamOffload.ico'))
Add-Type -AssemblyName System.Drawing

function Draw([int]$s) {
    $b = New-Object Drawing.Bitmap($s, $s, [Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [Drawing.Graphics]::FromImage($b)
    $g.SmoothingMode = 'AntiAlias'; $g.Clear([Drawing.Color]::Transparent)
    $k = $s / 256.0
    function RR($x, $y, $w, $h, $r) {
        $p = New-Object Drawing.Drawing2D.GraphicsPath
        $p.AddArc($x, $y, 2 * $r, 2 * $r, 180, 90); $p.AddArc($x + $w - 2 * $r, $y, 2 * $r, 2 * $r, 270, 90)
        $p.AddArc($x + $w - 2 * $r, $y + $h - 2 * $r, 2 * $r, 2 * $r, 0, 90); $p.AddArc($x, $y + $h - 2 * $r, 2 * $r, 2 * $r, 90, 90)
        $p.CloseFigure(); $p
    }
    # Hintergrund: abgerundetes Quadrat, blauer Verlauf
    $bg = RR (8 * $k) (8 * $k) (240 * $k) (240 * $k) (48 * $k)
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush((New-Object Drawing.PointF(0, 0)), (New-Object Drawing.PointF(0, $s)), [Drawing.Color]::FromArgb(255, 45, 140, 255), [Drawing.Color]::FromArgb(255, 20, 70, 180))
    $g.FillPath($br, $bg)
    # Kamera-Koerper (Action-Cam, querformat) + Objektiv
    $white = New-Object Drawing.SolidBrush([Drawing.Color]::White)
    $g.FillPath($white, (RR (44 * $k) (62 * $k) (168 * $k) (112 * $k) (22 * $k)))
    $g.FillRectangle($white, 70 * $k, 50 * $k, 40 * $k, 16 * $k)
    $lens = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 25, 80, 190))
    $g.FillEllipse($lens, 92 * $k, 76 * $k, 84 * $k, 84 * $k)
    $g.FillEllipse($white, 112 * $k, 96 * $k, 44 * $k, 44 * $k)
    $g.FillEllipse($lens, 122 * $k, 106 * $k, 24 * $k, 24 * $k)
    # Gruener Pfeil nach unten (= holen/sichern)
    $green = New-Object Drawing.SolidBrush([Drawing.Color]::FromArgb(255, 60, 210, 110))
    $g.FillRectangle($green, 114 * $k, 176 * $k, 28 * $k, 30 * $k)
    $pts = [Drawing.PointF[]]@([Drawing.PointF]::new(92 * $k, 200 * $k), [Drawing.PointF]::new(164 * $k, 200 * $k), [Drawing.PointF]::new(128 * $k, 238 * $k))
    $g.FillPolygon($green, $pts)
    $g.Dispose(); $b
}

$entries = @()
foreach ($s in 16, 32, 48, 256) {
    $bmp = Draw $s
    if ($s -eq 256) {
        $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $data = $ms.ToArray()
    } else {
        # 32-bit DIB: Header, Pixel (BGRA, von unten nach oben), AND-Maske (leer, Alpha zaehlt)
        $rect = New-Object Drawing.Rectangle(0, 0, $s, $s)
        $bd = $bmp.LockBits($rect, 'ReadOnly', [Drawing.Imaging.PixelFormat]::Format32bppArgb)
        $px = New-Object byte[] ($s * $s * 4); [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $px, 0, $px.Length); $bmp.UnlockBits($bd)
        $maskRow = [int]([math]::Ceiling($s / 32.0) * 4)
        $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter($ms)
        $w.Write([int]40); $w.Write([int]$s); $w.Write([int]($s * 2)); $w.Write([int16]1); $w.Write([int16]32)
        $w.Write([int]0); $w.Write([int]($px.Length + $maskRow * $s)); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0); $w.Write([int]0)
        for ($y = $s - 1; $y -ge 0; $y--) { $w.Write($px, $y * $s * 4, $s * 4) }
        $w.Write((New-Object byte[] ($maskRow * $s))); $w.Flush(); $data = $ms.ToArray()
    }
    $entries += , @($s, $data); $bmp.Dispose()
}
$fs = [IO.File]::Create($Out); $w = New-Object IO.BinaryWriter($fs)
$w.Write([int16]0); $w.Write([int16]1); $w.Write([int16]$entries.Count)
$off = 6 + 16 * $entries.Count
foreach ($e in $entries) {
    $s = $e[0]; $d = $e[1]
    $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s }))); $w.Write([byte]($(if ($s -ge 256) { 0 } else { $s }))); $w.Write([byte]0); $w.Write([byte]0)
    $w.Write([int16]1); $w.Write([int16]32); $w.Write([int]$d.Length); $w.Write([int]$off); $off += $d.Length
}
foreach ($e in $entries) { $w.Write($e[1]) }
$w.Dispose(); $fs.Dispose()
"Icon: $Out"
