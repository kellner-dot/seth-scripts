# Build-KaviGuardLauncher.ps1 - compiles the KaviGuard launcher exe (shield icon
# embedded), repoints the desktop shortcut at it, and pins it to the taskbar.
# Pure ASCII for PS 5.1. Run in PowerShell (Admin): writes to C:\Tools\KaviGuard.
$ErrorActionPreference = "Stop"
$dir = "C:\Tools\KaviGuard"

$cs = @'
using System;
using System.Management.Automation;
using System.Windows.Forms;
public static class KaviGuardLauncher
{
    [STAThread]
    public static void Main()
    {
        string scriptPath = @"C:\Tools\KaviGuard\KaviGuard-Gui.ps1";
        try
        {
            string script = System.IO.File.ReadAllText(scriptPath);
            using (PowerShell ps = PowerShell.Create())
            {
                ps.AddScript(script);
                ps.Invoke();
            }
        }
        catch { }
    }
}
'@
Set-Content (Join-Path $dir "KaviGuardLauncher.cs") $cs -Encoding ASCII
"launcher source written"

$runtimeDir = [Runtime.InteropServices.RuntimeEnvironment]::GetRuntimeDirectory()
$csc = Join-Path $runtimeDir "csc.exe"
if (-not (Test-Path $csc)) { throw "csc.exe not found in $runtimeDir" }
$sma = [System.Management.Automation.PowerShell].Assembly.Location
$ico = Join-Path $dir "kaviguard.ico"
$exe = Join-Path $dir "KaviGuard.exe"
$src = Join-Path $dir "KaviGuardLauncher.cs"
& $csc /nologo /target:winexe /win32icon:"$ico" /reference:System.Windows.Forms.dll /reference:"$sma" /out:"$exe" "$src"
if (-not (Test-Path $exe)) { throw "compile failed - $exe not created" }
"launcher built: $exe"

# The exe gives the taskbar its identity now - drop the explicit AppID from the GUI
$f = Join-Path $dir "KaviGuard-Gui.ps1"
$t = Get-Content $f -Raw
$t = $t.Replace('[KGWin32]::SetCurrentProcessExplicitAppUserModelID("KellnerDot.KaviGuard") | Out-Null' + "`r`n", "")
$t = $t.Replace('[KGWin32]::SetCurrentProcessExplicitAppUserModelID("KellnerDot.KaviGuard") | Out-Null', "")
Set-Content $f $t -Encoding ASCII
$errs = $null; $null = [System.Management.Automation.Language.Parser]::ParseFile($f, [ref]$null, [ref]$errs)
if ($errs.Count -ne 0) { throw "GUI syntax errors: $($errs.Count)" }
"gui cleaned, syntax ok"

# Repoint the desktop shortcut at the exe
$ws = New-Object -ComObject WScript.Shell
$l = $ws.CreateShortcut((Join-Path ([Environment]::GetFolderPath("Desktop")) "KaviGuard.lnk"))
$l.TargetPath = $exe
$l.Arguments = ""
$l.IconLocation = "$exe,0"
$l.Save()
"desktop shortcut repointed"

# Pin it
$sh = New-Object -ComObject Shell.Application
$ns = $sh.Namespace([Environment]::GetFolderPath("Desktop"))
$item = $ns.ParseName("KaviGuard.lnk")
if ($null -eq $item) { throw "shortcut not found via shell" }
$item.InvokeVerb("taskbarpin")
"pinned - close any open dashboard and launch it from the new taskbar pin"
