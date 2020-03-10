#!/usr/bin/env pwsh

<#
.SYNOPSIS
Installs PowerShell profiles for the current user.

.DESCRIPTION

The `install.ps1` script sets up the PowerShell profiles in this repository for the current user by creating the profile script at the standard location in which PowerShell looks for it.  This script uses the current PowerShell session to find the proper profile script path with `$PROFILE.CurrentUserAllHosts`. Therefore, you must run this script separatly for Windows PowerShell and PowerShell Core.

Pass the name of the profiles in the `profiles` directory that you'd like to enable in the PowerShell profile.

Use `-Force` to overwriting an existing profile script if one already exists.

This script uses the [EPS (Embedded PowerShell)](https://github.com/straightdave/eps) module to add content to the profile script.

.EXAMPLE
./install.ps1 -Profile 'decoyjoe', 'psreadline'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    # List of profile names, from the `profiles` directory, to enable in the PowerShell profile script.
    [String[]]$ProfileName,

    [Parameter(Mandatory)]
    # Name of theme to set in the profile.
    [String]$ThemeName,

    # Overwrite an existing profile script.
    [switch]$Force
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 'Latest'

foreach ($item in $ProfileName)
{
    $profilePath = Join-Path -Path $PSScriptRoot -ChildPath ('profiles/{0}.ps1' -f $item)
    if (-not (Test-Path -Path $profilePath -PathType Leaf))
    {
        Write-Error -Message ('Profile "{0}" does not exist. I looked for it at "{1}".' -f $item, $profilePath)
        return
    }
}

$defaultProfilePath = Join-Path -Path $PSScriptRoot -ChildPath 'default.profile.eps' -Resolve
$destinationProfilePath = $PROFILE.CurrentUserAllHosts

if ((Test-Path -Path $destinationProfilePath -PathType Leaf) -and -not $Force)
{
    Write-Error -Message ('Profile already exists at "{0}". Use the -Force switch to overwrite the existing profile.' -f $destinationProfilePath)
    return
}

New-Item -Path ($destinationProfilePath | Split-Path -Parent) -ItemType Container -Force | Write-Verbose
Copy-Item -Path $defaultProfilePath -Destination $destinationProfilePath -Force

# Install any modules necessary for the install script or used by any profiles
# I only want to have to do this once and not re-check for modules everytime the
# profiles are loaded
$modulesToInstall = @(
    'EPS'
    'oh-my-posh'
    'Pester'
    'posh-git'
)

foreach ($module in $modulesToInstall)
{
    if( -not (Get-Module $module -ListAvailable -Verbose:$false) )
    {
        $repository = Find-Module -Name $module | Select-Object -First 1 -ExpandProperty 'Repository'
        Write-Verbose -Message 'Installing EPS module'
        Install-Module -Name $module -Scope CurrentUser -Repository $repository -Verbose:$false
    }
}

Import-Module -Name 'EPS' -Verbose:$false

$templateBindings = @{
    'profilesRepoRoot' = $PSScriptRoot
    'profilesToLoad'   = $ProfileName
    'myThemesLocation' = (Join-Path -Path $PSScriptRoot -ChildPath 'oh-my-posh_themes' -Resolve)
    'themeName'        = $ThemeName
}

$profileContent = Invoke-EpsTemplate -Path $destinationProfilePath -Safe -Binding $templateBindings
Set-Content -Path $destinationProfilePath -Value $profileContent -Force -NoNewline
