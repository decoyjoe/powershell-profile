#requires -Version 2 -Modules posh-git
# Adapted from: https://github.com/JanDeDobbeleer/oh-my-posh/blob/master/Themes/pure.psm1

function Write-Theme {
    param(
        [bool]
        $lastCommandFailed,
        [string]
        $with
    )

    #check the last command state and indicate if failed
    $promtSymbolColor = $sl.Colors.PromptSymbolColor
    if ($lastCommandFailed) {
        $promtSymbolColor = $sl.Colors.WithForegroundColor
    }

    $prompt = Set-Newline

    # Check for elevated prompt
    if (Test-Administrator) {
        $prompt += Write-Prompt -Object "$($sl.PromptSymbols.ElevatedSymbol) " -ForegroundColor $sl.Colors.AdminIconForegroundColor -BackgroundColor $sl.Colors.SessionInfoBackgroundColor
    }

    # Writes the drive portion
    $drive = Get-FullPath -dir $pwd
    $prompt += Write-Prompt -Object $drive -ForegroundColor $sl.Colors.DriveForegroundColor

    $prompt +=  Write-Prompt -Object ' '

    $status = Get-VCSStatus
    if ($status) {
        $prompt += Write-Prompt -Object "$($status.Branch)" -ForegroundColor $sl.Colors.GitDefaultColor
        if ($status.Working.Length -gt 0) {
            $prompt += Write-Prompt -Object (" " + $sl.PromptSymbols.GitDirtyIndicator + ' ') -ForegroundColor $sl.Colors.GitDirtyIndicatorColor
        }
    }

    function Get-CommandExecutionTime
    {
        <#
        .Synopsis
            Get the time span elapsed during the execution of command (by default the previous command)
        .Description
            Calls Get-History to return a single command and returns the difference between the Start and End execution time
        .NOTES
            Adapted from: https://github.com/Jaykul/PowerLine/blob/master/Source/Public/Get-Elapsed.ps1
        #>
        [CmdletBinding()]
        param(
            # The command ID to get the execution time for (defaults to the previous command)
            [Parameter()]
            [int]$Id,

            # A Timespan format pattern such as "{0:ss\.ffff}"
            [Parameter()]
            [string]$Format = '{0:h\:mm\:ss\.ffff}'
        )
        $null = $PSBoundParameters.Remove('Format')
        $LastCommand = Get-History -Count 1 @PSBoundParameters
        if(-not $LastCommand) { return '' }
        $Duration = $LastCommand.EndExecutionTime - $LastCommand.StartExecutionTime
        $Format -f $Duration
    }

    # Add timestamp
    $timestamp = Get-Date -Format T
    $elapsed = Get-CommandExecutionTime -Format '{0:m\:ss\.ff}'
    $elapsedTimestamp = ' [{0} | {1}]' -f $elapsed, $timestamp
    $prompt += Set-CursorForRightBlockWrite -textLength ($elapsedTimestamp.Length)
    $prompt += Write-Prompt $elapsedTimestamp -ForegroundColor $sl.Colors.PromptForegroundColor

    # New line
    $prompt += Set-Newline

    # Writes the postfixes to the prompt
    $prompt += Write-Prompt -Object ($sl.PromptSymbols.PromptIndicator) -ForegroundColor $promtSymbolColor

    $prompt += ' '
    $prompt
}

# https://github.com/PowerShell/PSReadLine/issues/1541
$esc = [char]0x1b # escape character
$pc = [char]0x276f # prompt character ❯

Set-PSReadLineOption -PromptText (
    "$esc[92m$pc$esc[0m ", # Bright Green
    "$esc[91m$pc$esc[0m "  # Bright Red
)

$sl = $global:ThemeSettings #local settings
$sl.PromptSymbols.PromptIndicator = [char]::ConvertFromUtf32(0x276f)
$sl.Colors.PromptSymbolColor = [ConsoleColor]::Green
$sl.Colors.PromptHighlightColor = [ConsoleColor]::Blue
$sl.Colors.DriveForegroundColor = [ConsoleColor]::Cyan
$sl.Colors.WithForegroundColor = [ConsoleColor]::Red
$sl.PromptSymbols.GitDirtyIndicator = [char]::ConvertFromUtf32(10007)
$sl.Colors.GitDefaultColor =[ConsoleColor]::Yellow
$sl.Colors.GitDirtyIndicatorColor =[ConsoleColor]::Red