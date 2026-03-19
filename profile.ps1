
function Global:Import-Profile
{
    [CmdletBinding()]
    param(
        # Don't set the theme/prompt
        [switch]$SkipTheme
    )

    if ($PSBoundParameters.Keys.Contains('Debug'))
    {
        $DebugPreference = 'Continue'
    }

    Write-Debug -Message ('[0000ms]  [BEGIN] {0}' -f $MyInvocation.MyCommand)
    $Global:timingIndentCount = 4

    $startedAt = Get-Date
    function Write-Timing
    {
        param(
            [Parameter(Mandatory)]
            [ValidateSet('BEGIN','COMPLETE')]
            [string]$Status,

            [Parameter(Mandatory)]
            [string]$Message
        )

        if ($Status -eq 'COMPLETE') {
            $Global:timingIndentCount = $timingIndentCount - 2
            $messagePadding = 1
        }
        else {
            $messagePadding = 4
        }

        $elapsedMs = ((Get-Date) - $startedAt).TotalMilliseconds
        [int]$elapsedMs = [Math]::Round($elapsedMs)

        $indentation = ' ' * $timingIndentCount
        $padding = ' ' * $messagePadding

        Write-Debug -Message ('[{0:d4}ms]{1}[{2}]{3}{4}' -f $elapsedMs, $indentation, $Status, $padding, $Message)

        if ($Status -eq 'BEGIN') {
            $Global:timingIndentCount = $timingIndentCount + 2
        }
    }

    # https://github.com/PowerShell/PSReadLine/issues/1541#issuecomment-632899981
    [Console]::OutputEncoding = [System.Text.Encoding]::UTF8

    $homeDir = Resolve-Path -Path '~' | Select-Object -ExpandProperty 'ProviderPath'
    $profileConfig = Join-Path -Path $homeDir -ChildPath '.powershell-profile-config.json'

    if (-not (Test-Path -Path $profileConfig -PathType Leaf)) {
        $installPs1Path = Join-Path $PSScriptRoot -ChildPath 'install.ps1' -Resolve

        $err = "Local PowerShell profile configuration ""$($profileConfig)"" does not exist. Run: " +
               "$($installPs1Path)"
        Write-Error -Message $err -ErrorAction Stop
    }

    $config = [IO.File]::ReadAllText($profileConfig) | ConvertFrom-Json
    $profilesToLoad = $config.ProfilesToLoad

    if (-not $profilesToLoad)
    {
        Write-Warning -Message "No profiles to load defined in "$($profileConfig)"."
        return
    }

    $profilesRoot = Join-Path -Path $PSScriptRoot -ChildPath 'profiles' -Resolve
    foreach ($profileName in $profilesToLoad)
    {
        $profilePath = Join-Path -Path $profilesRoot -ChildPath "$($profileName).ps1"

        if (-not (Test-Path -Path $profilePath -PathType Leaf)) {
            $msg = "Profile ""$($profileName)"" does not exist under ""$($profilesRoot)"". Skipping."
            Write-Warning -Message $msg
            continue
        }

        # Execute profile scripts, don't dot-source them. Profile scripts should be explicit with what they export by
        # using the 'Global:' scope modifier.
        Write-Timing -Status 'BEGIN' -Message ('Load "{0}" profile' -f $profileName)
        & $profilePath
        Write-Timing -Status 'COMPLETE' -Message ('Load "{0}" profile' -f $profileName)
    }

    if (-not $SkipTheme)
    {
        $ohMyPoshMonkeyPatchSignal = Join-Path -Path $PSScriptRoot -ChildPath '.oh-my-posh-v2-monkey-patched'
        if (-not (Test-Path -Path $ohMyPoshMonkeyPatchSignal))
        {
            # oh-my-posh v2 has a hardcoded requirement on the "posh-git" module. Moneky-patch that requirement out.
            & (Join-Path -Path $PSScriptRoot -ChildPath 'Edit-OhMyPosh.ps1')
            Set-Content -Path $ohMyPoshMonkeyPatchSignal -Value (Get-Date)
        }

        Write-Timing -Status 'BEGIN' -Message 'Import module "oh-my-posh"'
        Import-Module -Name 'oh-my-posh'
        Write-Timing -Status 'COMPLETE' -Message 'Import module "oh-my-posh"'

        $themesLocation = Join-Path -Path $PSScriptRoot -ChildPath 'themes' -Resolve
        $Global:ThemeSettings.MyThemesLocation = $themesLocation # oh-my-posh uses $Global:ThemeSettings
        Set-Theme -Name $config.Theme
    }

    Write-Verbose -Message 'Profile Loaded'
    Write-Timing -Status 'COMPLETE' -Message $MyInvocation.MyCommand

    Remove-Variable -Name 'timingIndentCount' -Scope 'Global' -Force
}

Import-Profile
