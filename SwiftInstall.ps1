#Requires -RunAsAdministrator
<#
.SYNOPSIS
    Bulk Driver Installation Sequencer.

.DESCRIPTION
    Reads a text file (drivers.txt) listing extracted driver folder names,
    one per line, in install order. For each folder it walks the directory
    tree to find Install.bat and runs it via cmd.exe. A single reboot with
    a cancellable countdown fires after all installs complete.

.NOTES
    - Place this script, drivers.txt, and all driver folders in the same directory.
    - Run from an elevated PowerShell prompt or right-click > Run as Administrator.

    drivers.txt format (one folder name per line, lines starting with # are ignored):
    -----------------------------------------------------------------------
    # Chipset must go first
    ATKPackage
    Chipset_AMD
    Audio_Realtek
    GPU_AMD
    NetworkCard_Intel
    Bluetooth_Intel
    Touchpad_ELAN
    -----------------------------------------------------------------------
#>

# ============================================================
#  CONFIGURATION
# ============================================================

# Name of the text file listing driver folders (must sit next to this script)
$DriverListFile = 'drivers.txt'

# Name of the batch file to look for inside each driver folder tree
$BatchFileName  = 'Install.bat'

# How deep to search for Install.bat inside each folder
$SearchDepth    = 5

# Seconds before automatic reboot (0 = reboot immediately, no prompt)
$RebootCountdownSec = 30

# Max seconds to wait for a batch install to finish (0 = wait forever)
$TimeoutSec = 300

# ============================================================
#  INTERNALS — no edits needed below
# ============================================================

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Continue'

$ScriptDir = $PSScriptRoot
$Timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile   = Join-Path $ScriptDir "DriverInstall_$Timestamp.log"

function Write-Log {
    param([string]$Message, [string]$Level = 'INFO')
    $Line = '[{0}] [{1}] {2}' -f (Get-Date -Format 'HH:mm:ss'), $Level.PadRight(5), $Message
    $Line | Tee-Object -FilePath $LogFile -Append | Write-Host -ForegroundColor $(
        switch ($Level) {
            'ERROR' { 'Red'    }
            'WARN'  { 'Yellow' }
            'OK'    { 'Green'  }
            default { 'Cyan'   }
        }
    )
}

function Find-InstallBat {
    param([string]$RootFolder)

    # Breadth-first walk up to $SearchDepth levels
    $Queue         = [System.Collections.Generic.Queue[string]]::new()
    $Queue.Enqueue($RootFolder)
    $CurrentDepth  = 0
    $LevelBoundary = 1

    while ($Queue.Count -gt 0) {
        $Dir = $Queue.Dequeue()
        $LevelBoundary--

        $Candidate = Join-Path $Dir $BatchFileName
        if (Test-Path $Candidate -PathType Leaf) {
            return $Candidate
        }

        if ($CurrentDepth -lt $SearchDepth) {
            $SubDirs = Get-ChildItem -Path $Dir -Directory -ErrorAction SilentlyContinue
            foreach ($Sub in $SubDirs) { $Queue.Enqueue($Sub.FullName) }
        }

        if ($LevelBoundary -eq 0) {
            $CurrentDepth++
            $LevelBoundary = $Queue.Count
        }
    }

    return $null
}

function Invoke-InstallBat {
    param([string]$BatPath)

    $BatDir = Split-Path $BatPath -Parent
    Write-Log "Running: $BatPath"

    try {
        $ProcArgs = @{
            FilePath         = 'cmd.exe'
            ArgumentList     = "/c `"$BatPath`""
            WorkingDirectory = $BatDir
            PassThru         = $true
            Wait             = $false
            WindowStyle      = 'Hidden'
        }
        $Proc = Start-Process @ProcArgs

        if ($TimeoutSec -gt 0) {
            $Finished = $Proc.WaitForExit($TimeoutSec * 1000)
            if (-not $Finished) {
                Write-Log "Timed out after ${TimeoutSec}s — killing process." 'WARN'
                $Proc.Kill()
                return 'TIMEOUT'
            }
        } else {
            $Proc.WaitForExit()
        }

        return $Proc.ExitCode
    } catch {
        Write-Log "Exception while running bat: $_" 'ERROR'
        return 'EXCEPTION'
    }
}

function Install-DriverFolder {
    param([string]$FolderName)

    $FolderPath = Join-Path $ScriptDir $FolderName

    if (-not (Test-Path $FolderPath -PathType Container)) {
        Write-Log "Folder not found: $FolderName" 'ERROR'
        return [pscustomobject]@{
            Folder   = $FolderName
            BatPath  = 'N/A'
            ExitCode = 'MISSING'
            Status   = 'SKIPPED'
        }
    }

    $BatPath = Find-InstallBat -RootFolder $FolderPath
    if ($null -eq $BatPath) {
        Write-Log "No $BatchFileName found anywhere under: $FolderName" 'WARN'
        return [pscustomobject]@{
            Folder   = $FolderName
            BatPath  = 'not found'
            ExitCode = 'NO_BAT'
            Status   = 'SKIPPED'
        }
    }

    $RelBat = $BatPath.Replace($ScriptDir, '').TrimStart('\')
    Write-Log "Found: $RelBat"

    $ExitCode = Invoke-InstallBat -BatPath $BatPath

    $Status = switch ($ExitCode) {
        'TIMEOUT'   { 'FAILED' }
        'EXCEPTION' { 'FAILED' }
        0           { 'OK'     }
        3010        { 'OK (reboot pending)' }
        1641        { 'OK (reboot pending)' }
        default     {
            # Non-zero exits from bat files are common and often benign
            Write-Log "$FolderName exited with code $ExitCode — may be benign." 'WARN'
            'WARN'
        }
    }

    $LogLevel = switch ($Status) {
        'OK'                  { 'OK'   }
        'OK (reboot pending)' { 'OK'   }
        'WARN'                { 'WARN' }
        default               { 'ERROR'}
    }
    Write-Log "$FolderName finished (exit $ExitCode)." $LogLevel

    return [pscustomobject]@{
        Folder   = $FolderName
        BatPath  = $RelBat
        ExitCode = $ExitCode
        Status   = $Status
    }
}

function Show-RebootCountdown {
    param([int]$Seconds)

    if ($Seconds -le 0) {
        Write-Log "Rebooting now..."
        Restart-Computer -Force
        return
    }

    Write-Host ''
    Write-Host '  All drivers installed.' -ForegroundColor White
    Write-Host "  System will reboot in $Seconds seconds." -ForegroundColor Yellow
    Write-Host '  Press [C] to cancel.' -ForegroundColor Cyan
    Write-Host ''

    for ($i = $Seconds; $i -gt 0; $i--) {
        Write-Host "`r  Rebooting in $i seconds...   " -NoNewline -ForegroundColor Yellow
        for ($p = 0; $p -lt 10; $p++) {
            Start-Sleep -Milliseconds 100
            if ([Console]::KeyAvailable) {
                $Key = [Console]::ReadKey($true)
                if ($Key.Key -eq [ConsoleKey]::C) {
                    Write-Host ''
                    Write-Log "Reboot cancelled by user. Reboot manually when ready." 'WARN'
                    return
                }
            }
        }
    }

    Write-Host ''
    Write-Log "Initiating reboot..."
    Restart-Computer -Force
}

# ============================================================
#  MAIN
# ============================================================

Clear-Host
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host '  ASUS A16 Driver Installer  [BAT method]' -ForegroundColor White
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host ''
Write-Log "Log file : $LogFile"
Write-Log "Root dir : $ScriptDir"

# --- Read drivers.txt ---
$ListPath = Join-Path $ScriptDir $DriverListFile
if (-not (Test-Path $ListPath -PathType Leaf)) {
    Write-Log "Cannot find '$DriverListFile' in script directory. Aborting." 'ERROR'
    Write-Host ''
    Write-Host "  Create '$DriverListFile' next to this script with one driver folder name per line." -ForegroundColor Red
    Read-Host '  Press Enter to exit'
    exit 1
}

$FolderList = Get-Content $ListPath |
    ForEach-Object { $_.Trim() } |
    Where-Object   { $_ -ne '' -and -not $_.StartsWith('#') }

if ($FolderList.Count -eq 0) {
    Write-Log "'$DriverListFile' contains no entries. Aborting." 'WARN'
    Read-Host '  Press Enter to exit'
    exit 1
}

Write-Log "Folders to process: $($FolderList.Count)"
Write-Host ''

# --- Install loop ---
$Results = [System.Collections.Generic.List[object]]::new()
$Total   = $FolderList.Count
$Index   = 0

foreach ($Folder in $FolderList) {
    $Index++
    Write-Host ''
    Write-Host "  [$Index/$Total] $Folder" -ForegroundColor White
    Write-Host ('-' * 56) -ForegroundColor DarkGray

    $Result = Install-DriverFolder -FolderName $Folder
    $Results.Add($Result)
}

# --- Summary table ---
Write-Host ''
Write-Host ('=' * 60) -ForegroundColor DarkGray
Write-Host '  Summary' -ForegroundColor White
Write-Host ('=' * 60) -ForegroundColor DarkGray

$Header = '{0,-28} {1,-8} {2}' -f 'Folder', 'Exit', 'Status'
Write-Host $Header -ForegroundColor DarkGray
Write-Host ('-' * 60) -ForegroundColor DarkGray

foreach ($R in $Results) {
    $Color = switch -Wildcard ($R.Status) {
        'OK*'     { 'Green'  }
        'WARN'    { 'Yellow' }
        'SKIPPED' { 'Yellow' }
        default   { 'Red'    }
    }
    $Label = if ($R.Folder.Length -gt 27) { $R.Folder.Substring(0,24) + '...' } else { $R.Folder }
    Write-Host ('{0,-28} {1,-8} {2}' -f $Label, $R.ExitCode, $R.Status) -ForegroundColor $Color
}

Write-Host ('-' * 60) -ForegroundColor DarkGray

$OK      = ($Results | Where-Object { $_.Status -like 'OK*' }).Count
$Warned  = ($Results | Where-Object { $_.Status -eq 'WARN' }).Count
$Skipped = ($Results | Where-Object { $_.Status -eq 'SKIPPED' }).Count
$Failed  = ($Results | Where-Object { $_.Status -eq 'FAILED' }).Count

Write-Host "  OK: $OK   Warnings: $Warned   Skipped: $Skipped   Failed: $Failed" -ForegroundColor White
Write-Log  "Summary — OK: $OK | Warnings: $Warned | Skipped: $Skipped | Failed: $Failed"
Write-Host ''

# --- Reboot ---
if (($OK + $Warned) -gt 0) {
    Show-RebootCountdown -Seconds $RebootCountdownSec
} else {
    Write-Log "Nothing installed successfully — skipping reboot." 'WARN'
    Write-Host '  No reboot scheduled. Resolve the issues above and re-run.' -ForegroundColor Yellow
    Write-Host ''
}
