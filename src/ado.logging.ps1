function Write-Log {
    param(
        [Parameter(Mandatory = $true)]
        [ValidateSet('Info', 'Debug', 'Warn', 'Error')]
        [string]$Level,

        [Parameter(Mandatory = $true)]
        [string]$Message
    )

    if ($Level -eq 'Debug' -and $LogLevel -ne 'Debug') {
        return
    }

    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss.fff'
    $runElapsed = $Script:RunStopwatch.Elapsed.ToString('hh\:mm\:ss\.fff')
    $stepElapsed = if ($Script:StepStopwatch.IsRunning) { $Script:StepStopwatch.Elapsed.ToString('hh\:mm\:ss\.fff') } else { '00:00:00.000' }
    $line = '[{0}] [{1}] [Run+{2}] [Step+{3}] {4}' -f $ts, $Level.ToUpperInvariant(), $runElapsed, $stepElapsed, $Message

    switch ($Level) {
        'Warn' { Write-Warning $line }
        'Error' { Write-Host $line -ForegroundColor Red }
        default { Write-Host $line }
    }

    if (-not [string]::IsNullOrWhiteSpace($Script:LogFilePath)) {
        Add-Content -Path $Script:LogFilePath -Value $line -Encoding UTF8
    }
}

function Start-Step {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name
    )

    $Script:CurrentStepName = $Name
    $Script:StepStopwatch.Restart()
    Write-Log -Level 'Info' -Message ('STEP START: {0}' -f $Name)
}

function Stop-Step {
    param(
        [Parameter(Mandatory = $false)]
        [string]$Result = 'OK'
    )

    if ($Script:StepStopwatch.IsRunning) {
        $Script:StepStopwatch.Stop()
    }

    if (-not [string]::IsNullOrWhiteSpace($Script:CurrentStepName)) {
        Write-Log -Level 'Info' -Message ('STEP END: {0} | Result={1}' -f $Script:CurrentStepName, $Result)
    }

    $Script:CurrentStepName = ''
}

function Assert-NotCancelled {
    if ([string]::IsNullOrWhiteSpace($Script:StopFilePath)) {
        return
    }

    if (Test-Path -LiteralPath $Script:StopFilePath) {
        Write-Log -Level 'Warn' -Message ('Cancellation requested. Stop file found: {0}' -f $Script:StopFilePath)
        throw 'Execution cancelled by user request.'
    }
}
