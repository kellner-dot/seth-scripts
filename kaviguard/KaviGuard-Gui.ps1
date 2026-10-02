# KaviGuard dashboard - double-click the desktop icon to open.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

$ErrorActionPreference = "SilentlyContinue"
$script:dir     = "C:\Tools\KaviGuard"
$script:watcher = Join-Path $script:dir "KaviGuard.ps1"
$script:ico     = Join-Path $script:dir "kaviguard.ico"

$bg     = [System.Drawing.Color]::FromArgb(24, 28, 36)
$panelc = [System.Drawing.Color]::FromArgb(34, 40, 52)
$btnc   = [System.Drawing.Color]::FromArgb(48, 54, 68)
$green  = [System.Drawing.Color]::FromArgb(63, 185, 80)
$red    = [System.Drawing.Color]::FromArgb(248, 81, 73)
$amber  = [System.Drawing.Color]::FromArgb(210, 153, 34)
$fg     = [System.Drawing.Color]::FromArgb(230, 237, 243)
$dim    = [System.Drawing.Color]::FromArgb(139, 148, 158)

function Get-KGData {
    $f = Join-Path $script:dir "status.json"
    if (Test-Path $f) { try { return (Get-Content $f -Raw | ConvertFrom-Json) } catch {} }
    return $null
}

$form = New-Object System.Windows.Forms.Form
if (Test-Path $script:ico) { $form.Icon = New-Object System.Drawing.Icon($script:ico) }
$form.Text = "KaviGuard"
$form.Size = New-Object System.Drawing.Size(480, 640)
$form.StartPosition = "CenterScreen"
$form.BackColor = $bg
$form.ForeColor = $fg
$form.FormBorderStyle = [System.Windows.Forms.FormBorderStyle]::FixedDialog
$form.MaximizeBox = $false
$form.MinimizeBox = $true
if (Test-Path $script:ico) { try { $form.Icon = New-Object System.Drawing.Icon($script:ico) } catch {} }

# ---- header ----
$pic = New-Object System.Windows.Forms.PictureBox
$pic.Location = New-Object System.Drawing.Point(24, 18)
$pic.Size = New-Object System.Drawing.Size(72, 72)
$pic.SizeMode = [System.Windows.Forms.PictureBoxSizeMode]::StretchImage
if (Test-Path $script:ico) { try { $pic.Image = [System.Drawing.Image]::FromFile($script:ico) } catch {} }
$form.Controls.Add($pic)

$title = New-Object System.Windows.Forms.Label
$title.Location = New-Object System.Drawing.Point(112, 20)
$title.Size = New-Object System.Drawing.Size(320, 42)
$title.Text = "KaviGuard"
$title.Font = New-Object System.Drawing.Font("Segoe UI", 22, [System.Drawing.FontStyle]::Bold)
$title.ForeColor = $fg
$form.Controls.Add($title)

$verLbl = New-Object System.Windows.Forms.Label
$verLbl.Location = New-Object System.Drawing.Point(114, 62)
$verLbl.Size = New-Object System.Drawing.Size(320, 24)
$verLbl.Font = New-Object System.Drawing.Font("Segoe UI", 10)
$verLbl.ForeColor = $dim
$form.Controls.Add($verLbl)

# ---- status banner: one glance tells you if all is well ----
$banner = New-Object System.Windows.Forms.Label
$banner.Location = New-Object System.Drawing.Point(24, 106)
$banner.Size = New-Object System.Drawing.Size(432, 34)
$banner.Font = New-Object System.Drawing.Font("Segoe UI", 16, [System.Drawing.FontStyle]::Bold)
$banner.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($banner)

$watchLbl = New-Object System.Windows.Forms.Label
$watchLbl.Location = New-Object System.Drawing.Point(24, 142)
$watchLbl.Size = New-Object System.Drawing.Size(432, 22)
$watchLbl.Font = New-Object System.Drawing.Font("Segoe UI", 9)
$watchLbl.ForeColor = $dim
$watchLbl.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($watchLbl)

# ---- info panel ----
$rows = New-Object System.Windows.Forms.Panel
$rows.Location = New-Object System.Drawing.Point(24, 172)
$rows.Size = New-Object System.Drawing.Size(432, 132)
$rows.BackColor = $panelc
$form.Controls.Add($rows)

$script:valLbls = @{}
$fields = @(
    @("quick", "Last quick scan"),
    @("full",  "Last full scan"),
    @("found", "Threats found"),
    @("rt",    "Defender real-time")
)
$y = 12
foreach ($fld in $fields) {
    $cap = New-Object System.Windows.Forms.Label
    $cap.Location = New-Object System.Drawing.Point(16, $y)
    $cap.Size = New-Object System.Drawing.Size(170, 24)
    $cap.Text = $fld[1]
    $cap.ForeColor = $dim
    $cap.Font = New-Object System.Drawing.Font("Segoe UI", 10)
    $rows.Controls.Add($cap)
    $v = New-Object System.Windows.Forms.Label
    $v.Location = New-Object System.Drawing.Point(200, $y)
    $v.Size = New-Object System.Drawing.Size(216, 24)
    $v.Font = New-Object System.Drawing.Font("Segoe UI", 10, [System.Drawing.FontStyle]::Bold)
    $v.ForeColor = $fg
    $rows.Controls.Add($v)
    $script:valLbls[$fld[0]] = $v
    $y += 30
}

function Update-KGGui {
    $s = Get-KGData
    $fnd = 0
    if ($s) { $fnd = [int]$s.threatsFound }
    if ($s -and $s.running -and $fnd -eq 0) {
        $banner.Text = "You're protected"
        $banner.ForeColor = $green
    } elseif ($s -and $s.running -and $fnd -gt 0) {
        $banner.Text = "Attention: $fnd threat(s) found"
        $banner.ForeColor = $red
    } else {
        $banner.Text = "Watcher not running"
        $banner.ForeColor = $amber
    }
    $verLbl.Text = if ($s) { "version $($s.version)" } else { "version ?" }
    $watchLbl.Text = if ($s -and $s.startedAt) { "Watching Downloads, Desktop and Temp since $($s.startedAt)" } else { "Watcher has not started yet" }
    $L = $script:valLbls
    $L["quick"].Text = if ($s -and $s.lastQuickScan) { "$($s.lastQuickScan)" } else { "not yet" }
    $L["full"].Text  = if ($s -and $s.lastFullScan) { "$($s.lastFullScan)" } else { "not yet" }
    $L["found"].Text = "$fnd"
    $L["found"].ForeColor = if ($fnd -gt 0) { $red } else { $fg }
    if ($s -and $s.defenderRealtime -eq $true) { $L["rt"].Text = "ON"; $L["rt"].ForeColor = $green }
    else { $L["rt"].Text = "OFF"; $L["rt"].ForeColor = $red }
}

function Add-KGButton($text, $sub, $x, $y, $w, $h, $fsize, $action) {
    $b = New-Object System.Windows.Forms.Button
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Text = $text
    $b.FlatStyle = [System.Windows.Forms.FlatStyle]::Flat
    $b.FlatAppearance.BorderColor = $dim
    $b.BackColor = $btnc
    $b.ForeColor = $fg
    $b.Font = New-Object System.Drawing.Font("Segoe UI", $fsize, [System.Drawing.FontStyle]::Bold)
    $b.Add_Click($action)
    if ($sub) {
        $tt = New-Object System.Windows.Forms.ToolTip
        $tt.SetToolTip($b, $sub)
    }
    $form.Controls.Add($b)
}

$script:note = New-Object System.Windows.Forms.Label
$script:note.Location = New-Object System.Drawing.Point(24, 560)
$script:note.Size = New-Object System.Drawing.Size(432, 30)
$script:note.ForeColor = $dim
$script:note.Font = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Italic)
$script:note.TextAlign = [System.Drawing.ContentAlignment]::MiddleCenter
$form.Controls.Add($script:note)

$scanBase = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script:watcher`""

# ---- primary actions: big, obvious, one click each ----
Add-KGButton "Quick Scan" "Fast check of the usual hiding spots. Takes a minute or two." 24 316 211 56 11 {
    $script:note.Text = "Starting quick scan - approve the admin prompt..."
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "$scanBase -ScanNow Quick"
    $script:note.Text = "Quick scan running in the background."
}
Add-KGButton "Full Scan" "Deep check of the whole system. Takes a while - let it run." 245 316 211 56 11 {
    $script:note.Text = "Starting full scan - approve the admin prompt..."
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "$scanBase -ScanNow Full"
    $script:note.Text = "Full scan running in the background."
}
Add-KGButton "Tune-Up" "Clears temp files and empties the recycle bin. Frees up space." 24 382 211 56 11 {
    $script:note.Text = "Tune-up running - approve the admin prompt..."
    Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "$scanBase -TuneUp"
    $script:note.Text = "Tune-up finished - see the toast and logs."
}
Add-KGButton "Scan a File..." "Pick any file or program to check it with Defender." 245 382 211 56 11 {
    $dlg = New-Object System.Windows.Forms.OpenFileDialog
    $dlg.Title = "Pick a file to scan with Defender"
    $dlg.Filter = "All files (*.*)|*.*"
    if ($dlg.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
        $p = $dlg.FileName
        $script:note.Text = "Scanning - approve the admin prompt..."
        Start-Process -FilePath "powershell.exe" -Verb RunAs -ArgumentList "$scanBase -ScanPath `"$p`""
        $script:note.Text = "Scan running in the background."
    }
}

# ---- secondary actions: small and quiet ----
Add-KGButton "Refresh" "Reload the numbers above." 24 452 102 32 9 { Update-KGGui; $script:note.Text = "Refreshed." }
Add-KGButton "Logs" "Open the folder with detailed logs." 134 452 102 32 9 { Start-Process (Join-Path $script:dir "logs") }
Add-KGButton "Quarantine" "Open the folder where threats are held." 244 452 102 32 9 { Start-Process (Join-Path $script:dir "quarantine") }
Add-KGButton "Close" "" 354 452 102 32 9 { $form.Close() }

Update-KGGui
# The wscript hidden launcher starts this process with SW_HIDE in STARTUPINFO, which
# WinForms honors on first show - leaving the form invisible. Force it visible.
Add-Type -TypeDefinition 'using System; using System.Runtime.InteropServices; public static class KGWin32 { [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow); [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hWnd, uint Msg, IntPtr wParam, IntPtr lParam); [DllImport("shell32.dll")] public static extern int SetCurrentProcessExplicitAppUserModelID(string AppID); }'
$showTimer = New-Object System.Windows.Forms.Timer
$showTimer.Interval = 300
$showTimer.Add_Tick({ $showTimer.Stop(); try { $kgIcon = New-Object System.Drawing.Icon($script:ico); $form.Icon = $kgIcon; [KGWin32]::SendMessage($form.Handle, 0x80, [IntPtr]1, $kgIcon.Handle) | Out-Null; [KGWin32]::SendMessage($form.Handle, 0x80, [IntPtr]0, $kgIcon.Handle) | Out-Null } catch {}; [KGWin32]::ShowWindow($form.Handle, 5) | Out-Null; $form.Visible = $true })
$showTimer.Start()
[void]$form.ShowDialog()
