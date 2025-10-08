#!/usr/bin/env pwsh

<#
.SYNOPSIS
Installs PowerShell profiles for the current user.

.DESCRIPTION

The `install.ps1` script sets up the PowerShell profiles in this repository for the current user by creating the profile
script at the standard location in which PowerShell looks for it. The script checks for both Windows PowerShell and
PowerShell Core, and installs the profile for each one found. I.e. this script is compatible with Windows, macOS, and
Linux.

The script uses `$PROFILE.CurrentUserAllHosts` to resolve the path to the PowerShell profile script to create.

Pass the name of the profiles in the `profiles` directory that you'd like to enable in the PowerShell profile.

Use `-Force` to overwriting an existing profile script if one already exists.

.EXAMPLE
./install.ps1

Demonstrates installing the PowerShell profile with all defaults.

.EXAMPLE
./install.ps1 -Profile 'default', 'psreadline' -Theme 'decoyjoe.pure'

Demonstrates installing the PowerShell profile with specific profiles and a specific theme.
#>
[CmdletBinding()]
param(
    # List of profile names, from the `profiles` directory, to enable in the PowerShell profile.
    [String[]] $ProfileName = @('default', 'psreadline'),

    # Name of theme to set in the profile.
    [String] $ThemeName = 'decoyjoe.pure',

    # Overwrite an existing profile.
    [switch] $Force
)

$InformationPreference = 'Continue'
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 'Latest'

foreach ($profileItem in $ProfileName) {
    $profilePath = Join-Path -Path $PSScriptRoot -ChildPath "profiles/$($profileItem).ps1"

    if (-not (Test-Path -Path $profilePath -PathType Leaf)) {
        $msg = "Profile ""$($profileItem)"" does not exist. I looked for it under ""$($profilePath)""."
        Write-Error -Message $msg -ErrorAction Stop
    }
}

# Install any modules necessary for the install script or used by any profiles. I only want to have to do this once and
# not include logic in the profile to check for required modules everytime the profiles are loaded.
$modules = @{
    'oh-my-posh' = '2.*'
    'Pester' = '5.*'
    'posh-git' = '0.*'
}

$installedModules = Get-Module -ListAvailable

foreach ($module in $modules.Keys)
{
    $desiredVersion = $modules[$module]
    $allModuleVersions = Find-Module -Name $module -AllVersions

    $moduleToInstall =
        $allModuleVersions |
        Where-Object { $_.Version -like $desiredVersion } |
        Select-Object -First 1

    if (-not $moduleToInstall)
    {
        $msg = "Module ""$($module)"" with version like ""$($desiredVersion)"" was not found via ""Find-Module"". " +
               "Versions found: [$($allModuleVersions.Version -join ', ')]"

        Write-Error -Message $msg -ErrorAction Stop
        return
    }

    $desiredVersionInstalled =
        $installedModules |
        Where-Object { $_.Name -eq $module } |
        Where-Object { $_.Version -eq $moduleToInstall.Version }

    $moduleVersion = $moduleToInstall.Version

    if (-not $desiredVersionInstalled)
    {
        Write-Information "Installing $($module) $($moduleVersion) for current user."
        Install-Module -Name $module `
                      -Scope CurrentUser `
                      -Repository $moduleToInstall.Repository `
                      -RequiredVersion $moduleVersion `
                      -Verbose:$false
    }
    else
    {
        Write-Information "$($module) $($moduleVersion) already installed."
    }
}

$repoProfilePs1 = Join-Path -Path $PSScriptRoot -ChildPath 'profile.ps1' -Resolve
$profilePs1PathEvalCommand = '$PROFILE.CurrentUserAllHosts'

foreach ($command in @('powershell.exe', 'pwsh')) {
    if (-not (Get-Command -Name $command -ErrorAction Ignore)) { continue }

    $profilePs1Path = & $command -NoLogo -NoProfile -Command $profilePs1PathEvalCommand
    $existingProfilePs1 = Get-Item -Path $profilePs1Path -ErrorAction Ignore

    if ($existingProfilePs1) {
        if (-not $Force)
        {
            $msg = "PowerShell profile script ""$($profilePs1Path)"" already exists. Use -Force to overwrite it."
            Write-Error -Message $msg -ErrorAction Stop
        }

        Remove-Item -Path $profilePs1Path -Force
    }

    $profileContent = "& ""$($repoProfilePs1)"""

    Write-Information "Creating ""$($profilePs1Path)"" which executes ""$($repoProfilePs1)"""
    New-Item -Path $profilePs1Path -Value $profileContent -Force | Write-Verbose
}

$homeDir = Resolve-Path -Path '~' | Select-Object -ExpandProperty 'ProviderPath'
$profileConfig = Join-Path -Path $homeDir -ChildPath '.powershell-profile-config.json'

if (Test-Path -Path $profileConfig -PathType Leaf) {
    if (-not $Force) {
        $msg = "PowerShell profile already installed ($($profileConfig)). Use the -Force switch to overwrite the " +
               "existing profile."
        Write-Error -Message $msg -ErrorAction Stop
    }

    Remove-Item -Path $profileConfig -Force
}

Write-Information "Profile config ""$($profileConfig)"""

@{
    ProfilesToLoad = $ProfileName
    Theme = $ThemeName
} | ConvertTo-Json | New-Item -Path $profileConfig -Force | Write-Verbose
