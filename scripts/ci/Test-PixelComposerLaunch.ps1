param(
    [Parameter(Mandatory = $true)][string]$ExePath,
    [Parameter(Mandatory = $true)][string]$WorkingDirectory,
    [string]$Label = 'Pixel Composer',
    [int]$TimeoutSeconds = 45,
    [int]$StableSeconds = 10
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName UIAutomationClient

function Get-ErrorWindowText([IntPtr]$Handle) {
    try {
        $root = [System.Windows.Automation.AutomationElement]::FromHandle($Handle)
        if (-not $root) { return '' }

        $lines = [System.Collections.Generic.List[string]]::new()
        if (-not [string]::IsNullOrWhiteSpace($root.Current.Name)) {
            $lines.Add($root.Current.Name)
        }
        $all = $root.FindAll(
            [System.Windows.Automation.TreeScope]::Descendants,
            [System.Windows.Automation.Condition]::TrueCondition
        )
        for ($i = 0; $i -lt $all.Count; $i++) {
            $name = $all.Item($i).Current.Name
            if (-not [string]::IsNullOrWhiteSpace($name) -and -not $lines.Contains($name)) {
                $lines.Add($name)
            }
        }
        return ($lines -join "`n")
    } catch {
        return "Unable to inspect error window: $($_.Exception.Message)"
    }
}

$stdout = Join-Path $env:RUNNER_TEMP (([IO.Path]::GetFileNameWithoutExtension($ExePath)) + '-stdout.log')
$stderr = Join-Path $env:RUNNER_TEMP (([IO.Path]::GetFileNameWithoutExtension($ExePath)) + '-stderr.log')
$process = Start-Process -FilePath $ExePath -WorkingDirectory $WorkingDirectory -RedirectStandardOutput $stdout -RedirectStandardError $stderr -PassThru
$deadline = (Get-Date).AddSeconds($TimeoutSeconds)
$healthySince = $null
$healthyTitle = $null
$failure = $null

try {
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Milliseconds 250
        $process.Refresh()

        if ($process.HasExited) {
            $failure = "$Label exited during startup with code $($process.ExitCode)."
            break
        }

        if ($process.MainWindowHandle -ne [IntPtr]::Zero) {
            $title = $process.MainWindowTitle
            if ($title -match '(?i)(code\s+error|fatal\s+error|runtime\s+error|exception|crash|\berror\b)') {
                $details = Get-ErrorWindowText $process.MainWindowHandle
                $failure = "$Label opened an error window titled '$title'.`n$details"
                break
            }

            if (-not [string]::IsNullOrWhiteSpace($title)) {
                if ($null -eq $healthySince -or $healthyTitle -ne $title) {
                    $healthySince = Get-Date
                    $healthyTitle = $title
                    Write-Host "$Label normal window detected: '$title'. Verifying it remains healthy..."
                } elseif (((Get-Date) - $healthySince).TotalSeconds -ge $StableSeconds) {
                    Write-Host "$Label remained alive with normal window '$title' for at least $StableSeconds seconds."
                    break
                }
            }
        }
    }

    if (-not $failure -and $null -eq $healthySince) {
        $failure = "$Label stayed alive but never created a normal top-level window within $TimeoutSeconds seconds."
    } elseif (-not $failure -and ((Get-Date) - $healthySince).TotalSeconds -lt $StableSeconds) {
        $failure = "$Label created '$healthyTitle' but did not remain healthy for $StableSeconds seconds before the timeout."
    }

    $output = ''
    if (Test-Path $stdout) { $output += Get-Content -Raw $stdout }
    if (Test-Path $stderr) { $output += "`n" + (Get-Content -Raw $stderr) }

    if (-not $failure -and $output -match 'Unable to find function|Could not find function|Could not locate initialization function|ERROR in action number|Fatal Error|Code Error') {
        $failure = "$Label reported a startup error in its console output."
    }

    if ($failure) {
        throw "$failure`n--- process output ---`n$output"
    }
} finally {
    if ($process -and -not $process.HasExited) {
        Stop-Process -Id $process.Id -Force
    }
}
