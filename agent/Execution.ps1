function Invoke-GemmaPermissionCommand {
    param([ValidateSet('ask','autopilot')][string]$Mode)
    $script:ExecutionPermission = $Mode
    if ($Mode -eq 'ask') {
        Write-Host '[Local command permission mode: ASK | each requested command requires confirmation; Enter = Yes.]' -ForegroundColor Cyan
    } else {
        Write-Host '[Local command permission mode: AUTOPILOT | requested commands execute without confirmation.]' -ForegroundColor Yellow
    }
}

function Invoke-GemmaPowerShellTool {
    param([string]$Command, [bool]$Elevated = $false)
    if ([string]::IsNullOrWhiteSpace($Command)) { throw 'run_powershell requires a command.' }

    $executionHost = if ($Elevated) { 'Administrator via Windows UAC' } else { 'PowerShell execution host' }
    Write-Host ([Environment]::NewLine + "[Local command requested by model ($executionHost)]:") -ForegroundColor DarkYellow
    Write-Host $Command -ForegroundColor Gray
    if ($script:ExecutionPermission -eq 'ask' -and -not $Elevated) {
        $approval = Read-Host 'Execute this command? [Y/n]'
        if ($approval -match '^(?i:n|no)

    if ($Elevated) {
        $previousApprovedToolState = $script:InApprovedPowerShellTool
        try {
            $script:InApprovedPowerShellTool = $true
            return Invoke-GemmaElevatedPowerShellTool -Command $Command
        } finally {
            $script:InApprovedPowerShellTool = $previousApprovedToolState
        }
    }

    $previousProgressPreference = $ProgressPreference
    $previousInformationPreference = $InformationPreference
    $previousApprovedToolState = $script:InApprovedPowerShellTool
    try {
        $script:InApprovedPowerShellTool = $true
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'
        $output = Invoke-Expression $Command *>&1 | Out-String -Width $MIRA_POWERSHELL_OUTPUT_WIDTH
        if ($output.Length -gt $MIRA_MAX_POWERSHELL_OUTPUT_CHARS) { $output = $output.Substring(0,$MIRA_MAX_POWERSHELL_OUTPUT_CHARS) + [Environment]::NewLine + '[PowerShell output truncated]' }
        return @{ approved=$true; output=$output; current_location=(Get-Location).Path }
    } catch { return @{ approved=$true; error=$_.Exception.Message } }
    finally {
        $ProgressPreference = $previousProgressPreference
        $InformationPreference = $previousInformationPreference
        $script:InApprovedPowerShellTool = $previousApprovedToolState
    }
}

function Invoke-GemmaElevatedPowerShellTool {
    param([Parameter(Mandatory = $true)][string]$Command)

    $token = [guid]::NewGuid().ToString('N')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('gemma-elevated-' + $token + '.out')
    $statusPath = Join-Path ([IO.Path]::GetTempPath()) ('gemma-elevated-' + $token + '.status')
    $location = Get-Location

    try {
        $commandBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
        $outputPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($outputPath))
        $statusPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($statusPath))
        $locationPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$location.Path))
        $width = [int]$MIRA_POWERSHELL_OUTPUT_WIDTH

        # The elevated child writes its output and exit status to per-invocation
        # temporary files. This works with ShellExecute/UAC, where standard
        # output redirection cannot be relied on.
        $childScript = @'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__COMMAND_B64__'))
$outputPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__OUTPUT_PATH_B64__'))
$statusPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__STATUS_PATH_B64__'))
$locationPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__LOCATION_PATH_B64__'))
$width = [int]'__OUTPUT_WIDTH__'
$result = @()
$exitCode = 0
try {
    if (-not [string]::IsNullOrWhiteSpace($locationPath)) {
        try { Set-Location -LiteralPath $locationPath -ErrorAction Stop } catch {}
    }
    $result = @(Invoke-Expression -Command $command *>&1)
    if ($null -ne $global:LASTEXITCODE) { $exitCode = [int]$global:LASTEXITCODE }
} catch {
    $result = @($_)
    $exitCode = 1
}
try {
    $rendered = ''
    if ($result.Count -gt 0) { $rendered = [string]($result | Out-String -Width $width) }
    [IO.File]::WriteAllText($outputPath, $rendered, [System.Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText($statusPath, [string]$exitCode, [Text.Encoding]::ASCII)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
exit $exitCode
'@
        $childScript = $childScript.Replace('__COMMAND_B64__', $commandBase64)
        $childScript = $childScript.Replace('__OUTPUT_PATH_B64__', $outputPathBase64)
        $childScript = $childScript.Replace('__STATUS_PATH_B64__', $statusPathBase64)
        $childScript = $childScript.Replace('__LOCATION_PATH_B64__', $locationPathBase64)
        $childScript = $childScript.Replace('__OUTPUT_WIDTH__', [string]$width)
        $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

        $powerShellExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ([string]::IsNullOrWhiteSpace($powerShellExe) -or -not (Test-Path -LiteralPath $powerShellExe)) {
            $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }

        $workingDirectory = [Environment]::CurrentDirectory
        if ($location.Provider.Name -eq 'FileSystem' -and
            -not [string]::IsNullOrWhiteSpace([string]$location.ProviderPath)) {
            $workingDirectory = [string]$location.ProviderPath
        }
        if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
            $workingDirectory = $env:SystemRoot
        }

        $process = Start-Process -FilePath $powerShellExe -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-EncodedCommand', $encodedScript
        ) -Verb RunAs -WindowStyle Hidden -WorkingDirectory $workingDirectory -Wait -PassThru -ErrorAction Stop

        $output = ''
        if (Test-Path -LiteralPath $outputPath) {
            $output = [IO.File]::ReadAllText($outputPath, [Text.Encoding]::UTF8)
        }
        if ($output.Length -gt $MIRA_MAX_POWERSHELL_OUTPUT_CHARS) {
            $output = $output.Substring(0,$MIRA_MAX_POWERSHELL_OUTPUT_CHARS) + [Environment]::NewLine + '[Elevated PowerShell output truncated]'
        }

        $exitCode = [int]$process.ExitCode
        if (Test-Path -LiteralPath $statusPath) {
            $statusText = [IO.File]::ReadAllText($statusPath, [Text.Encoding]::ASCII).Trim()
            $parsedExitCode = 0
            if ([int]::TryParse($statusText, [ref]$parsedExitCode)) { $exitCode = $parsedExitCode }
        } else {
            return @{
                approved = $true
                elevated = $true
                output = $output
                exit_code = $exitCode
                error = 'Elevated PowerShell exited without writing its completion status.'
                current_location = [string]$location.Path
            }
        }

        return @{
            approved = $true
            elevated = $true
            output = $output
            exit_code = $exitCode
            current_location = [string]$location.Path
        }
    } catch {
        $nativeErrorCode = 0
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception -is [System.ComponentModel.Win32Exception]) {
                $nativeErrorCode = [int]$exception.NativeErrorCode
                break
            }
            $exception = $exception.InnerException
        }
        if ($nativeErrorCode -eq 1223) {
            return @{ approved=$false; elevated=$true; cancelled=$true; output='Windows UAC elevation was cancelled by the user.' }
        }
        return @{ approved=$false; elevated=$true; error=$_.Exception.Message }
    } finally {
        foreach ($temporaryPath in @($outputPath,$statusPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ==============================================================================

function Invoke-GemmaQuickWeb {
    param([ValidateSet('weather','public-ip','cheatsheet')][string]$Action,[string]$Query = '')
    switch ($Action) {
        'weather' {
            $location = $Query.Trim()
            $url = if ($location) { 'https://wttr.in/' + [Uri]::EscapeDataString($location) + '?format=3' } else { 'https://wttr.in/?format=3' }
        }
        'public-ip' { $url = 'https://api.ipify.org' }
        'cheatsheet' {
            $topic = $Query.Trim().Trim('/')
            if (-not $topic) { $url = 'https://cht.sh/' }
            else {
                $encoded = (@($topic -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
                $url = 'https://cht.sh/' + $encoded
            }
        }
    }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        $result = & $curl.Source -fsS --max-time 15 --max-filesize 50000 $url 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "Quick web request failed (curl exit $exitCode): $([string]::Join(' ',@($result)))" }
        return [string]::Join([Environment]::NewLine,@($result))
    }
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    return [string]$response.Content
}
) {
            return @{ approved=$false; elevated=$false; output='User declined command execution.' }
        }
    }

    if ($Elevated) {
        $previousApprovedToolState = $script:InApprovedPowerShellTool
        try {
            $script:InApprovedPowerShellTool = $true
            return Invoke-GemmaElevatedPowerShellTool -Command $Command
        } finally {
            $script:InApprovedPowerShellTool = $previousApprovedToolState
        }
    }

    $previousProgressPreference = $ProgressPreference
    $previousInformationPreference = $InformationPreference
    $previousApprovedToolState = $script:InApprovedPowerShellTool
    try {
        $script:InApprovedPowerShellTool = $true
        $ProgressPreference = 'SilentlyContinue'
        $InformationPreference = 'SilentlyContinue'
        $output = Invoke-Expression $Command *>&1 | Out-String -Width $MIRA_POWERSHELL_OUTPUT_WIDTH
        if ($output.Length -gt $MIRA_MAX_POWERSHELL_OUTPUT_CHARS) { $output = $output.Substring(0,$MIRA_MAX_POWERSHELL_OUTPUT_CHARS) + [Environment]::NewLine + '[PowerShell output truncated]' }
        return @{ approved=$true; output=$output; current_location=(Get-Location).Path }
    } catch { return @{ approved=$true; error=$_.Exception.Message } }
    finally {
        $ProgressPreference = $previousProgressPreference
        $InformationPreference = $previousInformationPreference
        $script:InApprovedPowerShellTool = $previousApprovedToolState
    }
}

function Invoke-GemmaElevatedPowerShellTool {
    param([Parameter(Mandatory = $true)][string]$Command)

    $token = [guid]::NewGuid().ToString('N')
    $outputPath = Join-Path ([IO.Path]::GetTempPath()) ('gemma-elevated-' + $token + '.out')
    $statusPath = Join-Path ([IO.Path]::GetTempPath()) ('gemma-elevated-' + $token + '.status')
    $location = Get-Location

    try {
        $commandBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($Command))
        $outputPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($outputPath))
        $statusPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($statusPath))
        $locationPathBase64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes([string]$location.Path))
        $width = [int]$MIRA_POWERSHELL_OUTPUT_WIDTH

        # The elevated child writes its output and exit status to per-invocation
        # temporary files. This works with ShellExecute/UAC, where standard
        # output redirection cannot be relied on.
        $childScript = @'
$ErrorActionPreference = 'Continue'
$ProgressPreference = 'SilentlyContinue'
$InformationPreference = 'SilentlyContinue'
$command = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__COMMAND_B64__'))
$outputPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__OUTPUT_PATH_B64__'))
$statusPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__STATUS_PATH_B64__'))
$locationPath = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('__LOCATION_PATH_B64__'))
$width = [int]'__OUTPUT_WIDTH__'
$result = @()
$exitCode = 0
try {
    if (-not [string]::IsNullOrWhiteSpace($locationPath)) {
        try { Set-Location -LiteralPath $locationPath -ErrorAction Stop } catch {}
    }
    $result = @(Invoke-Expression -Command $command *>&1)
    if ($null -ne $global:LASTEXITCODE) { $exitCode = [int]$global:LASTEXITCODE }
} catch {
    $result = @($_)
    $exitCode = 1
}
try {
    $rendered = ''
    if ($result.Count -gt 0) { $rendered = [string]($result | Out-String -Width $width) }
    [IO.File]::WriteAllText($outputPath, $rendered, (New-Object System.Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText($statusPath, [string]$exitCode, [Text.Encoding]::ASCII)
} catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
exit $exitCode
'@
        $childScript = $childScript.Replace('__COMMAND_B64__', $commandBase64)
        $childScript = $childScript.Replace('__OUTPUT_PATH_B64__', $outputPathBase64)
        $childScript = $childScript.Replace('__STATUS_PATH_B64__', $statusPathBase64)
        $childScript = $childScript.Replace('__LOCATION_PATH_B64__', $locationPathBase64)
        $childScript = $childScript.Replace('__OUTPUT_WIDTH__', [string]$width)
        $encodedScript = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($childScript))

        $powerShellExe = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        if ([string]::IsNullOrWhiteSpace($powerShellExe) -or -not (Test-Path -LiteralPath $powerShellExe)) {
            $powerShellExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        }

        $workingDirectory = [Environment]::CurrentDirectory
        if ($location.Provider.Name -eq 'FileSystem' -and
            -not [string]::IsNullOrWhiteSpace([string]$location.ProviderPath)) {
            $workingDirectory = [string]$location.ProviderPath
        }
        if (-not (Test-Path -LiteralPath $workingDirectory -PathType Container)) {
            $workingDirectory = $env:SystemRoot
        }

        $process = Start-Process -FilePath $powerShellExe -ArgumentList @(
            '-NoLogo', '-NoProfile', '-NonInteractive',
            '-EncodedCommand', $encodedScript
        ) -Verb RunAs -WindowStyle Hidden -WorkingDirectory $workingDirectory -Wait -PassThru -ErrorAction Stop

        $output = ''
        if (Test-Path -LiteralPath $outputPath) {
            $output = [IO.File]::ReadAllText($outputPath, [Text.Encoding]::UTF8)
        }
        if ($output.Length -gt $MIRA_MAX_POWERSHELL_OUTPUT_CHARS) {
            $output = $output.Substring(0,$MIRA_MAX_POWERSHELL_OUTPUT_CHARS) + [Environment]::NewLine + '[Elevated PowerShell output truncated]'
        }

        $exitCode = [int]$process.ExitCode
        if (Test-Path -LiteralPath $statusPath) {
            $statusText = [IO.File]::ReadAllText($statusPath, [Text.Encoding]::ASCII).Trim()
            $parsedExitCode = 0
            if ([int]::TryParse($statusText, [ref]$parsedExitCode)) { $exitCode = $parsedExitCode }
        } else {
            return @{
                approved = $true
                elevated = $true
                output = $output
                exit_code = $exitCode
                error = 'Elevated PowerShell exited without writing its completion status.'
                current_location = [string]$location.Path
            }
        }

        return @{
            approved = $true
            elevated = $true
            output = $output
            exit_code = $exitCode
            current_location = [string]$location.Path
        }
    } catch {
        $nativeErrorCode = 0
        $exception = $_.Exception
        while ($null -ne $exception) {
            if ($exception -is [System.ComponentModel.Win32Exception]) {
                $nativeErrorCode = [int]$exception.NativeErrorCode
                break
            }
            $exception = $exception.InnerException
        }
        if ($nativeErrorCode -eq 1223) {
            return @{ approved=$false; elevated=$true; cancelled=$true; output='Windows UAC elevation was cancelled by the user.' }
        }
        return @{ approved=$false; elevated=$true; error=$_.Exception.Message }
    } finally {
        foreach ($temporaryPath in @($outputPath,$statusPath)) {
            if (Test-Path -LiteralPath $temporaryPath) {
                Remove-Item -LiteralPath $temporaryPath -Force -ErrorAction SilentlyContinue
            }
        }
    }
}

# ==============================================================================

function Invoke-GemmaQuickWeb {
    param([ValidateSet('weather','public-ip','cheatsheet')][string]$Action,[string]$Query = '')
    switch ($Action) {
        'weather' {
            $location = $Query.Trim()
            $url = if ($location) { 'https://wttr.in/' + [Uri]::EscapeDataString($location) + '?format=3' } else { 'https://wttr.in/?format=3' }
        }
        'public-ip' { $url = 'https://api.ipify.org' }
        'cheatsheet' {
            $topic = $Query.Trim().Trim('/')
            if (-not $topic) { $url = 'https://cht.sh/' }
            else {
                $encoded = (@($topic -split '/') | ForEach-Object { [Uri]::EscapeDataString($_) }) -join '/'
                $url = 'https://cht.sh/' + $encoded
            }
        }
    }
    $curl = Get-Command curl.exe -ErrorAction SilentlyContinue
    if ($null -ne $curl) {
        $result = & $curl.Source -fsS --max-time 15 --max-filesize 50000 $url 2>&1
        $exitCode = $LASTEXITCODE
        if ($exitCode -ne 0) { throw "Quick web request failed (curl exit $exitCode): $([string]::Join(' ',@($result)))" }
        return [string]::Join([Environment]::NewLine,@($result))
    }
    $response = Invoke-WebRequest -Uri $url -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
    return [string]$response.Content
}
