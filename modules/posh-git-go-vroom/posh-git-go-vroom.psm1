param([bool]$ForcePoshGitPrompt, [bool]$UseLegacyTabExpansion)

$debugTiming = $true

# ============================================================================
#region Initialization
# ============================================================================
$debugTimer = if ($debugTiming) { [System.Diagnostics.Stopwatch]::StartNew() }

function Write-DebugTiming
{
    param(
        [string] $Label
    )

    if (-not $debugTiming) { return }

    $debugTimer.Stop()
    Write-Host "[posh-git-go-vroom] [${Label}] $($debugTimer.ElapsedMilliseconds)ms" -ForegroundColor Cyan
    $debugTimer.Restart()
}

if (Test-Path Env:\POSHGIT_ENABLE_STRICTMODE) {
    # Set strict mode to latest to help catch scripting errors in the module. This is done by the Pester tests.
    Set-StrictMode -Version Latest
}
#endregion

# ============================================================================
#region CheckRequirements
# ============================================================================
$global:GitMissing = $false
$script:GitCygwin = $false

if (!(Get-Command git -TotalCount 1 -ErrorAction SilentlyContinue)) {
    Write-Warning "git command could not be found. Please create an alias or add it to your PATH."
    $global:GitMissing = $true
    return
}
Write-DebugTiming -Label 'CheckRequirements'
#endregion

# ============================================================================
#region ConsoleMode
# ============================================================================
# Hack! https://gist.github.com/lzybkr/f2059cb2ee8d0c13c65ab933b75e998c

# Always skip setting the console mode on non-Windows platforms.
if (($PSVersionTable.PSVersion.Major -ge 6) -and !$IsWindows) {
    function Set-ConsoleMode {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
        param()
    }

    return
}

$consoleModeSource = @"
using System;
using System.Runtime.InteropServices;

public class NativeConsoleMethods
{
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern IntPtr GetStdHandle(int handleId);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool GetConsoleMode(IntPtr hConsoleOutput, out uint dwMode);

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    public static extern bool SetConsoleMode(IntPtr hConsoleOutput, uint dwMode);

    public static uint GetConsoleMode(bool input = false)
    {
        var handle = GetStdHandle(input ? -10 : -11);
        uint mode;
        if (GetConsoleMode(handle, out mode))
        {
            return mode;
        }
        return 0xffffffff;
    }

    public static uint SetConsoleMode(bool input, uint mode)
    {
        var handle = GetStdHandle(input ? -10 : -11);
        if (SetConsoleMode(handle, mode))
        {
            return GetConsoleMode(input);
        }
        return 0xffffffff;
    }
}
"@

[Flags()]
enum ConsoleModeInputFlags
{
    ENABLE_PROCESSED_INPUT             = 0x0001
    ENABLE_LINE_INPUT                  = 0x0002
    ENABLE_ECHO_INPUT                  = 0x0004
    ENABLE_WINDOW_INPUT                = 0x0008
    ENABLE_MOUSE_INPUT                 = 0x0010
    ENABLE_INSERT_MODE                 = 0x0020
    ENABLE_QUICK_EDIT_MODE             = 0x0040
    ENABLE_EXTENDED_FLAGS              = 0x0080
    ENABLE_AUTO_POSITION               = 0x0100
    ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0200
}

[Flags()]
enum ConsoleModeOutputFlags
{
    ENABLE_PROCESSED_OUTPUT            = 0x0001
    ENABLE_WRAP_AT_EOL_OUTPUT          = 0x0002
    ENABLE_VIRTUAL_TERMINAL_PROCESSING = 0x0004
}

function Set-ConsoleMode
{
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
    param(
        [Parameter(ParameterSetName = "ANSI")]
        [switch]
        $ANSI,

        [Parameter(ParameterSetName = "Mode")]
        [uint32]
        $Mode,

        [switch]
        $StandardInput
    )

    begin {
        # Module import is speeded up by deferring the Add-Type until the first time this function is called.
        # Add the NativeConsoleMethods type but only once per session.
        if (!('NativeConsoleMethods' -as [System.Type])) {
            Add-Type $consoleModeSource
        }
    }

    end {
        if ($ANSI)
        {
            $outputMode = [NativeConsoleMethods]::GetConsoleMode($false)
            $null = [NativeConsoleMethods]::SetConsoleMode($false, $outputMode -bor [ConsoleModeOutputFlags]::ENABLE_VIRTUAL_TERMINAL_PROCESSING)

            if ($StandardInput)
            {
                $inputMode = [NativeConsoleMethods]::GetConsoleMode($true)
                $null = [NativeConsoleMethods]::SetConsoleMode($true, $inputMode -bor [ConsoleModeInputFlags]::ENABLE_VIRTUAL_TERMINAL_PROCESSING)
            }
        }
        else
        {
            [NativeConsoleMethods]::SetConsoleMode($StandardInput, $Mode)
        }
    }
}
Write-DebugTiming -Label 'ConsoleMode'
#endregion

# ============================================================================
#region Utils
# ============================================================================
# Store error records generated by stderr output when invoking an executable
# This can be accessed from the user's session by executing:
# PS> $m = Get-Module posh-git
# PS> & $m Get-Variable invokeErrors -ValueOnly
$invokeErrors = New-Object System.Collections.ArrayList 256

# General Utility Functions

function Invoke-NullCoalescing {
    $result = $null
    foreach ($arg in $args) {
        if ($arg -is [ScriptBlock]) {
            $result = & $arg
        }
        else {
            $result = $arg
        }
        if ($result) { break }
    }
    $result
}

Set-Alias ?? Invoke-NullCoalescing -Force

function Invoke-Utf8ConsoleCommand([ScriptBlock]$cmd) {
    $currentEncoding = [Console]::OutputEncoding
    $errorCount = $global:Error.Count
    try {
        # A native executable that writes to stderr AND has its stderr redirected will generate non-terminating
        # error records if the user has set $ErrorActionPreference to Stop. Override that value in this scope.
        $ErrorActionPreference = 'Continue'

        try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch [System.IO.IOException] {}
        & $cmd
    }
    finally {
        try { [Console]::OutputEncoding = $currentEncoding } catch [System.IO.IOException] {}

        # Clear out stderr output that was added to the $Error collection, putting those errors in a module variable
        if ($global:Error.Count -gt $errorCount) {
            $numNewErrors = $global:Error.Count - $errorCount
            $invokeErrors.InsertRange(0, $global:Error.GetRange(0, $numNewErrors))
            if ($invokeErrors.Count -gt 256) {
                $invokeErrors.RemoveRange(256, ($invokeErrors.Count - 256))
            }
            $global:Error.RemoveRange(0, $numNewErrors)
        }
    }
}

function Test-Administrator {
    # Don't care, disable for speed.
    return $false
}

<#
.SYNOPSIS
    Configures your PowerShell profile (startup) script to import the posh-git
    module when PowerShell starts.
.DESCRIPTION
    Checks if your PowerShell profile script is not already importing posh-git
    and if not, adds a command to import the posh-git module. This will cause
    PowerShell to load posh-git whenever PowerShell starts.
.PARAMETER AllHosts
    By default, this command modifies the CurrentUserCurrentHost profile
    script.  By specifying the AllHosts switch, the command updates the
    CurrentUserAllHosts profile (or AllUsersAllHosts, given -AllUsers).
.PARAMETER AllUsers
    By default, this command modifies the CurrentUserCurrentHost profile
    script.  By specifying the AllUsers switch, the command updates the
    AllUsersCurrentHost profile (or AllUsersAllHosts, given -AllHosts).
    Requires elevated permissions.
.PARAMETER Force
    Do not check if the specified profile script is already importing
    posh-git. Just add Import-Module posh-git command.
.EXAMPLE
    PS C:\> Add-PoshGitToProfile
    Updates your profile script for the current PowerShell host to import the
    posh-git module when the current PowerShell host starts.
.EXAMPLE
    PS C:\> Add-PoshGitToProfile -AllHosts
    Updates your profile script for all PowerShell hosts to import the posh-git
    module whenever any PowerShell host starts.
.INPUTS
    None.
.OUTPUTS
    None.
#>
function Add-PoshGitToProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]
        $AllHosts,

        [Parameter()]
        [switch]
        $AllUsers,

        [Parameter()]
        [switch]
        $Force,

        [Parameter(ValueFromRemainingArguments)]
        [psobject[]]
        $TestParams
    )

    if ($AllUsers -and !(Test-Administrator)) {
        throw 'Adding posh-git to an AllUsers profile requires an elevated host.'
    }

    $underTest = $false

    $profileName = $(if ($AllUsers) { 'AllUsers' } else { 'CurrentUser' }) `
                 + $(if ($AllHosts) { 'AllHosts' } else { 'CurrentHost' })
    Write-Verbose "`$profileName = '$profileName'"

    $profilePath = $PROFILE.$profileName
    Write-Verbose "`$profilePath = '$profilePath'"

    # Under test, we override some variables using $args as a backdoor.
    if (($TestParams.Count -gt 0) -and ($TestParams[0] -is [string])) {
        $profilePath = [string]$TestParams[0]
        $underTest = $true
        if ($TestParams.Count -gt 1) {
            $ModuleBasePath = [string]$TestParams[1]
        }
    }

    if (!$profilePath) { $profilePath = $PROFILE }

    if (!$Force) {
        # Search the user's profiles to see if any are using posh-git already, there is an extra search
        # ($profilePath) taking place to accomodate the Pester tests.
        $importedInProfile = Test-PoshGitImportedInScript $profilePath
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE
        }
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE.CurrentUserCurrentHost
        }
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE.CurrentUserAllHosts
        }
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE.AllUsersCurrentHost
        }
        if (!$importedInProfile -and !$underTest) {
            $importedInProfile = Test-PoshGitImportedInScript $PROFILE.AllUsersAllHosts
        }

        if ($importedInProfile) {
            Write-Warning "Skipping add of posh-git import to file '$profilePath'."
            Write-Warning "posh-git appears to already be imported in one of your profile scripts."
            Write-Warning "If you want to force the add, use the -Force parameter."
            return
        }
    }

    if (!$profilePath) {
        Write-Warning "Skipping add of posh-git import to profile; no profile found."
        Write-Verbose "`$PROFILE              = '$PROFILE'"
        Write-Verbose "CurrentUserCurrentHost = '$($PROFILE.CurrentUserCurrentHost)'"
        Write-Verbose "CurrentUserAllHosts    = '$($PROFILE.CurrentUserAllHosts)'"
        Write-Verbose "AllUsersCurrentHost    = '$($PROFILE.AllUsersCurrentHost)'"
        Write-Verbose "AllUsersAllHosts       = '$($PROFILE.AllUsersAllHosts)'"
        return
    }

    # If the profile script exists and is signed, then we should not modify it
    if (Test-Path -LiteralPath $profilePath) {
        if (!(Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue))
        {
            Write-Verbose "Platform doesn't support script signing, skipping test for signed profile."
        }
        else {
            $sig = Get-AuthenticodeSignature $profilePath
            if ($null -ne $sig.SignerCertificate) {
                Write-Warning "Skipping add of posh-git import to profile; '$profilePath' appears to be signed."
                Write-Warning "Add the command 'Import-Module posh-git' to your profile and resign it."
                return
            }
        }
    }

    # Check if the location of this module file is in the PSModulePath
    if (Test-InPSModulePath $ModuleBasePath) {
        $profileContent = "`nImport-Module posh-git"
    }
    else {
        $modulePath = Join-Path $ModuleBasePath posh-git.psd1
        $profileContent = "`nImport-Module '$modulePath'"
    }

    # Make sure the PowerShell profile directory exists
    $profileDir = Split-Path $profilePath -Parent
    if (!(Test-Path -LiteralPath $profileDir)) {
        if ($PSCmdlet.ShouldProcess($profileDir, "Create current user PowerShell profile directory")) {
            New-Item $profileDir -ItemType Directory -Force -Verbose:$VerbosePreference > $null
        }
    }

    if ($PSCmdlet.ShouldProcess($profilePath, "Add 'Import-Module posh-git' to profile")) {
        Add-Content -LiteralPath $profilePath -Value $profileContent -Encoding UTF8
    }
}

<#
.SYNOPSIS
    Modifies your PowerShell profile (startup) script so that it does not import
    the posh-git module when PowerShell starts.
.DESCRIPTION
    Checks if your PowerShell profile script is importing posh-git and if it does,
    removes the command to import the posh-git module. This will cause PowerShell
    to no longer load posh-git whenever PowerShell starts.
.PARAMETER AllHosts
    By default, this command modifies the CurrentUserCurrentHost profile
    script.  By specifying the AllHosts switch, the command updates the
    CurrentUserAllHosts profile (or AllUsersAllHosts, given -AllUsers).
.PARAMETER AllUsers
    By default, this command modifies the CurrentUserCurrentHost profile
    script.  By specifying the AllUsers switch, the command updates the
    AllUsersCurrentHost profile (or AllUsersAllHosts, given -AllHosts).
    Requires elevated permissions.
.EXAMPLE
    PS C:\> Remove-PoshGitFromProfile
    Updates your profile script for the current PowerShell host to stop importing
    the posh-git module when the current PowerShell host starts.
.EXAMPLE
    PS C:\> Remove-PoshGitFromProfile -AllHosts
    Updates your profile script for all PowerShell hosts to no longer import the
    posh-git module whenever any PowerShell host starts.
.INPUTS
    None.
.OUTPUTS
    None.
#>
function Remove-PoshGitFromProfile {
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter()]
        [switch]
        $AllHosts,

        [Parameter()]
        [switch]
        $AllUsers,

        [Parameter(ValueFromRemainingArguments)]
        [psobject[]]
        $TestParams
    )

    if ($AllUsers -and !(Test-Administrator)) {
        throw 'Removing posh-git from an AllUsers profile requires an elevated host.'
    }

    $underTest = $false

    $profileName = $(if ($AllUsers) { 'AllUsers' } else { 'CurrentUser' }) `
                 + $(if ($AllHosts) { 'AllHosts' } else { 'CurrentHost' })
    Write-Verbose "`$profileName = '$profileName'"

    $profilePath = $PROFILE.$profileName
    Write-Verbose "`$profilePath = '$profilePath'"

    # Under test, we override some variables using $args as a backdoor.
    if (($TestParams.Count -gt 0) -and ($TestParams[0] -is [string])) {
        $profilePath = [string]$TestParams[0]
        $underTest = $true
        if ($TestParams.Count -gt 1) {
            $ModuleBasePath = [string]$TestParams[1]
        }
    }

    if (!$profilePath) { $profilePath = $PROFILE }

    if (!$profilePath) {
        Write-Warning "Skipping removal of posh-git import from profile; no profile found."
        Write-Verbose "`$PROFILE              = '$PROFILE'"
        Write-Verbose "CurrentUserCurrentHost = '$($PROFILE.CurrentUserCurrentHost)'"
        Write-Verbose "CurrentUserAllHosts    = '$($PROFILE.CurrentUserAllHosts)'"
        Write-Verbose "AllUsersCurrentHost    = '$($PROFILE.AllUsersCurrentHost)'"
        Write-Verbose "AllUsersAllHosts       = '$($PROFILE.AllUsersAllHosts)'"
        return
    }

    if (Test-Path -LiteralPath $profilePath) {
        # If the profile script exists and is signed, then we should not modify it
        if (!(Get-Command Get-AuthenticodeSignature -ErrorAction SilentlyContinue))
        {
            Write-Verbose "Platform doesn't support script signing, skipping test for signed profile."
        }
        else {
            $sig = Get-AuthenticodeSignature $profilePath
            if ($null -ne $sig.SignerCertificate) {
                Write-Warning "Skipping removal of posh-git import from profile; '$profilePath' appears to be signed."
                Write-Warning "Remove the command 'Import-Module posh-git' from your profile and resign it."
                return
            }
        }

        $oldProfile = @(Get-Content $profilePath)
        $oldProfileEncoding = Get-FileEncoding $profilePath

        $newProfile = @()
        foreach($line in $oldProfile) {
            if ($line -like '*PoshGitPrompt*') { continue; }
            if ($line -like '*Load posh-git example profile*') { continue; }

            if($line -like '. *posh-git*profile.example.ps1*') {
                continue;
            }
            if($line -like 'Import-Module *\posh-git.psd1*') {
                continue;
            }
            $newProfile += $line
        }
        Set-Content -path $profilePath -value $newProfile -Force -Encoding $oldProfileEncoding
    }
}

<#
.SYNOPSIS
    Gets the file encoding of the specified file.
.DESCRIPTION
    Gets the file encoding of the specified file.
.PARAMETER Path
    Path to the file to check.  The file must exist.
.EXAMPLE
    PS C:\> Get-FileEncoding $profile
    Get's the file encoding of the profile file.
.INPUTS
    None.
.OUTPUTS
    [System.String]
.NOTES
    Adapted from http://www.west-wind.com/Weblog/posts/197245.aspx
#>
function Get-FileEncoding($Path) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $bytes = [byte[]](Get-Content $Path -AsByteStream -ReadCount 4 -TotalCount 4)
    }
    else {
        $bytes = [byte[]](Get-Content $Path -Encoding byte -ReadCount 4 -TotalCount 4)
    }

    if (!$bytes) { return 'utf8' }

    switch -regex ('{0:x2}{1:x2}{2:x2}{3:x2}' -f $bytes[0],$bytes[1],$bytes[2],$bytes[3]) {
        '^efbbbf'   { return 'utf8' }
        '^2b2f76'   { return 'utf7' }
        '^fffe'     { return 'unicode' }
        '^feff'     { return 'bigendianunicode' }
        '^0000feff' { return 'utf32' }
        default     { return 'ascii' }
    }
}

<#
.SYNOPSIS
    Gets a StringComparison enum value appropriate for comparing paths on the OS platform.
.DESCRIPTION
    Gets a StringComparison enum value appropriate for comparing paths on the OS platform.
.EXAMPLE
    PS C:\> $pathStringComparison = Get-PathStringComparison
.INPUTS
    None
.OUTPUTS
    [System.StringComparison]
#>
function Get-PathStringComparison {
    # File system paths are case-sensitive on Linux and case-insensitive on Windows and macOS
    if (($PSVersionTable.PSVersion.Major -ge 6) -and $IsLinux) {
        [System.StringComparison]::Ordinal
    }
    else {
        [System.StringComparison]::OrdinalIgnoreCase
    }
}

function Get-PromptPath {
    $settings = $global:GitPromptSettings
    $stringComparison = Get-PathStringComparison

    # A UNC path has no drive so it's better to use the ProviderPath e.g. "\\server\share".
    # However for any path with a drive defined, it's better to use the Path property.
    # In this case, ProviderPath is "\LocalMachine\My"" whereas Path is "Cert:\LocalMachine\My".
    # The latter is more desirable.
    $pathInfo = $ExecutionContext.SessionState.Path.CurrentLocation
    $currentPath = if ($pathInfo.Drive) { $pathInfo.Path } else { $pathInfo.ProviderPath }
    if (!$settings -or !$currentPath) {
        return $currentPath
    }

    $abbrevHomeDir = $settings.DefaultPromptAbbreviateHomeDirectory
    $abbrevGitDir = $settings.DefaultPromptAbbreviateGitDirectory

    # Look up the git root
    if ($abbrevGitDir) {
        $gitPath = Get-GitDirectory
        # Up one level from `.git`
        if ($gitPath) { $gitPath = Split-Path $gitPath -Parent }
    }

    # Abbreviate path under a git repository as "<repo-name>:<relative-path>"
    if ($abbrevGitDir -and $gitPath -and $currentPath.StartsWith($gitPath, $stringComparison)) {
        $gitName = Split-Path $gitPath -Leaf
        $relPath = if ($currentPath -eq $gitPath) { "" } else { $currentPath.SubString($gitPath.Length + 1) }
        $currentPath = "$gitName`:$relPath"
    }
    # Abbreviate path under the user's home dir as "~<relative-path>"
    elseif ($abbrevHomeDir -and $currentPath.StartsWith($Home, $stringComparison)) {
        $currentPath = "~" + $currentPath.SubString($Home.Length)
    }

    return $currentPath
}

<#
.SYNOPSIS
    Gets a string with current machine name and user name when connected with SSH
.PARAMETER Format
    Format string to use for displaying machine name ({0}) and user name ({1}).
    Default: "[{1}@{0}]: ", i.e. "[user@machine]: "
.INPUTS
    None
.OUTPUTS
    [String]
#>
function Get-PromptConnectionInfo($Format = '[{1}@{0}]: ') {
    if ($GitPromptSettings -and (Test-Path Env:SSH_CONNECTION)) {
        $MachineName = [System.Environment]::MachineName
        $UserName = [System.Environment]::UserName
        $Format -f $MachineName,$UserName
    }
}

function Get-PSModulePath {
    $modulePaths = $Env:PSModulePath -split ';'
    $modulePaths
}

function Test-InPSModulePath {
    param (
        [Parameter(Position=0, Mandatory=$true)]
        [ValidateNotNull()]
        [string]
        $Path
    )

    $modulePaths = Get-PSModulePath
    if (!$modulePaths) { return $false }

    $pathStringComparison = Get-PathStringComparison
    $Path = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $inModulePath = @($modulePaths | Where-Object { $Path.StartsWith($_.TrimEnd([System.IO.Path]::DirectorySeparatorChar), $pathStringComparison) }).Count -gt 0

    if ($inModulePath -and ('src' -eq (Split-Path $Path -Leaf))) {
        Write-Warning 'posh-git repository structure is incompatible with %PSModulePath%.'
        Write-Warning 'Importing with absolute path instead.'
        return $false
    }

    $inModulePath
}

function Test-PoshGitImportedInScript {
    param (
        [Parameter(Position=0)]
        [string]
        $Path
    )

    if (!$Path -or !(Test-Path -LiteralPath $Path)) {
        return $false
    }

    $match = (@(Get-Content $Path -ErrorAction SilentlyContinue) -match 'posh-git').Count -gt 0
    if ($match) { Write-Verbose "posh-git found in '$Path'" }
    $match
}

function dbg($Message, [Diagnostics.Stopwatch]$Stopwatch) {
    if ($Stopwatch) {
        Write-Verbose ('{0:00000}:{1}' -f $Stopwatch.ElapsedMilliseconds,$Message) -Verbose # -ForegroundColor Yellow
    }
}
Write-DebugTiming -Label 'Utils'
#endregion

# ============================================================================
#region AnsiUtils
# ============================================================================
# Color codes from https://msdn.microsoft.com/en-us/library/windows/desktop/mt638032(v=vs.85).aspx
$ConsoleColorToAnsi = @(
    30 # Black
    34 # DarkBlue
    32 # DarkGreen
    36 # DarkCyan
    31 # DarkRed
    35 # DarkMagenta
    33 # DarkYellow
    37 # Gray
    90 # DarkGray
    94 # Blue
    92 # Green
    96 # Cyan
    91 # Red
    95 # Magenta
    93 # Yellow
    97 # White
)
$AnsiDefaultColor = 39
$AnsiEscape = [char]27 + "["

[Reflection.Assembly]::LoadWithPartialName('System.Drawing') > $null
$ColorTranslatorType = 'System.Drawing.ColorTranslator' -as [Type]
$ColorType = 'System.Drawing.Color' -as [Type]

function EscapeAnsiString([string]$AnsiString) {
    if ($PSVersionTable.PSVersion.Major -ge 6) {
        $res = $AnsiString -replace "$([char]27)", '`e'
    }
    else {
        $res = $AnsiString -replace "$([char]27)", '$([char]27)'
    }

    $res
}

function Test-VirtualTerminalSequece([psobject[]]$Object, [switch]$Force) {
    foreach ($obj in $Object) {
        if (($Force -or $global:GitPromptSettings.AnsiConsole) -and ($obj -is [string])) {
            $obj.Contains($AnsiEscape)
        }
        else {
            $false
        }
    }
}

function Get-VirtualTerminalSequence ($color, [int]$offset = 0) {
    # Don't output ANSI escape sequences if the `$color` parameter is `$null`,
    # they would be broken anyway
    if ($null -eq $color) {
        return $null;
    }

    if ($color -is [byte]) {
        return "${AnsiEscape}$(38 + $offset);5;${color}m"
    }

    if ($color -is [int]) {
        $r = ($color -shr 16) -band 0xff
        $g = ($color -shr 8) -band 0xff
        $b = $color -band 0xff
        return "${AnsiEscape}$(38 + $offset);2;${r};${g};${b}m"
    }

    # Force 'DarkYellow' to ConsoleColor, since it is not an HTML color
    if ($color -eq [System.ConsoleColor]::DarkYellow) {
        $color = [System.ConsoleColor]::DarkYellow
    }
    elseif ($color -is [String]) {
        try {
            if ($ColorTranslatorType) {
                $color = $ColorTranslatorType::FromHtml($color)
            }
        }
        catch {
            Write-Debug $_
        }
    }

    if ($ColorType -and ($color -is $ColorType)) {
        return "${AnsiEscape}$(38 + $offset);2;$($color.R);$($color.G);$($color.B)m"
    }

    if (($color -is [System.ConsoleColor]) -and ($color -ge 0) -and ($color -le 15)) {
        return "${AnsiEscape}$($ConsoleColorToAnsi[$color] + $offset)m"
    }

    return "${AnsiEscape}$($AnsiDefaultColor + $offset)m"
}

function Get-ForegroundVirtualTerminalSequence($Color) {
    return Get-VirtualTerminalSequence $Color
}

function Get-BackgroundVirtualTerminalSequence($Color) {
    return Get-VirtualTerminalSequence $Color 10
}
Write-DebugTiming -Label 'AnsiUtils'
#endregion

# ============================================================================
#region WindowTitle
# ============================================================================
$HostSupportsSettingWindowTitle = $null
$OriginalWindowTitle = $null

function Test-WindowTitleIsWriteable {
    if ($null -eq $HostSupportsSettingWindowTitle) {
        # Probe $Host.UI.RawUI.WindowTitle to see if it can be set without errors
        try {
            $script:OriginalWindowTitle = $Host.UI.RawUI.WindowTitle
            if (!$script:OriginalWindowTitle) {
                # Set a reasonable title to revert to on uninstall
                $Host.UI.RawUI.WindowTitle = 'PowerShell';
                $script:OriginalWindowTitle = $Host.UI.RawUI.WindowTitle
            }
            $newTitle = "${OriginalWindowTitle} "
            $Host.UI.RawUI.WindowTitle = $newTitle
            $script:HostSupportsSettingWindowTitle = ($Host.UI.RawUI.WindowTitle -eq $newTitle)
            $Host.UI.RawUI.WindowTitle = $OriginalWindowTitle
            Write-Debug "HostSupportsSettingWindowTitle: $HostSupportsSettingWindowTitle"
            Write-Debug "OriginalWindowTitle: $OriginalWindowTitle"
        }
        catch {
            $script:OriginalWindowTitle = $null
            $script:HostSupportsSettingWindowTitle = $false
            Write-Debug "HostSupportsSettingWindowTitle error: $_"
        }
    }
    return $HostSupportsSettingWindowTitle
}

function Reset-WindowTitle {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
    param()
    $settings = $global:GitPromptSettings

    # Revert to original WindowTitle, but only if posh-git is currently configured to set it
    if ($HostSupportsSettingWindowTitle -and $OriginalWindowTitle -and $settings.WindowTitle) {
        Write-Debug "Resetting WindowTitle: '$OriginalWindowTitle'"
        $Host.UI.RawUI.WindowTitle = $OriginalWindowTitle
    }
}

function Set-WindowTitle {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute("PSUseShouldProcessForStateChangingFunctions", "")]
    param($GitStatus, $IsAdmin)
    $settings = $global:GitPromptSettings

    # Update the host's WindowTitle if host supports it and user has not disabled $GitPromptSettings.WindowTitle
    if ($settings.WindowTitle -and (Test-WindowTitleIsWriteable)) {
        try {
            if ($settings.WindowTitle -is [scriptblock]) {
                # ensure results returned by scriptblock are flattened into a string
                $windowTitleText = "$(& $settings.WindowTitle $GitStatus $IsAdmin)"
            }
            else {
                $windowTitleText = $ExecutionContext.SessionState.InvokeCommand.ExpandString("$($settings.WindowTitle)")
            }

            Write-Debug "Setting WindowTitle: $windowTitleText"
            $Host.UI.RawUI.WindowTitle = "$windowTitleText"
        }
        catch {
            Write-Debug "Error occurred during evaluation of `$GitPromptSettings.WindowTitle: $_"
        }
    }
}
Write-DebugTiming -Label 'WindowTitle'
#endregion

# ============================================================================
#region PoshGitTypes
# ============================================================================
enum BranchBehindAndAheadDisplayOptions { Full; Compact; Minimal }
enum UntrackedFilesMode { Default; No; Normal; All }

class PoshGitCellColor {
    [psobject]$BackgroundColor
    [psobject]$ForegroundColor

    PoshGitCellColor() {
        $this.ForegroundColor = $null
        $this.BackgroundColor = $null
    }

    PoshGitCellColor([psobject]$ForegroundColor) {
        $this.ForegroundColor = $ForegroundColor
        $this.BackgroundColor = $null
    }

    PoshGitCellColor([psobject]$ForegroundColor, [psobject]$BackgroundColor) {
        $this.ForegroundColor = $ForegroundColor
        $this.BackgroundColor = $BackgroundColor
    }

    hidden [string] ToString($color) {
        $ansiTerm = "$([char]27)[0m"
        $colorSwatch = "  "
        $str = ""

        if (!$color) {
            $str = "<default>"
        }
        elseif (Test-VirtualTerminalSequece $color -Force) {
            if ($global:GitPromptSettings.AnsiConsole) {
                # Use '#' for FG color swatch since we are just applying the VT seqs as-is and
                # a " " swatch char won't show anything for a FG color.
                if ($color -eq $this.ForegroundColor) {
                    $colorSwatch = "#"
                }

                $str = "${color}$colorSwatch${ansiTerm} "
            }

            $str = "`"$(EscapeAnsiString $color)`""
        }
        else {
            if ($global:GitPromptSettings.AnsiConsole) {
                $bg = Get-BackgroundVirtualTerminalSequence $color
                $str = "${bg}${colorSwatch}${ansiTerm} "
            }

            if ($color -is [int]) {
                $str += "0x{0:X6}" -f $color
            }
            else {
                $str += $color.ToString()
            }
        }

        return $str
    }

    [string] ToEscapedString() {
        if (!$global:GitPromptSettings.AnsiConsole) {
            return ""
        }

        $str = ""

        if ($this.ForegroundColor) {
            if (Test-VirtualTerminalSequece $this.ForegroundColor) {
                $str += EscapeAnsiString $this.ForegroundColor
            }
            else {
                $seq = Get-ForegroundVirtualTerminalSequence $this.ForegroundColor
                $str += EscapeAnsiString $seq
            }
        }

        if ($this.BackgroundColor) {
            if (Test-VirtualTerminalSequece $this.BackgroundColor) {
                $str += EscapeAnsiString $this.BackgroundColor
            }
            else {
                $seq = Get-BackgroundVirtualTerminalSequence $this.BackgroundColor
                $str += EscapeAnsiString $seq
            }
        }

        return $str
    }

    [string] ToString() {
        $str = "ForegroundColor: "
        $str += $this.ToString($this.ForegroundColor) + ", "
        $str += "BackgroundColor: "
        $str += $this.ToString($this.BackgroundColor)
        return $str
    }
}

class PoshGitTextSpan {
    [string]$Text
    [psobject]$BackgroundColor
    [psobject]$ForegroundColor

    PoshGitTextSpan() {
        $this.Text = ""
        $this.ForegroundColor = $null
        $this.BackgroundColor = $null
    }

    PoshGitTextSpan([string]$Text) {
        $this.Text = $Text
        $this.ForegroundColor = $null
        $this.BackgroundColor = $null
    }

    PoshGitTextSpan([string]$Text, [psobject]$ForegroundColor) {
        $this.Text = $Text
        $this.ForegroundColor = $ForegroundColor
        $this.BackgroundColor = $null
    }

    PoshGitTextSpan([string]$Text, [psobject]$ForegroundColor, [psobject]$BackgroundColor) {
        $this.Text = $Text
        $this.ForegroundColor = $ForegroundColor
        $this.BackgroundColor = $BackgroundColor
    }

    PoshGitTextSpan([PoshGitTextSpan]$PoshGitTextSpan) {
        $this.Text = $PoshGitTextSpan.Text
        $this.ForegroundColor = $PoshGitTextSpan.ForegroundColor
        $this.BackgroundColor = $PoshGitTextSpan.BackgroundColor
    }

    PoshGitTextSpan([PoshGitCellColor]$PoshGitCellColor) {
        $this.Text = ''
        $this.ForegroundColor = $PoshGitCellColor.ForegroundColor
        $this.BackgroundColor = $PoshGitCellColor.BackgroundColor
    }

    [PoshGitTextSpan] Expand() {
        if (!$this.Text) {
            return $this
        }

        $execContext = Get-Variable ExecutionContext -ValueOnly
        $expandedText = $execContext.SessionState.InvokeCommand.ExpandString($this.Text)
        $newTextSpan = [PoshGitTextSpan]::new($expandedText, $this.ForegroundColor, $this.BackgroundColor)
        return $newTextSpan
    }

    # This method is used by Write-Prompt to render an instance of a PoshGitTextSpan when
    # $GitPromptSettings.AnsiConsole is $true.  It is also used by the default ToString()
    # implementation to display any ANSI seqs when AnsiConsole is $true.
    [string] ToAnsiString() {
        # If we know which colors were changed, we can reset only these and leave others be.
        $reset = [System.Collections.Generic.List[string]]::new()
        $e = [char]27 + "["

        $fg = $this.ForegroundColor
        if (($null -ne $fg) -and !(Test-VirtualTerminalSequece $fg)) {
            $fg = Get-ForegroundVirtualTerminalSequence $fg
            $reset.Add('39')
        }

        $bg = $this.BackgroundColor
        if (($null -ne $bg) -and !(Test-VirtualTerminalSequece $bg)) {
            $bg = Get-BackgroundVirtualTerminalSequence $bg
            $reset.Add('49')
        }

        $txt = $this.Text
        $str = "${fg}${bg}${txt}"

        # ALWAYS terminate a VT sequence in case the host supports VT (regardless of AnsiConsole setting),
        # or the host display can get messed up.
        if (Test-VirtualTerminalSequece $txt -Force) {
            $reset.Clear()
            $reset.Add('0')
        }

        if ($reset.Count -gt 0) {
            $str += "${e}$($reset -join ';')m"
        }

        return $str
    }

    [string] ToEscapedString() {
        $str = EscapeAnsiString $this.ToAnsiString()
        return $str
    }

    # This method is used when displaying the "value" of PoshGitTextSpan e.g. when evaluating $GitPromptSettings
    [string] ToString() {
        $sep = " "
        if ($this.Text.Length -lt 2) {
            $sep = " " * (3 - $this.Text.Length)
        }

        if ($global:GitPromptSettings.AnsiConsole) {
            $txt = $this.ToAnsiString()
            if (Test-VirtualTerminalSequece $txt) {
                $escAnsi = "ANSI: `"$(EscapeAnsiString $txt)`""
                $str = "Text: `"$txt`e[39;49m`",${sep}${escAnsi}"
            }
            else {
                $str = "Text: `"$txt`""
            }
        }
        else {
            $txt = $this.Text
            if (Test-VirtualTerminalSequece $txt -Force) {
                $txt = EscapeAnsiString $txt
            }

            $color = [PoshGitCellColor]::new($this.ForegroundColor, $this.BackgroundColor)
            $str = "Text: `"$txt`",${sep}$($color.ToString())"
        }

        return $str
    }
}

class PoshGitPromptSettings {
    [bool]$AnsiConsole = ($Host.UI.SupportsVirtualTerminal -or ($Env:ConEmuANSI -eq "ON")) -and !$script:GitCygwin
    [bool]$SetEnvColumns = $true

    [PoshGitCellColor]$DefaultColor = [PoshGitCellColor]::new()
    [PoshGitCellColor]$BranchColor  = [PoshGitCellColor]::new([ConsoleColor]::Cyan)

    [PoshGitCellColor]$IndexColor   = [PoshGitCellColor]::new([ConsoleColor]::DarkGreen)
    [PoshGitCellColor]$WorkingColor = [PoshGitCellColor]::new([ConsoleColor]::DarkRed)
    [PoshGitCellColor]$StashColor   = [PoshGitCellColor]::new([ConsoleColor]::Red)
    [PoshGitCellColor]$ErrorColor   = [PoshGitCellColor]::new([ConsoleColor]::Red)

    [PoshGitTextSpan]$PathStatusSeparator      = ' '
    [PoshGitTextSpan]$BeforeStatus             = [PoshGitTextSpan]::new('[', [ConsoleColor]::Yellow)
    [PoshGitTextSpan]$DelimStatus              = [PoshGitTextSpan]::new(' |', [ConsoleColor]::Yellow)
    [PoshGitTextSpan]$AfterStatus              = [PoshGitTextSpan]::new(']', [ConsoleColor]::Yellow)

    [PoshGitTextSpan]$BeforePath               = [PoshGitTextSpan]::new('', [ConsoleColor]::Yellow)
    [PoshGitTextSpan]$AfterPath                = [PoshGitTextSpan]::new('', [ConsoleColor]::Yellow)

    [PoshGitTextSpan]$BeforeIndex              = [PoshGitTextSpan]::new('', [ConsoleColor]::DarkGreen)
    [PoshGitTextSpan]$BeforeStash              = [PoshGitTextSpan]::new(' (', [ConsoleColor]::Red)
    [PoshGitTextSpan]$AfterStash               = [PoshGitTextSpan]::new(')', [ConsoleColor]::Red)

    [PoshGitTextSpan]$LocalDefaultStatusSymbol = [PoshGitTextSpan]::new('', [ConsoleColor]::DarkGreen)
    [PoshGitTextSpan]$LocalWorkingStatusSymbol = [PoshGitTextSpan]::new('!', [ConsoleColor]::DarkRed)
    [PoshGitTextSpan]$LocalStagedStatusSymbol  = [PoshGitTextSpan]::new('~', [ConsoleColor]::Cyan)

    [PoshGitTextSpan]$BranchGoneStatusSymbol           = [PoshGitTextSpan]::new([char]0x00D7, [ConsoleColor]::DarkCyan) # × Multiplication sign
    [PoshGitTextSpan]$BranchIdenticalStatusSymbol      = [PoshGitTextSpan]::new([char]0x2261, [ConsoleColor]::Cyan)     # ≡ Three horizontal lines
    [PoshGitTextSpan]$BranchAheadStatusSymbol          = [PoshGitTextSpan]::new([char]0x2191, [ConsoleColor]::Green)    # ↑ Up arrow
    [PoshGitTextSpan]$BranchBehindStatusSymbol         = [PoshGitTextSpan]::new([char]0x2193, [ConsoleColor]::Red)      # ↓ Down arrow
    [PoshGitTextSpan]$BranchBehindAndAheadStatusSymbol = [PoshGitTextSpan]::new([char]0x2195, [ConsoleColor]::Yellow)   # ↕ Up & Down arrow

    [BranchBehindAndAheadDisplayOptions]$BranchBehindAndAheadDisplay = [BranchBehindAndAheadDisplayOptions]::Full

    [string]$FileAddedText       = '+'
    [string]$FileModifiedText    = '~'
    [string]$FileRemovedText     = '-'
    [string]$FileConflictedText  = '!'
    [string]$BranchUntrackedText = ''

    [bool]$EnableStashStatus     = $false
    [bool]$ShowStatusWhenZero    = $true
    [bool]$AutoRefreshIndex      = $true

    [UntrackedFilesMode]$UntrackedFilesMode = [UntrackedFilesMode]::Default

    [bool]$EnablePromptStatus    = !$global:GitMissing
    [bool]$EnableFileStatus      = $true

    [Nullable[bool]]$EnableFileStatusFromCache        = $null
    [string[]]$RepositoriesInWhichToDisableFileStatus = @()

    [string]$DescribeStyle = ''
    [psobject]$WindowTitle = {param($GitStatus, [bool]$IsAdmin) "$(if ($IsAdmin) {'Admin: '})$(if ($GitStatus) {"$($GitStatus.RepoName) [$($GitStatus.Branch)]"} else {Get-PromptPath}) - PowerShell $($PSVersionTable.PSVersion.Major).$($PSVersionTable.PSVersion.Minor) $(if ([IntPtr]::Size -eq 4) {'32-bit '})($PID)"}

    [PoshGitTextSpan]$DefaultPromptPrefix       = '$(Get-PromptConnectionInfo -Format "[{1}@{0}]: ")'
    [PoshGitTextSpan]$DefaultPromptPath         = '$(Get-PromptPath)'
    [PoshGitTextSpan]$DefaultPromptBeforeSuffix = ''
    [PoshGitTextSpan]$DefaultPromptDebug        = [PoshGitTextSpan]::new(' [DBG]:', [ConsoleColor]::Magenta)
    [PoshGitTextSpan]$DefaultPromptSuffix       = '$(">" * ($nestedPromptLevel + 1)) '

    [bool]$DefaultPromptAbbreviateHomeDirectory = ($PSVersionTable.PSVersion.Major -gt 5) -and !$IsWindows
    [bool]$DefaultPromptAbbreviateGitDirectory  = $false
    [bool]$DefaultPromptWriteStatusFirst        = $false
    [bool]$DefaultPromptEnableTiming            = $false
    [PoshGitTextSpan]$DefaultPromptTimingFormat = ' {0}ms'

    [int]$BranchNameLimit = 0
    [string]$TruncatedBranchSuffix = '...'

    [bool]$Debug = $false
}

class PoshGitPromptValues {
    [int]$LastExitCode
    [bool]$DollarQuestion
    [bool]$IsAdmin
    [string]$LastPrompt
}
Write-DebugTiming -Label 'PoshGitTypes'
#endregion

# ============================================================================
#region GitUtils
# ============================================================================
# Inspired by Mark Embling
# http://www.markembling.info/view/my-ideal-powershell-prompt-with-git-integration

<#
.SYNOPSIS
    Gets the path to the current repository's .git dir.
.DESCRIPTION
    Gets the path to the current repository's .git dir.  Or if the repository
    is a bare repository, the root directory of the bare repository.
.EXAMPLE
    PS C:\GitHub\posh-git\tests> Get-GitDirectory
    Returns C:\GitHub\posh-git\.git
.INPUTS
    None.
.OUTPUTS
    System.String
#>
function Get-GitDirectory {
    $pathInfo = Microsoft.PowerShell.Management\Get-Location
    if (!$pathInfo -or ($pathInfo.Provider.Name -ne 'FileSystem')) {
        $null
    }
    elseif ($Env:GIT_DIR) {
        $Env:GIT_DIR -replace '\\|/', [System.IO.Path]::DirectorySeparatorChar
    }
    else {
        $currentDir = Get-Item -LiteralPath $pathInfo -Force
        while ($currentDir) {
            $gitDirPath = Join-Path $currentDir.FullName .git
            if (Test-Path -LiteralPath $gitDirPath -PathType Container) {
                return $gitDirPath
            }

            # Handle the worktree case where .git is a file
            if (Test-Path -LiteralPath $gitDirPath -PathType Leaf) {
                $gitDirPath = Invoke-Utf8ConsoleCommand { git rev-parse --git-dir 2>$null }
                if ($gitDirPath) {
                    return $gitDirPath
                }
            }

            $headPath = Join-Path $currentDir.FullName HEAD
            if (Test-Path -LiteralPath $headPath -PathType Leaf) {
                $refsPath = Join-Path $currentDir.FullName refs
                $objsPath = Join-Path $currentDir.FullName objects
                if ((Test-Path -LiteralPath $refsPath -PathType Container) -and
                    (Test-Path -LiteralPath $objsPath -PathType Container)) {

                    $bareDir = Invoke-Utf8ConsoleCommand { git rev-parse --git-dir 2>$null }
                    if ($bareDir -and (Test-Path -LiteralPath $bareDir -PathType Container)) {
                        $resolvedBareDir = (Resolve-Path $bareDir).Path
                        return $resolvedBareDir
                    }
                }
            }

            $currentDir = $currentDir.Parent
        }
    }
}

function Get-GitBranch($branch = $null, $gitDir = $(Get-GitDirectory), [switch]$isDotGitOrBare, [Diagnostics.Stopwatch]$sw) {
    if (!$gitDir) { return }

    Invoke-Utf8ConsoleCommand {
        dbg 'Finding branch' $sw
        $r = ''; $b = ''; $c = ''
        $step = ''; $total = ''
        if (Test-Path $gitDir/rebase-merge) {
            dbg 'Found rebase-merge' $sw
            if (Test-Path $gitDir/rebase-merge/interactive) {
                dbg 'Found rebase-merge/interactive' $sw
                $r = '|REBASE-i'
            }
            else {
                $r = '|REBASE-m'
            }
            $b = "$(Get-Content $gitDir/rebase-merge/head-name)"
            $step = "$(Get-Content $gitDir/rebase-merge/msgnum)"
            $total = "$(Get-Content $gitDir/rebase-merge/end)"
        }
        else {
            if (Test-Path $gitDir/rebase-apply) {
                dbg 'Found rebase-apply' $sw
                $step = "$(Get-Content $gitDir/rebase-apply/next)"
                $total = "$(Get-Content $gitDir/rebase-apply/last)"

                if (Test-Path $gitDir/rebase-apply/rebasing) {
                    dbg 'Found rebase-apply/rebasing' $sw
                    $r = '|REBASE'
                }
                elseif (Test-Path $gitDir/rebase-apply/applying) {
                    dbg 'Found rebase-apply/applying' $sw
                    $r = '|AM'
                }
                else {
                    $r = '|AM/REBASE'
                }
            }
            elseif (Test-Path $gitDir/MERGE_HEAD) {
                dbg 'Found MERGE_HEAD' $sw
                $r = '|MERGING'
            }
            elseif (Test-Path $gitDir/CHERRY_PICK_HEAD) {
                dbg 'Found CHERRY_PICK_HEAD' $sw
                $r = '|CHERRY-PICKING'
            }
            elseif (Test-Path $gitDir/REVERT_HEAD) {
                dbg 'Found REVERT_HEAD' $sw
                $r = '|REVERTING'
            }
            elseif (Test-Path $gitDir/BISECT_LOG) {
                dbg 'Found BISECT_LOG' $sw
                $r = '|BISECTING'
            }

            if ($step -and $total) {
                $r += " $step/$total"
            }

            $b = Invoke-NullCoalescing `
                $b `
                $branch `
                { dbg 'Trying symbolic-ref' $sw; git --no-optional-locks symbolic-ref HEAD -q 2>$null } `
                { '({0})' -f (Invoke-NullCoalescing `
                    {
                        dbg 'Trying describe' $sw
                        switch ($Global:GitPromptSettings.DescribeStyle) {
                            'contains' { git --no-optional-locks describe --contains HEAD 2>$null }
                            'branch' { git --no-optional-locks describe --contains --all HEAD 2>$null }
                            'describe' { git --no-optional-locks describe HEAD 2>$null }
                            default { git --no-optional-locks tag --points-at HEAD 2>$null }
                        }
                    } `
                    {
                        dbg 'Falling back on parsing HEAD' $sw
                        $ref = $null

                        if (Test-Path $gitDir/HEAD) {
                            dbg 'Reading from .git/HEAD' $sw
                            $ref = Get-Content $gitDir/HEAD 2>$null
                        }
                        else {
                            dbg 'Trying rev-parse' $sw
                            $ref = git --no-optional-locks rev-parse HEAD 2>$null
                        }

                        if ($ref -match 'ref: (?<ref>.+)') {
                            return $Matches['ref']
                        }
                        elseif ($ref -and $ref.Length -ge 7) {
                            return $ref.Substring(0, 7) + '...'
                        }
                        else {
                            return 'unknown'
                        }
                    }
                ) }
        }

        if ($isDotGitOrBare -or !$b) {
            dbg 'Inside git directory?' $sw
            $revParseOut = git --no-optional-locks rev-parse --is-inside-git-dir 2>$null
            if ('true' -eq $revParseOut) {
                dbg 'Inside git directory' $sw
                $revParseOut = git --no-optional-locks rev-parse --is-bare-repository 2>$null
                if ('true' -eq $revParseOut) {
                    $c = 'BARE:'
                }
                else {
                    $b = 'GIT_DIR!'
                }
            }
        }

        "$c$($b -replace 'refs/heads/','')$r"
    }
}

function GetUniquePaths($pathCollections) {
    $hash = New-Object System.Collections.Specialized.OrderedDictionary

    foreach ($pathCollection in $pathCollections) {
        foreach ($path in $pathCollection) {
            $hash[$path] = 1
        }
    }

    $hash.Keys
}

$castStringSeq = [Linq.Enumerable].GetMethod("Cast").MakeGenericMethod([string])

<#
.SYNOPSIS
    Gets a Git status object that is used by `Write-GitStatus`.
.DESCRIPTION
    The `Get-GitStatus` cmdlet gets the status of the current Git repo.

    The status object returned by this cmdlet provides the information
    displayed in the various sections of the posh-git prompt. The following
    properties in $GitPromptSettings control what information is returned in
    the status object:

    EnableFileStatus          = $true # Or $false if Git not installed
    EnableFileStatusFromCache = <unset> # Or $true if GitStatusCachePoshClient installed
    EnablePromptStatus        = $true
    EnableStashStatus         = $false
    UntrackedFilesMode        = Default # Other enum values: No, Normal, All

    The `Force` parameter can be used to override the EnableFileStatus and
    EnablePromptStatus properties to ensure that both file and prompt status
    information is returned in the status object.
.EXAMPLE
    PS C:\> $s = Get-GitStatus; Write-GitStatus $s
    Gets a Git status object. Then passes the object to Write-GitStatus which
    writes out a posh-git prompt (or returns a string in ANSI mode) with the
    information contained in the status object.
.EXAMPLE
    PS C:\> $s = Get-GitStatus -Force
    Gets a Git status object that always returns all status information even
    if $GitPromptSettings has disabled `EnableFileStatus` and/or
    `EnablePromptStatus`.
.INPUTS
    None
.OUTPUTS
    System.Management.Automation.PSObject
.LINK
    Write-GitStatus
#>
function Get-GitStatus {
    param(
        # The path of a directory within a Git repository that you want to get
        # the Git status.
        [Parameter(Position = 0)]
        $GitDir = (Get-GitDirectory),

        # If specified, overrides $GitPromptSettings.EnableFileStatus and
        # $GitPromptSettings.EnablePromptStatus when they are set to $false.
        [Parameter()]
        [switch]
        $Force
    )

    $settings = if ($global:GitPromptSettings) { $global:GitPromptSettings } else { [PoshGitPromptSettings]::new() }

    $promptStatusEnabled = $Force -or $settings.EnablePromptStatus
    if ($promptStatusEnabled -and $GitDir) {
        if ($settings.Debug) {
            $sw = [Diagnostics.Stopwatch]::StartNew(); Write-Host ''
        }
        else {
            $sw = $null
        }

        $branch = $null
        $aheadBy = 0
        $behindBy = 0
        $gone = $false
        $upstream = $null

        $indexAdded = New-Object System.Collections.Generic.List[string]
        $indexModified = New-Object System.Collections.Generic.List[string]
        $indexDeleted = New-Object System.Collections.Generic.List[string]
        $indexUnmerged = New-Object System.Collections.Generic.List[string]
        $filesAdded = New-Object System.Collections.Generic.List[string]
        $filesModified = New-Object System.Collections.Generic.List[string]
        $filesDeleted = New-Object System.Collections.Generic.List[string]
        $filesUnmerged = New-Object System.Collections.Generic.List[string]
        $stashCount = 0

        $fileStatusEnabled = $Force -or $settings.EnableFileStatus
        # Optimization: short-circuit to avoid InDotGitOrBareRepoDir and InDisabledRepository if !$fileStatusEnabled
        if ($fileStatusEnabled -and !$($isDotGitOrBare = InDotGitOrBareRepoDir $GitDir) -and !$(InDisabledRepository)) {
            if ($null -eq $settings.EnableFileStatusFromCache) {
                $settings.EnableFileStatusFromCache = $null -ne (Get-Module GitStatusCachePoshClient)
            }

            if ($settings.EnableFileStatusFromCache) {
                dbg 'Getting status from cache' $sw
                $cacheResponse = Get-GitStatusFromCache

                if ($cacheResponse.Error) {
                    # git-status-cache failed; set $global:GitStatusCacheLoggingEnabled = $true, call Restart-GitStatusCache,
                    # and check %temp%\GitStatusCache_[timestamp].log for details.
                    dbg "Cache returned an error: $($cacheResponse.Error)" $sw
                    $branch = "CACHE ERROR"
                    $behindBy = 1
                }
                else {
                    dbg 'Parsing status' $sw

                    $indexAdded.AddRange($castStringSeq.Invoke($null, (, @($cacheResponse.IndexAdded))))
                    $indexModified.AddRange($castStringSeq.Invoke($null, (, @($cacheResponse.IndexModified))))
                    foreach ($indexRenamed in $cacheResponse.IndexRenamed) {
                        $indexModified.Add($indexRenamed.Old)
                    }
                    $indexDeleted.AddRange($castStringSeq.Invoke($null, (, @($cacheResponse.IndexDeleted))))
                    $indexUnmerged.AddRange($castStringSeq.Invoke($null, (, @($cacheResponse.Conflicted))))

                    $filesAdded.AddRange($castStringSeq.Invoke($null, (, @($cacheResponse.WorkingAdded))))
                    $filesModified.AddRange($castStringSeq.Invoke($null, (, @($cacheResponse.WorkingModified))))
                    foreach ($workingRenamed in $cacheResponse.WorkingRenamed) {
                        $filesModified.Add($workingRenamed.Old)
                    }
                    $filesDeleted.AddRange($castStringSeq.Invoke($null, (, @($cacheResponse.WorkingDeleted))))
                    $filesUnmerged.AddRange($castStringSeq.Invoke($null, (, @($cacheResponse.Conflicted))))

                    $branch = $cacheResponse.Branch
                    $upstream = $cacheResponse.Upstream
                    $gone = $cacheResponse.UpstreamGone
                    $aheadBy = $cacheResponse.AheadBy
                    $behindBy = $cacheResponse.BehindBy

                    if ($settings.EnableStashStatus -and $cacheResponse.Stashes) {
                        $stashCount = $cacheResponse.Stashes.Length
                    }

                    if ($cacheResponse.State) {
                        $branch += "|" + $cacheResponse.State
                    }
                }
            }
            else {
                dbg 'Getting status' $sw
                switch ($settings.UntrackedFilesMode) {
                    "No" { $untrackedFilesOption = "-uno" }
                    "All" { $untrackedFilesOption = "-uall" }
                    default { $untrackedFilesOption = "-unormal" }
                }
                $status = Invoke-Utf8ConsoleCommand { git --no-optional-locks -c core.quotepath=false -c color.status=false status $untrackedFilesOption --short --branch 2>$null }
                if ($settings.EnableStashStatus) {
                    dbg 'Getting stash count' $sw
                    $stashCount = $null | git --no-optional-locks stash list 2>$null | measure-object | Select-Object -expand Count
                }

                dbg 'Parsing status' $sw
                switch -regex ($status) {
                    '^(?<index>[^#])(?<working>.) (?<path1>.*?)(?: -> (?<path2>.*))?$' {
                        if ($sw) { dbg "Status: $_" $sw }

                        $path1 = $matches['path1']

                        # Even with core.quotePath=false, paths with spaces are wrapped in ""
                        # https://github.com/git/git/commit/dbfdc625a5aad10c47e3ffa446d0b92e341a7b44
                        # https://github.com/git/git/commit/f3fc4a1b8680c114defd98ce6f2429f8946a5dc1
                        if ($path1 -like '"*"') {
                            $path1 = $path1.Substring(1, $path1.Length - 2)
                        }

                        switch ($matches['index']) {
                            'A' { $null = $indexAdded.Add($path1); break }
                            'M' { $null = $indexModified.Add($path1); break }
                            'R' { $null = $indexModified.Add($path1); break }
                            'C' { $null = $indexModified.Add($path1); break }
                            'D' { $null = $indexDeleted.Add($path1); break }
                            'U' { $null = $indexUnmerged.Add($path1); break }
                        }
                        switch ($matches['working']) {
                            '?' { $null = $filesAdded.Add($path1); break }
                            'A' { $null = $filesAdded.Add($path1); break }
                            'M' { $null = $filesModified.Add($path1); break }
                            'D' { $null = $filesDeleted.Add($path1); break }
                            'U' { $null = $filesUnmerged.Add($path1); break }
                        }
                        continue
                    }

                    '^## (?<branch>\S+?)(?:\.\.\.(?<upstream>\S+))?(?: \[(?:ahead (?<ahead>\d+))?(?:, )?(?:behind (?<behind>\d+))?(?<gone>gone)?\])?$' {
                        if ($sw) { dbg "Status: $_" $sw }

                        $branch = $matches['branch']
                        $upstream = $matches['upstream']
                        $aheadBy = [int]$matches['ahead']
                        $behindBy = [int]$matches['behind']
                        $gone = [string]$matches['gone'] -eq 'gone'
                        continue
                    }

                    '^## Initial commit on (?<branch>\S+)$' {
                        if ($sw) { dbg "Status: $_" $sw }

                        $branch = $matches['branch']
                        continue
                    }

                    default { if ($sw) { dbg "Status: $_" $sw } }
                }
            }
        }

        $branch = Get-GitBranch -Branch $branch -GitDir $GitDir -IsDotGitOrBare:$isDotGitOrBare -sw $sw

        dbg 'Building status object' $sw

        # This collection is used twice, so create the array just once
        $filesAdded = $filesAdded.ToArray()

        $indexPaths = @(GetUniquePaths $indexAdded, $indexModified, $indexDeleted, $indexUnmerged)
        $workingPaths = @(GetUniquePaths $filesAdded, $filesModified, $filesDeleted, $filesUnmerged)
        $index = (, $indexPaths) |
            Add-Member -Force -PassThru NoteProperty Added    $indexAdded.ToArray() |
            Add-Member -Force -PassThru NoteProperty Modified $indexModified.ToArray() |
            Add-Member -Force -PassThru NoteProperty Deleted  $indexDeleted.ToArray() |
            Add-Member -Force -PassThru NoteProperty Unmerged $indexUnmerged.ToArray()

        $working = (, $workingPaths) |
            Add-Member -Force -PassThru NoteProperty Added    $filesAdded |
            Add-Member -Force -PassThru NoteProperty Modified $filesModified.ToArray() |
            Add-Member -Force -PassThru NoteProperty Deleted  $filesDeleted.ToArray() |
            Add-Member -Force -PassThru NoteProperty Unmerged $filesUnmerged.ToArray()

        $result = New-Object PSObject -Property @{
            GitDir       = $GitDir
            RepoName     = Split-Path (Split-Path $GitDir -Parent) -Leaf
            Branch       = $branch
            AheadBy      = $aheadBy
            BehindBy     = $behindBy
            UpstreamGone = $gone
            Upstream     = $upstream
            HasIndex     = [bool]$index
            Index        = $index
            HasWorking   = [bool]$working
            Working      = $working
            HasUntracked = [bool]$filesAdded
            StashCount   = $stashCount
        }

        dbg 'Finished' $sw
        if ($sw) { $sw.Stop() }
        return $result
    }
}

function InDisabledRepository {
    $currentLocation = Get-Location

    foreach ($repo in $Global:GitPromptSettings.RepositoriesInWhichToDisableFileStatus) {
        if ($currentLocation -like "$repo*") {
            return $true
        }
    }

    return $false
}

function InDotGitOrBareRepoDir([string][ValidateNotNullOrEmpty()]$GitDir) {
    # A UNC path has no drive so it's better to use the ProviderPath e.g. "\\server\share".
    # However for any path with a drive defined, it's better to use the Path property.
    # In this case, ProviderPath is "\LocalMachine\My"" whereas Path is "Cert:\LocalMachine\My".
    # The latter is more desirable.
    $pathInfo = Microsoft.PowerShell.Management\Get-Location
    $currentPath = if ($pathInfo.Drive) { $pathInfo.Path } else { $pathInfo.ProviderPath }
    $separator = [System.IO.Path]::DirectorySeparatorChar
    $res = "$currentPath$separator".StartsWith("$GitDir$separator", (Get-PathStringComparison))
    $res
}

function Get-AliasPattern($cmd) {
    $aliases = @($cmd) + @(Get-Alias | Where-Object { $_.Definition -match "^$cmd(\.exe)?$" } | Foreach-Object Name)
    "($($aliases -join '|'))"
}

<#
.SYNOPSIS
    Deletes the specified Git branches.
.DESCRIPTION
    Deletes the specified Git branches that have been merged into the commit specified by the Commit parameter (HEAD by default). You must either specify a branch name via the Name parameter, which accepts wildard characters, or via the Pattern parameter, which accepts a regular expression.

    The following branches are always excluded from deletion:

    * The current branch
    * develop
    * master

    The default set of excluded branches can be overridden with the ExcludePattern parameter.

    Consider always running this command FIRST with the WhatIf parameter. This will show you which branches will be deleted. This gives you a chance to adjust your branch name wildcard pattern or regular expression if you are using the Pattern parameter.

    IMPORTANT: Be careful using this command. Even though by default this command deletes only merged branches, most, if not all, of your historical branches have been merged. But that doesn't mean you want to delete them. That is why this command excludes `develop` and `master` by default. But you may use different names e.g. `development` or have other historical branches you don't want to delete. In these cases, you can either:

    * Specify a narrower branch name wildcard such as "user/$env:USERNAME/*".
    * Specify an updated ExcludeParameter e.g. '(^\*)|(^. (develop|master|v\d+)$)' which adds any branch matching the pattern 'v\d+' to the exclusion list.

    If necessary, you can delete the specified branches REGARDLESS of their merge status by using the IncludeUnmerged parameter. BE VERY CAREFUL using the IncludeUnmerged parameter together with the Force parameter, since you will not be given the opportunity to confirm each branch deletion.

    The following Git commands are executed by this command:

        git branch --merged $Commit |
            Where-Object { $_ -notmatch $ExcludePattern } |
            Where-Object { $_.Trim() -like $Name } |
            Foreach-Object { git branch --delete $_.Trim() }

    If the IncludeUnmerged parameter is specified, execution changes to:

        git branch |
            Where-Object { $_ -notmatch $ExcludePattern } |
            Where-Object { $_.Trim() -like $Name } |
            Foreach-Object { git branch --delete $_.Trim() }

    If the DeleteForce parameter is specified, the Foreach-Object changes to:

        Foreach-Object { git branch --delete --force $_.Trim() }

    If the Pattern parameter is used instead of the Name parameter, the second Where-Object changes to:

        Where-Object { $_ -match $Pattern }

    Recovering Deleted Branches

    If you wind up deleting a branch you didn't intend to, you can easily recover it with the info provided by Git during the delete. For instance, let's say you realized you didn't want to delete the branch 'feature/exp1'. In the output of this command, you should see a deletion entry for this branch that looks like:

        Deleted branch feature/exp1 (was 08f9000).

    To recover this branch, execute the following Git command:

        # git branch <branch-name> <sha1>
        git branch feature/exp1 08f9000
.EXAMPLE
    PS> Remove-GitBranch -Name "user/${env:USERNAME}/*" -WhatIf
    Shows the merged branches that would be deleted by the specified branch name without actually deleting. Remove the WhatIf parameter when you are happy with the list of branches that will be deleted.
.EXAMPLE
    PS> Remove-GitBranch "feature/*" -Force
    Deletes the merged branches that match the specified wildcard. Using the Force parameter skips all confirmation prompts. Name is a positional parameter. The first argument is assumed to be the value of the Name parameter.
.EXAMPLE
    PS> Remove-GitBranch "bugfix/*" -Force -DeleteForce
    Deletes the merged branches that match the specified wildcard. Using the Force parameter skips all confirmation prompts while the DeleteForce parameter uses the --force option in the underlying Git command.
.EXAMPLE
    PS> Remove-GitBranch -Pattern 'user/(dahlbyk|hillr)/.*'
    Deletes the merged branches that match the specified regular expression.
.EXAMPLE
    PS> Remove-GitBranch -Name * -ExcludePattern '(^\*)|(^. (develop|master|v\d+)$)'
    Deletes merged branches except the current branch, develop, master and branches that also match the pattern 'v\d+' e.g. v1, v1.0, v1.x. BE VERY CAREFUL SPECIYING SUCH A BROAD BRANCH NAME WILDCARD!
.EXAMPLE
    PS> Remove-GitBranch "feature/*" -IncludeUnmerged -WhatIf
    Shows the branches, both merged and unmerged, that match the specified wildcard that would be deleted without actually deleting them. Once you've verified the list of branches looks correct, remove the WhatIf parameter to actually delete the branches.
#>
function Remove-GitBranch {
    [CmdletBinding(DefaultParameterSetName = "Wildcard", SupportsShouldProcess, ConfirmImpact = "Medium")]
    param(
        # Specifies a regular expression pattern for the branches that will be deleted. Certain branches are always excluded from deletion e.g. the current branch as well as the develop and master branches. See the ExcludePattern parameter to modify that pattern.
        [Parameter(Position = 0, Mandatory, ParameterSetName = "Wildcard")]
        [ValidateNotNullOrEmpty()]
        [string]
        $Name,

        # Specifies a regular expression for the branches that will be deleted. Certain branches are always excluded from deletion e.g. the current branch as well as the develop and master branches. See the ExcludePattern parameter to modify that pattern.
        [Parameter(Position = 0, Mandatory, ParameterSetName = "Pattern")]
        [ValidateNotNull()]
        [string]
        $Pattern,

        # Specifies a regular expression used to exclude merged branches from being deleted. The default pattern excludes the current branch, develop and master branches.
        [Parameter()]
        [ValidateNotNull()]
        [string]
        $ExcludePattern = '(^\*)|(^. (develop|master)$)',

        # Branches whose tips are reachable from the specified commit will be deleted. The default commit is HEAD. This parameter is ignored if the IncludeUnmerged parameter is specified.
        [Parameter()]
        [string]
        $Commit = "HEAD",

        # Specifies that unmerged branches are also eligible to be deleted.
        [Parameter()]
        [switch]
        $IncludeUnmerged,

        # Deletes the specified branches without prompting for confirmation. By default, Remove-GitBranch prompts for confirmation before deleting branches.
        [Parameter()]
        [switch]
        $Force,

        # Deletes the specified branches by adding the --force parameter to the git branch --delete command e.g. git branch --delete --force <branch-name>. This is also the equivalent of using the -D parameter on the git branch command.
        [Parameter()]
        [switch]
        $DeleteForce
    )

    if ($IncludeUnmerged) {
        $branches = git branch
    }
    else {
        $branches = git branch --merged $Commit
    }

    $filteredBranches = $branches | Where-Object { $_ -notmatch $ExcludePattern }

    if ($PSCmdlet.ParameterSetName -eq "Wildcard") {
        $branchesToDelete = $filteredBranches | Where-Object { $_.Trim() -like $Name }
    }
    else {
        $branchesToDelete = $filteredBranches | Where-Object { $_ -match $Pattern }
    }

    $action = if ($DeleteForce) { "delete with force" } else { "delete" }
    $yesToAll = $noToAll = $false

    foreach ($branch in $branchesToDelete) {
        $targetBranch = $branch.Trim()
        if ($PSCmdlet.ShouldProcess($targetBranch, $action)) {
            if ($Force -or $yesToAll -or
                $PSCmdlet.ShouldContinue(
                    "Are you REALLY sure you want to $action `"$targetBranch`"?",
                    "Confirm branch deletion", [ref]$yesToAll, [ref]$noToAll)) {

                if ($noToAll) { return }

                if ($DeleteForce) {
                    Invoke-Utf8ConsoleCommand { git branch --delete --force $targetBranch }
                }
                else {
                    Invoke-Utf8ConsoleCommand { git branch --delete $targetBranch }
                }
            }
        }
    }
}

function Update-AllBranches($Upstream = 'master', [switch]$Quiet) {
    $head = git rev-parse --abbrev-ref HEAD
    git checkout -q $Upstream
    $branches = Invoke-Utf8ConsoleCommand { (git branch --no-color --no-merged) } | Where-Object { $_ -notmatch '^\* ' }
    foreach ($line in $branches) {
        $branch = $line.SubString(2)
        if (!$Quiet) { Write-Host "Rebasing $branch onto $Upstream..." }

        git rebase -q $Upstream $branch > $null 2> $null
        if ($LASTEXITCODE) {
            git rebase --abort
            Write-Warning "Rebase failed for $branch"
        }
    }

    git checkout -q $head
}

Write-DebugTiming -Label 'GitUtils'
#endregion

# ============================================================================
#region GitPrompt
# ============================================================================
# Inspired by Mark Embling
# http://www.markembling.info/view/my-ideal-powershell-prompt-with-git-integration

$global:GitPromptSettings = [PoshGitPromptSettings]::new()
$global:GitPromptValues = [PoshGitPromptValues]::new()

# Override some of the normal colors if the background color is set to the default DarkMagenta.
$s = $global:GitPromptSettings
if ($Host.UI.RawUI.BackgroundColor -eq [ConsoleColor]::DarkMagenta) {
    $s.LocalDefaultStatusSymbol.ForegroundColor = 'Green'
    $s.LocalWorkingStatusSymbol.ForegroundColor = 'Red'
    $s.BeforeIndex.ForegroundColor              = 'Green'
    $s.IndexColor.ForegroundColor               = 'Green'
    $s.WorkingColor.ForegroundColor             = 'Red'
}

<#
.SYNOPSIS
    Creates a new instance of a PoshGitPromptSettings object that can be assigned to $GitPromptSettings.
.DESCRIPTION
    Creates a new instance of a PoshGitPromptSettings object that can be used to reset the
    $GitPromptSettings back to its default.
.INPUTS
    None
.OUTPUTS
    PoshGitPromptSettings
.EXAMPLE
    PS> $GitPromptSettings = New-GitPromptSettings
    This will reset the current $GitPromptSettings back to its default.
#>
function New-GitPromptSettings {
    [PoshGitPromptSettings]::new()
}

<#
.SYNOPSIS
    Writes the object to the display or renders it as a string using ANSI/VT sequences.
.DESCRIPTION
    Writes the specified object to the display unless $GitPromptSettings.AnsiConsole
    is enabled.  In this case, the Object is rendered, along with the specified
    colors, as a string with the appropriate ANSI/VT sequences for colors embedded
    in the string.  If a StringBuilder is provided, the string is appended to the
    StringBuilder.
.EXAMPLE
    PS C:\> Write-Prompt "PS > " -ForegroundColor Cyan -BackgroundColor Black
    On a system where $GitPromptSettings.AnsiConsole is set to $false, this
    will write the above to the display using the Write-Host command.
    If AnsiConsole is set to $true, this will return a string of the form:
    "`e[96m`e[40mPS > `e[0m".
.EXAMPLE
    PS C:\> $sb = [System.Text.StringBuilder]::new()
    PS C:\> $sb | Write-Prompt "PS > " -ForegroundColor Cyan -BackgroundColor Black
    On a system where $GitPromptSettings.AnsiConsole is set to $false, this
    will write the above to the display using the Write-Host command.
    If AnsiConsole is set to $true, this will append the following string to the
    StringBuilder object piped into the command:
    "`e[96m`e[40mPS > `e[0m".
#>
function Write-Prompt {
    [CmdletBinding(DefaultParameterSetName="Default")]
    param(
        # Specifies objects to display in the console or render as a string if
        # $GitPromptSettings.AnsiConsole is enabled. If the Object is of type
        # [PoshGitTextSpan] the other color parameters are ignored since a
        # [PoshGitTextSpan] provides the colors.
        [Parameter(Mandatory, Position=0)]
        $Object,

        # Specifies the foreground color.
        [Parameter(ParameterSetName="Default")]
        $ForegroundColor = $null,

        # Specifies the background color.
        [Parameter(ParameterSetName="Default")]
        $BackgroundColor = $null,

        # Specifies both the background and foreground colors via [PoshGitCellColor] object.
        [Parameter(ParameterSetName="CellColor")]
        [ValidateNotNull()]
        [PoshGitCellColor]
        $Color,

        # When specified and $GitPromptSettings.AnsiConsole is enabled, the Object parameter
        # is written to the StringBuilder along with the appropriate ANSI/VT sequences for
        # the specified foreground and background colors.
        [Parameter(ValueFromPipeline = $true)]
        [System.Text.StringBuilder]
        $StringBuilder
    )

    if (!$Object -or (($Object -is [PoshGitTextSpan]) -and !$Object.Text)) {
        return $(if ($StringBuilder) { $StringBuilder } else { "" })
    }

    if ($PSCmdlet.ParameterSetName -eq "CellColor") {
        $bgColor = $Color.BackgroundColor
        $fgColor = $Color.ForegroundColor
    }
    else {
        $bgColor = $BackgroundColor
        $fgColor = $ForegroundColor
    }

    $s = $global:GitPromptSettings
    if ($s) {
        if ($null -eq $fgColor) {
            $fgColor = $s.DefaultColor.ForegroundColor
        }

        if ($null -eq $bgColor) {
            $bgColor = $s.DefaultColor.BackgroundColor
        }

        if ($s.AnsiConsole) {
            if ($Object -is [PoshGitTextSpan]) {
                $str = $Object.ToAnsiString()
            }
            else {
                # If we know which colors were changed, we can reset only these and leave others be.
                $reset = [System.Collections.Generic.List[string]]::new()
                $e = [char]27 + "["

                $fg = $fgColor
                if (($null -ne $fg) -and !(Test-VirtualTerminalSequece $fg)) {
                    $fg = Get-ForegroundVirtualTerminalSequence $fg
                    $reset.Add('39')
                }

                $bg = $bgColor
                if (($null -ne $bg) -and !(Test-VirtualTerminalSequece $bg)) {
                    $bg = Get-BackgroundVirtualTerminalSequence $bg
                    $reset.Add('49')
                }

                $str = "${Object}"
                if (Test-VirtualTerminalSequece $str -Force) {
                    $reset.Clear()
                    $reset.Add('0')
                }

                $str = "${fg}${bg}" + $str
                if ($reset.Count -gt 0) {
                    $str += "${e}$($reset -join ';')m"
                }
            }

            return $(if ($StringBuilder) { $StringBuilder.Append($str) } else { $str })
        }
    }

    if ($Object -is [PoshGitTextSpan]) {
        $bgColor = $Object.BackgroundColor
        $fgColor = $Object.ForegroundColor
        $Object = $Object.Text
    }

    $writeHostParams = @{
        Object = $Object;
        NoNewLine = $true;
    }

    if ($bgColor -and ($bgColor -ge 0) -and ($bgColor -le 15)) {
        $writeHostParams.BackgroundColor = $bgColor
    }

    if ($fgColor -and ($fgColor -ge 0) -and ($fgColor -le 15)) {
        $writeHostParams.ForegroundColor = $fgColor
    }

    Write-Host @writeHostParams
    return $(if ($StringBuilder) { $StringBuilder } else { "" })
}

<#
.SYNOPSIS
    Writes the Git status for repo.  Typically, you use Write-VcsStatus
    function instead of this one.
.DESCRIPTION
    Writes the Git status for repo. This includes the branch name, branch
    status with respect to its remote (if exists), index status, working
    dir status, working dir local status and stash count (optional).
    Various settings from GitPromptSettngs are used to format and color
    the Git status.

    On systems that support ANSI terminal sequences, this method will
    return a string containing ANSI sequences to color various parts of
    the Git status string.  This string can be written to the host and
    the ANSI sequences will be interpreted and converted to the specified
    behaviors which is typically setting the foreground and/or background
    color of text.
.EXAMPLE
    PS C:\> Write-GitStatus (Get-GitStatus)

    Writes the Git status for the current repo.
.INPUTS
    System.Management.Automation.PSCustomObject
        This is PSCustomObject returned by Get-GitStatus
.OUTPUTS
    System.String
        This command returns a System.String object.
#>
function Write-GitStatus {
    param(
        # The Git status object that provides the status information to be written.
        # This object is retrieved via the Get-GitStatus command.
        [Parameter(Position = 0)]
        $Status
    )

    $s = $global:GitPromptSettings
    if (!$Status -or !$s) {
        return
    }

    $sb = [System.Text.StringBuilder]::new(150)

    # When prompt is first (default), place the separator before the status summary
    if (!$s.DefaultPromptWriteStatusFirst) {
        $sb | Write-Prompt $s.PathStatusSeparator.Expand() > $null
    }

    $sb | Write-Prompt $s.BeforeStatus > $null
    $sb | Write-GitBranchName $Status -NoLeadingSpace > $null
    $sb | Write-GitBranchStatus $Status > $null

    $sb | Write-Prompt $s.BeforeIndex > $null

    if ($s.EnableFileStatus -and $Status.HasIndex) {
        $sb | Write-GitIndexStatus $Status > $null

        if ($Status.HasWorking) {
            $sb | Write-Prompt $s.DelimStatus > $null
        }
    }

    if ($s.EnableFileStatus -and $Status.HasWorking) {
        $sb | Write-GitWorkingDirStatus $Status > $null
    }

    $sb | Write-GitWorkingDirStatusSummary $Status > $null

    if ($s.EnableStashStatus -and ($Status.StashCount -gt 0)) {
        $sb | Write-GitStashCount $Status > $null
    }

    $sb | Write-Prompt $s.AfterStatus > $null

    # When status is first, place the separator after the status summary
    if ($s.DefaultPromptWriteStatusFirst) {
        $sb | Write-Prompt $s.PathStatusSeparator.Expand() > $null
    }

    if ($sb.Length -gt 0) {
        $sb.ToString()
    }
}

<#
.SYNOPSIS
    Formats the branch name text according to $GitPromptSettings.
.DESCRIPTION
    Formats the branch name text according the $GitPromptSettings:
    BranchNameLimit and TruncatedBranchSuffix.
.EXAMPLE
    PS C:\> $branchName = Format-GitBranchName (Get-GitStatus).Branch

    Gets the branch name formatted as specified by the user's $GitPromptSettings.
.INPUTS
    System.String
        This is the branch name as a string.
.OUTPUTS
    System.String
        This command returns a System.String object.
#>
function Format-GitBranchName {
    param(
        # The branch name to format according to the GitPromptSettings:
        # BranchNameLimit and TruncatedBranchSuffix.
        [Parameter(Position=0)]
        [string]
        $BranchName
    )

    $s = $global:GitPromptSettings
    if (!$s -or !$BranchName) {
        return "$BranchName"
    }

    $res = $BranchName
    if (($s.BranchNameLimit -gt 0) -and ($BranchName.Length -gt $s.BranchNameLimit))
    {
        $res = "{0}{1}" -f $BranchName.Substring(0, $s.BranchNameLimit), $s.TruncatedBranchSuffix
    }

    $res
}

<#
.SYNOPSIS
    Gets the colors to use for the branch status.
.DESCRIPTION
    Gets the colors to use for the branch status. This color is typically
    used for the branch name as well.  The default color is specified by
    $GitPromptSettins.BranchColor.  But depending on the Git status object
    passed in, the colors could be changed to match that of one these
    other $GitPromptSettings: BranchBehindAndAheadStatusSymbol,
    BranchBehindStatusSymbol or BranchAheadStatusSymbol.
.EXAMPLE
    PS C:\> $branchStatusColor = Get-GitBranchStatusColor (Get-GitStatus)

    Returns a PoshGitTextSpan with the foreground and background colors
    for the branch status.
.INPUTS
    System.Management.Automation.PSCustomObject
        This is PSCustomObject returned by Get-GitStatus
.OUTPUTS
    PoshGitTextSpan
        A PoshGitTextSpan with colors reflecting those to be used by
        branch status symbols.
#>
function Get-GitBranchStatusColor {
    param(
        # The Git status object that provides branch status information.
        # This object is retrieved via the Get-GitStatus command.
        [Parameter(Position = 0)]
        $Status
    )

    $s = $global:GitPromptSettings
    if (!$s) {
        return [PoshGitTextSpan]::new()
    }

    $branchStatusTextSpan = [PoshGitTextSpan]::new($s.BranchColor)

    if (($Status.BehindBy -ge 1) -and ($Status.AheadBy -ge 1)) {
        # We are both behind and ahead of remote
        $branchStatusTextSpan = [PoshGitTextSpan]::new($s.BranchBehindAndAheadStatusSymbol)
    }
    elseif ($Status.BehindBy -ge 1) {
        # We are behind remote
        $branchStatusTextSpan = [PoshGitTextSpan]::new($s.BranchBehindStatusSymbol)
    }
    elseif ($Status.AheadBy -ge 1) {
        # We are ahead of remote
        $branchStatusTextSpan = [PoshGitTextSpan]::new($s.BranchAheadStatusSymbol)
    }

    $branchStatusTextSpan.Text = ''
    $branchStatusTextSpan
}

<#
.SYNOPSIS
    Writes the branch name given the current Git status.
.DESCRIPTION
    Writes the branch name given the current Git status which can retrieved
    via the Get-GitStatus command. Branch name can be affected by the
    $GitPromptSettings: BranchColor, BranchNameLimit, TruncatedBranchSuffix
    and Branch*StatusSymbol colors.
.EXAMPLE
    PS C:\> Write-GitBranchName (Get-GitStatus)

    Writes the name of the current branch.
.INPUTS
    System.Management.Automation.PSCustomObject
        This is PSCustomObject returned by Get-GitStatus
.OUTPUTS
    System.String, System.Text.StringBuilder
        This command returns a System.String object unless the -StringBuilder parameter
        is supplied. In this case, it returns a System.Text.StringBuilder.
#>
function Write-GitBranchName {
    param(
        # The Git status object that provides the status information to be written.
        # This object is retrieved via the Get-GitStatus command.
        [Parameter(Position = 0)]
        $Status,

        # If specified the branch name is written into the provided StringBuilder object.
        [Parameter(ValueFromPipeline = $true)]
        [System.Text.StringBuilder]
        $StringBuilder,

        # If specified, suppresses the output of the leading space character.
        [Parameter()]
        [switch]
        $NoLeadingSpace
    )

    $s = $global:GitPromptSettings
    if (!$Status -or !$s) {
        return $(if ($StringBuilder) { $StringBuilder } else { "" })
    }

    $str = ""

    # Use the branch status colors (or CustomAnsi) to display the branch name
    $branchNameTextSpan = Get-GitBranchStatusColor $Status
    $branchNameTextSpan.Text = Format-GitBranchName $Status.Branch
    if (!$NoLeadingSpace) {
        $branchNameTextSpan.Text = " " + $branchNameTextSpan.Text
    }

    if ($StringBuilder) {
        $StringBuilder | Write-Prompt $branchNameTextSpan > $null
    }
    else {
        $str = Write-Prompt $branchNameTextSpan
    }

    return $(if ($StringBuilder) { $StringBuilder } else { $str })
}

<#
.SYNOPSIS
    Writes the branch status text given the current Git status.
.DESCRIPTION
    Writes the branch status text given the current Git status which can retrieved
    via the Get-GitStatus command. Branch status includes information about the
    upstream branch, how far behind and/or ahead the local branch is from the remote.
.EXAMPLE
    PS C:\> Write-GitBranchStatus (Get-GitStatus)

    Writes the status of the current branch to the host.
.INPUTS
    System.Management.Automation.PSCustomObject
        This is PSCustomObject returned by Get-GitStatus
.OUTPUTS
    System.String, System.Text.StringBuilder
        This command returns a System.String object unless the -StringBuilder parameter
        is supplied. In this case, it returns a System.Text.StringBuilder.
#>
function Write-GitBranchStatus {
    param(
        # The Git status object that provides the status information to be written.
        # This object is retrieved via the Get-GitStatus command.
        [Parameter(Position = 0)]
        $Status,

        # If specified the branch status is written into the provided StringBuilder object.
        [Parameter(ValueFromPipeline = $true)]
        [System.Text.StringBuilder]
        $StringBuilder,

        # If specified, suppresses the output of the leading space character.
        [Parameter()]
        [switch]
        $NoLeadingSpace
    )

    $s = $global:GitPromptSettings
    if (!$Status -or !$s) {
        return $(if ($StringBuilder) { $StringBuilder } else { "" })
    }

    $branchStatusTextSpan = Get-GitBranchStatusColor $Status

    if (!$Status.Upstream) {
        $branchStatusTextSpan.Text = $s.BranchUntrackedText
    }
    elseif ($Status.UpstreamGone -eq $true) {
        # Upstream branch is gone
        $branchStatusTextSpan.Text = $s.BranchGoneStatusSymbol.Text
    }
    elseif (($Status.BehindBy -eq 0) -and ($Status.AheadBy -eq 0)) {
        # We are aligned with remote
        $branchStatusTextSpan.Text = $s.BranchIdenticalStatusSymbol.Text
    }
    elseif (($Status.BehindBy -ge 1) -and ($Status.AheadBy -ge 1)) {
        # We are both behind and ahead of remote
        if ($s.BranchBehindAndAheadDisplay -eq "Full") {
            $branchStatusTextSpan.Text = ("{0}{1} {2}{3}" -f $s.BranchBehindStatusSymbol.Text, $Status.BehindBy, $s.BranchAheadStatusSymbol.Text, $status.AheadBy)
        }
        elseif ($s.BranchBehindAndAheadDisplay -eq "Compact") {
            $branchStatusTextSpan.Text = ("{0}{1}{2}" -f $Status.BehindBy, $s.BranchBehindAndAheadStatusSymbol.Text, $Status.AheadBy)
        }
        else {
            $branchStatusTextSpan.Text = $s.BranchBehindAndAheadStatusSymbol.Text
        }
    }
    elseif ($Status.BehindBy -ge 1) {
        # We are behind remote
        if (($s.BranchBehindAndAheadDisplay -eq "Full") -Or ($s.BranchBehindAndAheadDisplay -eq "Compact")) {
            $branchStatusTextSpan.Text = ("{0}{1}" -f $s.BranchBehindStatusSymbol.Text, $Status.BehindBy)
        }
        else {
            $branchStatusTextSpan.Text = $s.BranchBehindStatusSymbol.Text
        }
    }
    elseif ($Status.AheadBy -ge 1) {
        # We are ahead of remote
        if (($s.BranchBehindAndAheadDisplay -eq "Full") -or ($s.BranchBehindAndAheadDisplay -eq "Compact")) {
            $branchStatusTextSpan.Text = ("{0}{1}" -f $s.BranchAheadStatusSymbol.Text, $Status.AheadBy)
        }
        else {
            $branchStatusTextSpan.Text = $s.BranchAheadStatusSymbol.Text
        }
    }
    else {
        # This condition should not be possible but defaulting the variables to be safe
        $branchStatusTextSpan.Text = "?"
    }

    $str = ""
    if ($branchStatusTextSpan.Text) {
        $textSpan = [PoshGitTextSpan]::new($branchStatusTextSpan)
        if (!$NoLeadingSpace) {
            $textSpan.Text = " " + $branchStatusTextSpan.Text
        }

        if ($StringBuilder) {
            $StringBuilder | Write-Prompt $textSpan > $null
        }
        else {
            $str = Write-Prompt $textSpan
        }
    }

    return $(if ($StringBuilder) { $StringBuilder } else { $str })
}

<#
.SYNOPSIS
    Writes the index status text given the current Git status.
.DESCRIPTION
    Writes the index status text given the current Git status.
.EXAMPLE
    PS C:\> Write-GitIndexStatus (Get-GitStatus)

    Writes the Git index status to the host.
.INPUTS
    System.Management.Automation.PSCustomObject
        This is PSCustomObject returned by Get-GitStatus
.OUTPUTS
    System.String, System.Text.StringBuilder
        This command returns a System.String object unless the -StringBuilder parameter
        is supplied. In this case, it returns a System.Text.StringBuilder.
#>
function Write-GitIndexStatus {
    param(
        # The Git status object that provides the status information to be written.
        # This object is retrieved via the Get-GitStatus command.
        [Parameter(Position = 0)]
        $Status,

        # If specified the index status is written into the provided StringBuilder object.
        [Parameter(ValueFromPipeline = $true)]
        [System.Text.StringBuilder]
        $StringBuilder,

        # If specified, suppresses the output of the leading space character.
        [Parameter()]
        [switch]
        $NoLeadingSpace
    )

    $s = $global:GitPromptSettings
    if (!$Status -or !$s) {
        return $(if ($StringBuilder) { $StringBuilder } else { "" })
    }

    $str = ""

    if ($Status.HasIndex) {
        if ($s.ShowStatusWhenZero -or $Status.Index.Added) {
            $indexStatusText = " "
            if ($NoLeadingSpace) {
                $indexStatusText = ""
                $NoLeadingSpace = $false
            }

            $indexStatusText += "$($s.FileAddedText)$($Status.Index.Added.Count)"

            if ($StringBuilder) {
                $StringBuilder | Write-Prompt $indexStatusText -Color $s.IndexColor > $null
            }
            else {
                $str += Write-Prompt $indexStatusText -Color $s.IndexColor
            }
        }

        if ($s.ShowStatusWhenZero -or $status.Index.Modified) {
            $indexStatusText = " "
            if ($NoLeadingSpace) {
                $indexStatusText = ""
                $NoLeadingSpace = $false
            }

            $indexStatusText += "$($s.FileModifiedText)$($status.Index.Modified.Count)"

            if ($StringBuilder) {
                $StringBuilder | Write-Prompt $indexStatusText -Color $s.IndexColor > $null
            }
            else {
                $str += Write-Prompt $indexStatusText -Color $s.IndexColor
            }
        }

        if ($s.ShowStatusWhenZero -or $Status.Index.Deleted) {
            $indexStatusText = " "
            if ($NoLeadingSpace) {
                $indexStatusText = ""
                $NoLeadingSpace = $false
            }

            $indexStatusText += "$($s.FileRemovedText)$($Status.Index.Deleted.Count)"

            if ($StringBuilder) {
                $StringBuilder | Write-Prompt $indexStatusText -Color $s.IndexColor > $null
            }
            else {
                $str += Write-Prompt $indexStatusText -Color $s.IndexColor
            }
        }

        if ($Status.Index.Unmerged) {
            $indexStatusText = " "
            if ($NoLeadingSpace) {
                $indexStatusText = ""
                $NoLeadingSpace = $false
            }

            $indexStatusText += "$($s.FileConflictedText)$($Status.Index.Unmerged.Count)"

            if ($StringBuilder) {
                $StringBuilder | Write-Prompt $indexStatusText -Color $s.IndexColor > $null
            }
            else {
                $str += Write-Prompt $indexStatusText -Color $s.IndexColor
            }
        }
    }

    return $(if ($StringBuilder) { $StringBuilder } else { $str })
}

<#
.SYNOPSIS
    Writes the working directory status text given the current Git status.
.DESCRIPTION
    Writes the working directory status text given the current Git status.
.EXAMPLE
    PS C:\> Write-GitWorkingDirStatus (Get-GitStatus)

    Writes the Git working directory status to the host.
.INPUTS
    System.Management.Automation.PSCustomObject
        This is PSCustomObject returned by Get-GitStatus
.OUTPUTS
    System.String, System.Text.StringBuilder
        This command returns a System.String object unless the -StringBuilder parameter
        is supplied. In this case, it returns a System.Text.StringBuilder.
#>
function Write-GitWorkingDirStatus {
    param(
        # The Git status object that provides the status information to be written.
        # This object is retrieved via the Get-GitStatus command.
        [Parameter(Position = 0)]
        $Status,

        # If specified the working dir status is written into the provided StringBuilder object.
        [Parameter(ValueFromPipeline = $true)]
        [System.Text.StringBuilder]
        $StringBuilder,

        # If specified, suppresses the output of the leading space character.
        [Parameter()]
        [switch]
        $NoLeadingSpace
    )

    $s = $global:GitPromptSettings
    if (!$Status -or !$s) {
        return $(if ($StringBuilder) { $StringBuilder } else { "" })
    }

    $str = ""

    if ($Status.HasWorking) {
        if ($s.ShowStatusWhenZero -or $Status.Working.Added) {
            $workingStatusText = " "
            if ($NoLeadingSpace) {
                $workingStatusText = ""
                $NoLeadingSpace = $false
            }

            $workingStatusText += "$($s.FileAddedText)$($Status.Working.Added.Count)"

            if ($StringBuilder) {
                $StringBuilder | Write-Prompt $workingStatusText -Color $s.WorkingColor > $null
            }
            else {
                $str += Write-Prompt $workingStatusText -Color $s.WorkingColor
            }
        }

        if ($s.ShowStatusWhenZero -or $Status.Working.Modified) {
            $workingStatusText = " "
            if ($NoLeadingSpace) {
                $workingStatusText = ""
                $NoLeadingSpace = $false
            }

            $workingStatusText += "$($s.FileModifiedText)$($Status.Working.Modified.Count)"

            if ($StringBuilder) {
                $StringBuilder | Write-Prompt $workingStatusText -Color $s.WorkingColor > $null
            }
            else {
                $str += Write-Prompt $workingStatusText -Color $s.WorkingColor
            }
        }

        if ($s.ShowStatusWhenZero -or $Status.Working.Deleted) {
            $workingStatusText = " "
            if ($NoLeadingSpace) {
                $workingStatusText = ""
                $NoLeadingSpace = $false
            }

            $workingStatusText += "$($s.FileRemovedText)$($Status.Working.Deleted.Count)"

            if ($StringBuilder) {
                $StringBuilder | Write-Prompt $workingStatusText -Color $s.WorkingColor > $null
            }
            else {
                $str += Write-Prompt $workingStatusText -Color $s.WorkingColor
            }
        }

        if ($Status.Working.Unmerged) {
            $workingStatusText = " "
            if ($NoLeadingSpace) {
                $workingStatusText = ""
                $NoLeadingSpace = $false
            }

            $workingStatusText += "$($s.FileConflictedText)$($Status.Working.Unmerged.Count)"

            if ($StringBuilder) {
                $StringBuilder | Write-Prompt $workingStatusText -Color $s.WorkingColor > $null
            }
            else {
                $str += Write-Prompt $workingStatusText -Color $s.WorkingColor
            }
        }
    }

    return $(if ($StringBuilder) { $StringBuilder } else { $str })
}

<#
.SYNOPSIS
    Writes the working directory status summary text given the current Git status.
.DESCRIPTION
    Writes the working directory status summary text given the current Git status.
    If there are any unstaged commits, the $GitPromptSettings.LocalWorkingStatusSymbol
    will be output.  If not, then if are any staged but uncommmited changes, the
    $GitPromptSettings.LocalStagedStatusSymbol will be output.  If not, then
    $GitPromptSettings.LocalDefaultStatusSymbol will be output.
.EXAMPLE
    PS C:\> Write-GitWorkingDirStatusSummary (Get-GitStatus)

    Outputs the Git working directory status summary text.
.INPUTS
    System.Management.Automation.PSCustomObject
        This is PSCustomObject returned by Get-GitStatus
.OUTPUTS
    System.String, System.Text.StringBuilder
        This command returns a System.String object unless the -StringBuilder parameter
        is supplied. In this case, it returns a System.Text.StringBuilder.
#>
function Write-GitWorkingDirStatusSummary {
    param(
        # The Git status object that provides the status information to be written.
        # This object is retrieved via the Get-GitStatus command.
        [Parameter(Position = 0)]
        $Status,

        # If specified the working dir local status is written into the provided StringBuilder object.
        [Parameter(ValueFromPipeline = $true)]
        [System.Text.StringBuilder]
        $StringBuilder,

        # If specified, suppresses the output of the leading space character.
        [Parameter()]
        [switch]
        $NoLeadingSpace
    )

    $s = $global:GitPromptSettings
    if (!$Status -or !$s) {
        return $(if ($StringBuilder) { $StringBuilder } else { "" })
    }

    $str = ""

    # No uncommited changes
    $localStatusSymbol = $s.LocalDefaultStatusSymbol

    if ($Status.HasWorking) {
        # We have un-staged files in the working tree
        $localStatusSymbol = $s.LocalWorkingStatusSymbol
    }
    elseif ($Status.HasIndex) {
        # We have staged but uncommited files
        $localStatusSymbol = $s.LocalStagedStatusSymbol
    }

    if ($localStatusSymbol.Text) {
        $textSpan = [PoshGitTextSpan]::new($localStatusSymbol)
        if (!$NoLeadingSpace) {
            $textSpan.Text = " " + $localStatusSymbol.Text
        }

        if ($StringBuilder) {
            $StringBuilder | Write-Prompt $textSpan > $null
        }
        else {
            $str += Write-Prompt $textSpan
        }
    }

    return $(if ($StringBuilder) { $StringBuilder } else { $str })
}

<#
.SYNOPSIS
    Writes the stash count given the current Git status.
.DESCRIPTION
    Writes the stash count given the current Git status.
.EXAMPLE
    PS C:\> Write-GitStashCount (Get-GitStatus)

    Writes the Git stash count to the host.
.INPUTS
    System.Management.Automation.PSCustomObject
        This is PSCustomObject returned by Get-GitStatus
.OUTPUTS
    System.String, System.Text.StringBuilder
        This command returns a System.String object unless the -StringBuilder parameter
        is supplied. In this case, it returns a System.Text.StringBuilder.
#>
function Write-GitStashCount {
    param(
        # The Git status object that provides the status information to be written.
        # This object is retrieved via the Get-GitStatus command.
        [Parameter(Position = 0)]
        $Status,

        # If specified the working dir local status is written into the provided StringBuilder object.
        [Parameter(ValueFromPipeline = $true)]
        [System.Text.StringBuilder]
        $StringBuilder
    )

    $s = $global:GitPromptSettings
    if (!$Status -or !$s) {
        return $(if ($StringBuilder) { $StringBuilder } else { "" })
    }

    $str = ""

    if ($Status.StashCount -gt 0) {
        $stashText = "$($Status.StashCount)"

        if ($StringBuilder) {
            $StringBuilder | Write-Prompt $s.BeforeStash > $null
            $StringBuilder | Write-Prompt $stashText -Color $s.StashColor > $null
            $StringBuilder | Write-Prompt $s.AfterStash > $null
        }
        else {
            $str += Write-Prompt $s.BeforeStash
            $str += Write-Prompt $stashText -Color $s.StashColor
            $str += Write-Prompt $s.AfterStash
        }
    }

    return $(if ($StringBuilder) { $StringBuilder } else { $str })
}

if (!(Test-Path Variable:Global:VcsPromptStatuses)) {
    $global:VcsPromptStatuses = @()
}

<#
.SYNOPSIS
    Writes all version control prompt statuses configured in $global:VscPromptStatuses.
.DESCRIPTION
    Writes all version control prompt statuses configured in $global:VscPromptStatuses.
    By default, this includes the PoshGit prompt status.
.EXAMPLE
    PS C:\> Write-VcsStatus

    Writes all version control prompt statuses that have been configured
    with the global variable $VscPromptStatuses
#>
function Global:Write-VcsStatus {
    Set-ConsoleMode -ANSI

    $OFS = ""
    $sb = [System.Text.StringBuilder]::new(256)

    foreach ($promptStatus in $global:VcsPromptStatuses) {
        [void]$sb.Append("$(& $promptStatus)")
    }

    if ($sb.Length -gt 0) {
        $sb.ToString()
    }
}

# Add scriptblock that will execute for Write-VcsStatus
$PoshGitVcsPrompt = {
    try {
        $global:GitStatus = Get-GitStatus
        Write-GitStatus $GitStatus
    }
    catch {
        $s = $global:GitPromptSettings
        if ($s) {
            $errorText = "PoshGitVcsPrompt error: $_"
            $sb = [System.Text.StringBuilder]::new()

            # When prompt is first (default), place the separator before the status summary
            if (!$s.DefaultPromptWriteStatusFirst) {
                $sb | Write-Prompt $s.PathStatusSeparator.Expand() > $null
            }
            $sb | Write-Prompt $s.BeforeStatus > $null

            $sb | Write-Prompt $errorText -Color $s.ErrorColor > $null
            if ($s.Debug) {
                if (!$s.AnsiConsole) { Write-Host }
                Write-Verbose "PoshGitVcsPrompt error details: $($_ | Format-List * -Force | Out-String)" -Verbose
            }
            $sb | Write-Prompt $s.AfterStatus > $null

            if ($sb.Length -gt 0) {
                $sb.ToString()
            }
        }
    }
}

$global:VcsPromptStatuses += $PoshGitVcsPrompt

Write-DebugTiming -Label 'GitPrompt'
#endregion

# ============================================================================
#region GitParamTabExpansion
# ============================================================================
# Variable is used in GitTabExpansion.ps1
$shortGitParams = @{
    add = 'n v f i p e u A N'
    bisect = ''
    blame = 'b L l t S p M C h c f n s e w'
    branch = 'd D l f m M r a v vv q t u'
    checkout = 'q f b B t l m p'
    cherry = 'v'
    'cherry-pick' = 'e x r m n s S X'
    clean = 'd f i n q e x X'
    clone = 'l s q v n o b u c'
    commit = 'a p C c z F m t s n e i o u v q S'
    config = 'f l z e'
    diff = 'p u s U z B M C D l S G O R a b w W'
    difftool = 'd y t x g'
    fetch = 'a f k p n t u q v'
    grep = 'a i I w v h H E G P F n l L O z c p C A B W f e q'
    help = 'a g i m w'
    init = 'q'
    log = 'L n i E F g c c m r t'
    merge = 'e n s X q v S m'
    mergetool = 't y'
    mv = 'f k n v'
    notes = 'f m F C c n s q v'
    prune = 'n v'
    pull = 'q v e n s X r a f k u'
    push = 'n f u q v'
    rebase = 'm s X S q v n C f i p x'
    remote = 'v'
    reset = 'q p'
    restore = 's p W S q m'
    revert = 'e m n S s X'
    rm = 'f n r q'
    shortlog = 'n s e w'
    stash = 'p k u a q'
    status = 's b u z'
    submodule = 'q b f n N'
    switch = 'c C d f m q t'
    tag = 'a s u f d v n l m F'
    whatchanged = 'p'
}

# Variable is used in GitTabExpansion.ps1
$longGitParams = @{
    add = 'dry-run verbose force interactive patch edit update all no-ignore-removal no-all ignore-removal intent-to-add refresh ignore-errors ignore-missing renormalize'
    bisect = 'no-checkout term-old term-new'
    blame = 'root show-stats reverse porcelain line-porcelain incremental encoding= contents date score-debug show-name show-number show-email abbrev'
    branch = 'color no-color list abbrev= no-abbrev column no-column merged no-merged contains set-upstream track no-track set-upstream-to= unset-upstream edit-description delete create-reflog force move all verbose quiet'
    checkout = 'quiet force ours theirs track no-track detach orphan ignore-skip-worktree-bits merge conflict= patch'
    'cherry-pick' = 'edit mainline no-commit signoff gpg-sign ff allow-empty allow-empty-message keep-redundant-commits strategy= strategy-option= continue quit abort'
    clean = 'force interactive dry-run quiet exclude='
    clone = 'local no-hardlinks shared reference quiet verbose progress no-checkout bare mirror origin branch upload-pack template= config depth single-branch no-single-branch recursive recurse-submodules separate-git-dir='
    commit = 'all patch reuse-message reedit-message fixup squash reset-author short branch porcelain long null file author date message template signoff no-verify allow-empty allow-empty-message cleanup= edit no-edit amend no-post-rewrite include only untracked-files verbose quiet dry-run status no-status gpg-sign no-gpg-sign'
    config = 'replace-all add get get-all get-regexp get-urlmatch global system local file blob remove-section rename-section unset unset-all list bool int bool-or-int path null get-colorbool get-color edit includes no-includes'
    describe = 'dirty all tags contains abbrev candidates= exact-match debug long match always first-parent'
    diff = 'cached patch no-patch unified= raw patch-with-raw minimal patience histogram diff-algorithm= stat numstat shortstat dirstat summary patch-with-stat name-only name-status submodule color no-color word-diff word-diff-regex color-words no-renames check full-index binary apprev break-rewrites find-renames find-copies find-copies-harder irreversible-delete diff-filter= pickaxe-all pickaxe-regex relative text ignore-space-at-eol ignore-space-change ignore-all-space ignore-blank-lines inter-hunk-context= function-context exit-code quiet ext-diff no-ext-diff textconv no-textconv ignore-submodules src-prefix dst-prefix no-prefix staged'
    difftool = 'dir-diff no-prompt prompt tool= tool-help no-symlinks symlinks extcmd= gui'
    fetch = 'all append depth= unshallow update-shallow dry-run force keep multiple prune no-tags tags recurse-submodules= no-recurse-submodules submodule-prefix= recurse-submodules-default= update-head-ok upload-pack quiet verbose progress'
    gc = 'aggressive auto prune= no-prune quiet force'
    grep = 'cached no-index untracked no-exclude-standard exclude-standard text textconv no-textconv ignore-case max-depth word-regexp invert-match full-name extended-regexp basic-regexp perl-regexp fixed-strings line-number files-with-matches open-file-in-pager null count color no-color break heading show-function context after-context before-context function-context and or not all-match quiet'
    help = 'all guides info man web'
    init = 'quiet bare template= separate-git-dir= shared='
    log = 'follow no-decorate decorate source use-mailmap full-diff log-size max-count skip since after until before author committer grep-reflog grep all-match regexp-ignore-case basic-regexp extended-regexp fixed-strings perl-regexp remove-empty merges no-merges min-parents max-parents no-min-parents no-max-parents first-parent not all branches tags remote glob= exclude= ignore-missing bisect stdin cherry-mark cherry-pick left-only right-only cherry walk-reflogs merge boundary simplify-by-decoration full-history dense sparse simplify-merges ancestry-path date-order author-date-order topo-order reverse objects objects-edge unpacked no-walk= do-walk pretty format= abbrev-commit no-abbrev-commit oneline encoding= notes no-notes standard-notes no-standard-notes show-signature relative-date date= parents children left-right graph show-linear-break patch stat'
    merge = 'commit no-commit edit no-edit ff no-ff ff-only log no-log stat no-stat squash no-squash strategy strategy-option verify-signatures no-verify-signatures summary no-summary quiet verbose progress no-progress gpg-sign rerere-autoupdate no-rerere-autoupdate abort allow-unrelated-histories'
    mergetool = 'tool= tool-help no-prompt prompt'
    mv = 'force dry-run verbose'
    notes = 'force message file reuse-message reedit-message ref ignore-missing stdin dry-run strategy= commit abort quiet verbose'
    prune = 'dry-run verbose expire'
    pull = 'quiet verbose recurse-submodules= no-recurse-submodules= commit no-commit edit no-edit ff no-ff ff-only log no-log stat no-stat squash no-squash strategy= strategy-option= verify-signatures no-verify-signatures summary no-summary rebase= no-rebase all append depth= unshallow update-shallow force keep no-tags update-head-ok upload-pack progress'
    push = 'all prune mirror dry-run porcelain delete tags follow-tags receive-pack= exec= force-with-lease no-force-with-lease force repo= set-upstream thin no-thin quiet verbose progress recurse-submodules= verify no-verify'
    rebase = 'onto continue abort keep-empty skip edit-todo merge strategy= strategy-option= gpg-sign quiet verbose stat no-stat no-verify verify force-rebase fork-point no-fork-point ignore-whitespace whitespace= committer-date-is-author-date ignore-date interactive preserve-merges exec root autosquash no-autosquash autostash no-autostash no-ff'
    reflog = 'stale-fix expire= expire-unreachable= all updateref rewrite verbose'
    remote = 'verbose'
    reset = 'patch quiet soft mixed hard merge keep'
    restore = 'source= patch worktree staged quiet progress no-progress ours theirs merge conflict= ignore-unmerged ignore-skip-worktree-bits overlay no-overlay'
    revert = 'edit mainline no-edit no-commit gpg-sign signoff strategy= strategy-option continue quit abort'
    rm = 'force dry-run cached ignore-unmatch quiet'
    shortlog = 'numbered summary email format='
    show = 'pretty= format= abbrev-commit no-abbrev-commit oneline encoding= notes no-notes show-notes no-standard-notes standard-notes show-signature'
    stash = 'patch no-keep-index keep-index include-untracked all quiet index'
    status = 'short branch porcelain long untracked-files ignore-submodules ignored column no-column'
    submodule = 'quiet branch force cached files summary-limit remote no-fetch checkout merge rebase init name reference recursive depth'
    switch = 'create force-create detach guess no-guess force discard-changes merge conflict= quiet no-progress track no-track orphan ignore-other-worktrees recurse-submodules no-recurse-submodules'
    tag = 'annotate sign local-user force delete verify list sort column no-column contains points-at message file cleanup'
    whatchanged = 'since'
}

$shortVstsGlobal = 'h o'
$shortVstsParams = @{
    abandon = "i $shortVstsGlobal"
    create = "d i p r s t $shortVstsGlobal"
    complete = "i $shortVstsGlobal"
    list = "i p r s t $shortVstsGlobal"
    reactivate = "i $shortVstsGlobal"
    'set-vote' = "i $shortVstsGlobal"
    show = "i $shortVstsGlobal"
    update = "d i $shortVstsGlobal"
}

$longVstsGlobal = 'debug help output query verbose'
$longVstsParams = @{
    abandon = "id detect instance $longVstsGlobal"
    create = "auto-complete delete-source-branch work-items bypass-policy bypass-policy-reason description detect instance merge-commit-message open project repository reviewers source-branch squash target-branch title $longVstsGlobal"
    complete = "id detect instance $longVstsGlobal"
    list = " $longVstsGlobal"
    reactivate = " $longVstsGlobal"
    'set-vote' = " $longVstsGlobal"
    show = " $longVstsGlobal"
    update = " $longVstsGlobal"
}

# Variable is used in GitTabExpansion.ps1
$gitParamValues = @{
    blame = @{
        encoding = 'utf-8 none'
    }
    branch = @{
        color = 'always never auto'
        abbrev = '7 8 9 10'
    }
    checkout = @{
        conflict = 'merge diff3'
    }
    'cherry-pick' = @{
        strategy = 'resolve recursive octopus ours subtree'
    }
    commit = @{
        'cleanup' = 'strip whitespace verbatim scissors default'
    }
    diff = @{
        unified = '0 1 2 3 4 5'
        'diff-algorithm' = 'default patience minimal histogram myers'
        color = 'always never auto'
        'word-diff' = 'color plain porcelain none'
        abbrev = '7 8 9 10'
        'diff-filter' = 'A C D M R T U X B *'
        'inter-hunk-context' = '0 1 2 3 4 5'
        'ignore-submodules' = 'none untracked dirty all'
    }
    difftool = @{
        tool = 'vimdiff vimdiff2 araxis bc3 codecompare deltawalker diffmerge diffuse ecmerge emerge gvimdiff gvimdiff2 kdiff3 kompare meld opendiff p4merge tkdiff xxdiff'
    }
    fetch = @{
        'recurse-submodules' = 'yes on-demand no'
        'recurse-submodules-default' = 'yes on-demand'
    }
    init = @{
        shared = 'false true umask group all world everybody o'
    }
    log = @{
        decorate = 'short full no'
        'no-walk' = 'sorted unsorted'
        pretty = {
            param($format)
            gitConfigKeys 'pretty' $format 'oneline short medium full fuller email raw'
        }
        format = {
            param($format)
            gitConfigKeys 'pretty' $format 'oneline short medium full fuller email raw'
        }
        encoding = 'UTF-8'
        date = 'relative local default iso rfc short raw'
    }
    merge = @{
        strategy = 'resolve recursive octopus ours subtree'
        log = '1 2 3 4 5 6 7 8 9'
    }
    mergetool = @{
        tool = 'vimdiff vimdiff2 araxis bc3 codecompare deltawalker diffmerge diffuse ecmerge emerge gvimdiff gvimdiff2 kdiff3 kompare meld opendiff p4merge tkdiff xxdiff'
    }
    notes = @{
        strategy = 'manual ours theirs union cat_sort_uniq'
    }
    pull = @{
        strategy = 'resolve recursive octopus ours subtree'
        'recurse-submodules' = 'yes on-demand no'
        'no-recurse-submodules' = 'yes on-demand no'
        rebase = 'false true preserve'
    }
    push = @{
        'recurse-submodules' = 'check on-demand'
    }
    rebase = @{
        strategy = 'resolve recursive octopus ours subtree'
    }
    restore = @{
        conflict = 'merge diff3'
        source = {
            param($ref)
            gitBranches $ref $true
            gitTags $ref
        }
    }
    revert = @{
        strategy = 'resolve recursive octopus ours subtree'
    }
    show = @{
        pretty = {
            param($format)
            gitConfigKeys 'pretty' $format 'oneline short medium full fuller email raw'
        }
        format = {
            param($format)
            gitConfigKeys 'pretty' $format 'oneline short medium full fuller email raw'
        }
        encoding = 'utf-8'
    }
    status = @{
        'untracked-files' = 'no normal all'
        'ignore-submodules' = 'none untracked dirty all'
    }
    switch = @{
        conflict = 'merge diff3'
    }
}

Write-DebugTiming -Label 'GitParamTabExpansion'
#endregion

# ============================================================================
#region GitTabExpansion
# ============================================================================
# Initial implementation by Jeremy Skinner
# http://www.jeremyskinner.co.uk/2010/03/07/using-git-with-windows-powershell/

$Global:GitTabSettings = New-Object PSObject -Property @{
    AllCommands = $false
    KnownAliases = @{
        '!f() { exec vsts code pr "$@"; }; f' = 'vsts.pr'
    }
    EnableLogging = $false
    LogPath = Join-Path ([System.IO.Path]::GetTempPath()) posh-git_tabexp.log
    RegisteredCommands = ""
}

$subcommands = @{
    bisect = "start bad good skip reset visualize replay log run"
    notes = 'add append copy edit get-ref list merge prune remove show'
    'vsts.pr' = 'create update show list complete abandon reactivate reviewers work-items set-vote policies'
    reflog = "show delete expire"
    remote = "
        add rename remove set-head set-branches
        get-url set-url show prune update
        "
    rerere = "clear forget diff remaining status gc"
    stash = 'push save list show apply clear drop pop create branch'
    submodule = "add status init deinit update summary foreach sync"
    svn = "
        init fetch clone rebase dcommit log find-rev
        set-tree commit-diff info create-ignore propget
        proplist show-ignore show-externals branch tag blame
        migrate mkdirs reset gc
        "
    tfs = "
        list-remote-branches clone quick-clone bootstrap init
        clone fetch pull quick-clone unshelve shelve-list labels
        rcheckin checkin checkintool shelve shelve-delete
        branch
        info cleanup cleanup-workspaces help verify autotag subtree reset-remote checkout
        "
    flow = "init feature bugfix release hotfix support help version"
    worktree = "add list lock move prune remove unlock"
}

$gitflowsubcommands = @{
    init = 'help'
    feature = 'list start finish publish track diff rebase checkout pull help delete'
    bugfix = 'list start finish publish track diff rebase checkout pull help delete'
    release = 'list start finish track publish help delete'
    hotfix = 'list start finish track publish help delete'
    support = 'list start help'
    config = 'list set base'
}

function script:gitCmdOperations($commands, $command, $filter) {
    $commands[$command].Trim() -split '\s+' | Where-Object { $_ -like "$filter*" }
}

$script:someCommands = @('add','am','annotate','archive','bisect','blame','branch','bundle','checkout','cherry',
                         'cherry-pick','citool','clean','clone','commit','config','describe','diff','difftool','fetch',
                         'format-patch','gc','grep','gui','help','init','instaweb','log','merge','mergetool','mv',
                         'notes','prune','pull','push','rebase','reflog','remote','rerere','reset','restore','revert','rm',
                         'shortlog','show','stash','status','submodule','svn','switch','tag','whatchanged', 'worktree')

$script:gitCommandsWithLongParams = $longGitParams.Keys -join '|'
$script:gitCommandsWithShortParams = $shortGitParams.Keys -join '|'
$script:gitCommandsWithParamValues = $gitParamValues.Keys -join '|'
$script:vstsCommandsWithShortParams = $shortVstsParams.Keys -join '|'
$script:vstsCommandsWithLongParams = $longVstsParams.Keys -join '|'

filter quoteStringWithSpecialChars {
    if ($_ -and ($_ -match '\s+|#|@|\$|;|,|''|\{|\}|\(|\)')) {
        $str = $_ -replace "'", "''"
        "'$str'"
    }
    else {
        $_
    }
}

function script:gitCommands($filter, $includeAliases) {
    $cmdList = @()
    if (-not $global:GitTabSettings.AllCommands) {
        $cmdList += $someCommands -like "$filter*"
    }
    else {
        $cmdList += git help --all |
            Where-Object { $_ -match '^\s{2,}\S.*' } |
            ForEach-Object { $_.Split(' ', [StringSplitOptions]::RemoveEmptyEntries) } |
            Where-Object { $_ -like "$filter*" }
    }

    if ($includeAliases) {
        $cmdList += gitAliases $filter
    }

    $cmdList | Sort-Object
}

function script:gitRemotes($filter) {
    git remote |
        Where-Object { $_ -like "$filter*" } |
        quoteStringWithSpecialChars
}

function script:gitBranches($filter, $includeHEAD = $false, $prefix = '') {
    if ($filter -match "^(?<from>\S*\.{2,3})(?<to>.*)") {
        $prefix += $matches['from']
        $filter = $matches['to']
    }

    $branches = @(git branch --no-color | ForEach-Object { if (($_ -notmatch "^\* \(HEAD detached .+\)$") -and ($_ -match "^[\*\+]?\s*(?<ref>\S+)(?: -> .+)?")) { $matches['ref'] } }) +
                @(git branch --no-color -r | ForEach-Object { if ($_ -match "^  (?<ref>\S+)(?: -> .+)?") { $matches['ref'] } }) +
                @(if ($includeHEAD) { 'HEAD','FETCH_HEAD','ORIG_HEAD','MERGE_HEAD' })

    $branches |
        Where-Object { $_ -ne '(no branch)' -and $_ -like "$filter*" } |
        ForEach-Object { $prefix + $_ } |
        quoteStringWithSpecialChars
}

function script:gitRemoteUniqueBranches($filter) {
    git branch --no-color -r |
        ForEach-Object { if ($_ -match "^  (?<remote>[^/]+)/(?<branch>\S+)(?! -> .+)?$") { $matches['branch'] } } |
        Group-Object -NoElement |
        Where-Object { $_.Count -eq 1 } |
        Select-Object -ExpandProperty Name |
        Where-Object { $_ -like "$filter*" } |
        quoteStringWithSpecialChars
}

function script:gitConfigKeys($section, $filter, $defaultOptions = '') {
    $completions = @($defaultOptions -split ' ')

    git config --name-only --get-regexp ^$section\..* |
        ForEach-Object { $completions += ($_ -replace "$section\.","") }

    return $completions |
        Where-Object { $_ -like "$filter*" } |
        Sort-Object |
        quoteStringWithSpecialChars
}

function script:gitTags($filter, $prefix = '') {
    git tag |
        Where-Object { $_ -like "$filter*" } |
        ForEach-Object { $prefix + $_ } |
        quoteStringWithSpecialChars
}

function script:gitFeatures($filter, $command) {
    $featurePrefix = git config --local --get "gitflow.prefix.$command"
    $branches = @(git branch --no-color | ForEach-Object { if ($_ -match "^\*?\s*$featurePrefix(?<ref>.*)") { $matches['ref'] } })
    $branches |
        Where-Object { $_ -ne '(no branch)' -and $_ -like "$filter*" } |
        ForEach-Object { $featurePrefix + $_ } |
        quoteStringWithSpecialChars
}

function script:gitRemoteBranches($remote, $ref, $filter, $prefix = '') {
    git branch --no-color -r |
        Where-Object { $_ -like "  $remote/$filter*" } |
        ForEach-Object { $prefix + $ref + ($_ -replace "  $remote/","") } |
        quoteStringWithSpecialChars
}

function script:gitStashes($filter) {
    (git stash list) -replace ':.*','' |
        Where-Object { $_ -like "$filter*" } |
        quoteStringWithSpecialChars
}

function script:gitTfsShelvesets($filter) {
    (git tfs shelve-list) |
        Where-Object { $_ -like "$filter*" } |
        quoteStringWithSpecialChars
}

function script:gitFiles($filter, $files) {
    $files | Sort-Object |
        Where-Object { $_ -like "$filter*" } |
        quoteStringWithSpecialChars
}

function script:gitIndex($GitStatus, $filter) {
    gitFiles $filter $GitStatus.Index
}

function script:gitAddFiles($GitStatus, $filter) {
    gitFiles $filter (@($GitStatus.Working.Unmerged) + @($GitStatus.Working.Modified) + @($GitStatus.Working.Added))
}

function script:gitCheckoutFiles($GitStatus, $filter) {
    gitFiles $filter (@($GitStatus.Working.Unmerged) + @($GitStatus.Working.Modified) + @($GitStatus.Working.Deleted))
}

function script:gitDeleted($GitStatus, $filter) {
    gitFiles $filter $GitStatus.Working.Deleted
}

function script:gitDiffFiles($GitStatus, $filter, $staged) {
    if ($staged) {
        gitFiles $filter $GitStatus.Index.Modified
    }
    else {
        gitFiles $filter (@($GitStatus.Working.Unmerged) + @($GitStatus.Working.Modified) + @($GitStatus.Index.Modified))
    }
}

function script:gitMergeFiles($GitStatus, $filter) {
    gitFiles $filter $GitStatus.Working.Unmerged
}

function script:gitRestoreFiles($GitStatus, $filter, $staged) {
    if ($staged) {
        gitFiles $filter (@($GitStatus.Index.Added) + @($GitStatus.Index.Modified) + @($GitStatus.Index.Deleted))
    }
    else {
        gitFiles $filter (@($GitStatus.Working.Unmerged) + @($GitStatus.Working.Modified) + @($GitStatus.Working.Deleted))
    }
}

function script:gitAliases($filter) {
    git config --get-regexp ^alias\. | ForEach-Object{
        if ($_ -match "^alias\.(?<alias>\S+) .*") {
            $alias = $Matches['alias']
            if ($alias -like "$filter*") {
                $alias
            }
        }
    } | Sort-Object -Unique
}

function script:expandGitAlias($cmd, $rest) {
    $alias = git config "alias.$cmd"

    if ($alias) {
        $known = $Global:GitTabSettings.KnownAliases[$alias]
        if ($known) {
            return "git $known$rest"
        }

        return "git $alias$rest"
    }
    else {
        return "git $cmd$rest"
    }
}

function script:expandLongParams($hash, $cmd, $filter) {
    $hash[$cmd].Trim() -split ' ' |
        Where-Object { $_ -like "$filter*" } |
        Sort-Object |
        ForEach-Object { -join ("--", $_) }
}

function script:expandShortParams($hash, $cmd, $filter) {
    $hash[$cmd].Trim() -split ' ' |
        Where-Object { $_ -like "$filter*" } |
        Sort-Object |
        ForEach-Object { -join ("-", $_) }
}

function script:expandParamValues($cmd, $param, $filter) {
    $paramValues = $gitParamValues[$cmd][$param]

    $completions = if ($paramValues -is [scriptblock]) {
        & $paramValues $filter
    }
    else {
        $paramValues.Trim() -split ' ' | Where-Object { $_ -like "$filter*" } | Sort-Object
    }

    $completions | ForEach-Object { -join ("--", $param, "=", $_) }
}

function Expand-GitCommand($Command) {
    # Parse all Git output as UTF8, including tab completion output - https://github.com/dahlbyk/posh-git/pull/359
    $res = Invoke-Utf8ConsoleCommand { GitTabExpansionInternal $Command $Global:GitStatus }
    $res
}

function GitTabExpansionInternal($lastBlock, $GitStatus = $null) {
    $ignoreGitParams = '(?<params>\s+-(?:[aA-zZ0-9]+|-[aA-zZ0-9][aA-zZ0-9-]*)(?:=\S+)?)*'

    if ($lastBlock -match "^$(Get-AliasPattern git) (?<cmd>\S+)(?<args> .*)$") {
        $lastBlock = expandGitAlias $Matches['cmd'] $Matches['args']
    }

    # Handles tgit <command> (tortoisegit)
    if ($lastBlock -match "^$(Get-AliasPattern tgit) (?<cmd>\S*)$") {
        # Need return statement to prevent fall-through.
        return $Global:TortoiseGitSettings.TortoiseGitCommands.Keys.GetEnumerator() | Sort-Object | Where-Object { $_ -like "$($matches['cmd'])*" }
    }

    # Handles gitk
    if ($lastBlock -match "^$(Get-AliasPattern gitk).* (?<ref>\S*)$") {
        return gitBranches $matches['ref'] $true
    }

    switch -regex ($lastBlock -replace "^$(Get-AliasPattern git) ","") {

        # Handles git <cmd> <op>
        "^(?<cmd>$($subcommands.Keys -join '|'))\s+(?<op>\S*)$" {
            gitCmdOperations $subcommands $matches['cmd'] $matches['op']
        }

        # Handles git flow <cmd> <op>
        "^flow (?<cmd>$($gitflowsubcommands.Keys -join '|'))\s+(?<op>\S*)$" {
            gitCmdOperations $gitflowsubcommands $matches['cmd'] $matches['op']
        }

        # Handles git flow <command> <op> <name>
        "^flow (?<command>\S*)\s+(?<op>\S*)\s+(?<name>\S*)$" {
            gitFeatures $matches['name'] $matches['command']
        }

        # Handles git remote (rename|rm|set-head|set-branches|set-url|show|prune) <stash>
        "^remote.* (?:rename|rm|set-head|set-branches|set-url|show|prune).* (?<remote>\S*)$" {
            gitRemotes $matches['remote']
        }

        # Handles git stash (show|apply|drop|pop|branch) <stash>
        "^stash (?:show|apply|drop|pop|branch).* (?<stash>\S*)$" {
            gitStashes $matches['stash']
        }

        # Handles git bisect (bad|good|reset|skip) <ref>
        "^bisect (?:bad|good|reset|skip).* (?<ref>\S*)$" {
            gitBranches $matches['ref'] $true
        }

        # Handles git tfs unshelve <shelveset>
        "^tfs +unshelve.* (?<shelveset>\S*)$" {
            gitTfsShelvesets $matches['shelveset']
        }

        # Handles git branch -d|-D|-m|-M <branch name>
        # Handles git branch <branch name> <start-point>
        "^branch.* (?<branch>\S*)$" {
            gitBranches $matches['branch']
        }

        # Handles git <cmd> (commands & aliases)
        "^(?<cmd>\S*)$" {
            gitCommands $matches['cmd'] $TRUE
        }

        # Handles git help <cmd> (commands only)
        "^help (?<cmd>\S*)$" {
            gitCommands $matches['cmd'] $FALSE
        }

        # Handles git push remote <ref>:<branch>
        # Handles git push remote +<ref>:<branch>
        "^push${ignoreGitParams}\s+(?<remote>[^\s-]\S*).*\s+(?<force>\+?)(?<ref>[^\s\:]*\:)(?<branch>\S*)$" {
            gitRemoteBranches $matches['remote'] $matches['ref'] $matches['branch'] -prefix $matches['force']
        }

        # Handles git push remote <ref>
        # Handles git push remote +<ref>
        # Handles git pull remote <ref>
        "^(?:push|pull)${ignoreGitParams}\s+(?<remote>[^\s-]\S*).*\s+(?<force>\+?)(?<ref>[^\s\:]*)$" {
            gitBranches $matches['ref'] -prefix $matches['force']
            gitTags $matches['ref'] -prefix $matches['force']
        }

        # Handles git pull <remote>
        # Handles git push <remote>
        # Handles git fetch <remote>
        "^(?:push|pull|fetch)${ignoreGitParams}\s+(?<remote>\S*)$" {
            gitRemotes $matches['remote']
        }

        # Handles git reset HEAD <path>
        # Handles git reset HEAD -- <path>
        "^reset.* HEAD(?:\s+--)? (?<path>\S*)$" {
            gitIndex $GitStatus $matches['path']
        }

        # Handles git <cmd> <ref>
        "^commit.*-C\s+(?<ref>\S*)$" {
            gitBranches $matches['ref'] $true
        }

        # Handles git add <path>
        "^add.* (?<files>\S*)$" {
            gitAddFiles $GitStatus $matches['files']
        }

        # Handles git checkout -- <path>
        "^checkout.* -- (?<files>\S*)$" {
            gitCheckoutFiles $GitStatus $matches['files']
        }

        # Handles git restore -s <ref> / --source=<ref> - must come before the next regex case
        "^restore.* (?-i)(-s\s*|(?<source>--source=))(?<ref>\S*)$" {
            gitBranches $matches['ref'] $true $matches['source']
            gitTags $matches['ref']
            break
        }

        # Handles git restore <path>
        "^restore(?:.* (?<staged>(?:(?-i)-S|--staged))|.*) (?<files>\S*)$" {
            gitRestoreFiles $GitStatus $matches['files'] $matches['staged']
        }

        # Handles git rm <path>
        "^rm.* (?<index>\S*)$" {
            gitDeleted $GitStatus $matches['index']
        }

        # Handles git diff/difftool <path>
        "^(?:diff|difftool)(?:.* (?<staged>(?:--cached|--staged))|.*) (?<files>\S*)$" {
            gitDiffFiles $GitStatus $matches['files'] $matches['staged']
        }

        # Handles git merge/mergetool <path>
        "^(?:merge|mergetool).* (?<files>\S*)$" {
            gitMergeFiles $GitStatus $matches['files']
        }

        # Handles git checkout|switch <ref>
        "^(?:checkout|switch).* (?<ref>\S*)$" {
            & {
                gitBranches $matches['ref'] $true
                gitRemoteUniqueBranches $matches['ref']
                gitTags $matches['ref']
                # Return only unique branches (to eliminate duplicates where the branch exists locally and on the remote)
            } | Select-Object -Unique
        }

        # Handles git worktree add <path> <ref>
        "^worktree add.* (?<files>\S+) (?<ref>\S*)$" {
            gitBranches $matches['ref']
        }

        # Handles git <cmd> <ref>
        "^(?:cherry|cherry-pick|diff|difftool|log|merge|rebase|reflog\s+show|reset|revert|show).* (?<ref>\S*)$" {
            gitBranches $matches['ref'] $true
            gitTags $matches['ref']
        }

        # Handles git <cmd> --<param>=<value>
        "^(?<cmd>$gitCommandsWithParamValues).* --(?<param>[^=]+)=(?<value>\S*)$" {
            expandParamValues $matches['cmd'] $matches['param'] $matches['value']
        }

        # Handles git <cmd> --<param>
        "^(?<cmd>$gitCommandsWithLongParams).* --(?<param>\S*)$" {
            expandLongParams $longGitParams $matches['cmd'] $matches['param']
        }

        # Handles git <cmd> -<shortparam>
        "^(?<cmd>$gitCommandsWithShortParams).* -(?<shortparam>\S*)$" {
            expandShortParams $shortGitParams $matches['cmd'] $matches['shortparam']
        }

        # Handles git pr alias
        "vsts\.pr\s+(?<op>\S*)$" {
            gitCmdOperations $subcommands 'vsts.pr' $matches['op']
        }

        # Handles git pr <cmd> --<param>
        "vsts\.pr\s+(?<cmd>$vstsCommandsWithLongParams).*--(?<param>\S*)$"
        {
            expandLongParams $longVstsParams $matches['cmd'] $matches['param']
        }

        # Handles git pr <cmd> -<shortparam>
        "vsts\.pr\s+(?<cmd>$vstsCommandsWithShortParams).*-(?<shortparam>\S*)$"
        {
            expandShortParams $shortVstsParams $matches['cmd'] $matches['shortparam']
        }
    }
}

function WriteTabExpLog([string] $Message) {
    if (!$global:GitTabSettings.EnableLogging) { return }

    $timestamp = Get-Date -Format HH:mm:ss
    "[$timestamp] $Message" | Out-File -Append $global:GitTabSettings.LogPath
}

if (!$UseLegacyTabExpansion -and ($PSVersionTable.PSVersion.Major -ge 6)) {
    $cmdNames = "git","tgit","gitk"

    # Create regex pattern from $cmdNames: ^(git|git\.exe|tgit|tgit\.exe|gitk|gitk\.exe)$
    $cmdNamesPattern = "^($($cmdNames -join '|'))(\.exe)?$"
    $cmdNames += Get-Alias | Where-Object { $_.Definition -match $cmdNamesPattern } | Foreach-Object Name

    $global:GitTabSettings.RegisteredCommands = $cmdNames -join ", "

    Microsoft.PowerShell.Core\Register-ArgumentCompleter -CommandName $cmdNames -Native -ScriptBlock {
        param($wordToComplete, $commandAst, $cursorPosition)

        # The PowerShell completion has a habit of stripping the trailing space when completing:
        # git checkout <tab>
        # The Expand-GitCommand expects this trailing space, so pad with a space if necessary.
        $padLength = $cursorPosition - $commandAst.Extent.StartOffset
        $textToComplete = $commandAst.ToString().PadRight($padLength, ' ').Substring(0, $padLength)

        WriteTabExpLog "Expand: command: '$($commandAst.Extent.Text)', padded: '$textToComplete', padlen: $padLength"
        Expand-GitCommand $textToComplete
    }
}
else {
    $PowerTab_RegisterTabExpansion = if (Get-Module -Name powertab) { Get-Command Register-TabExpansion -Module powertab -ErrorAction SilentlyContinue }
    if ($PowerTab_RegisterTabExpansion) {
        & $PowerTab_RegisterTabExpansion git -Type Command {
            param($Context, [ref]$TabExpansionHasOutput, [ref]$QuoteSpaces)

            $line = $Context.Line
            $lastBlock = [regex]::Split($line, '[|;]')[-1].TrimStart()
            $TabExpansionHasOutput.Value = $true
            WriteTabExpLog "PowerTab expand: '$lastBlock'"
            Expand-GitCommand $lastBlock
        }

        return
    }

    function TabExpansion($line, $lastWord) {
        $lastBlock = [regex]::Split($line, '[|;]')[-1].TrimStart()
        $msg = "Legacy expand: '$lastBlock'"

        switch -regex ($lastBlock) {
            # Execute git tab completion for all git-related commands
            "^$(Get-AliasPattern git) (.*)"  { WriteTabExpLog $msg; Expand-GitCommand $lastBlock }
            "^$(Get-AliasPattern tgit) (.*)" { WriteTabExpLog $msg; Expand-GitCommand $lastBlock }
            "^$(Get-AliasPattern gitk) (.*)" { WriteTabExpLog $msg; Expand-GitCommand $lastBlock }
        }
    }
}

# Handles Remove-GitBranch -Name parameter auto-completion using the built-in mechanism for cmdlet parameters
Microsoft.PowerShell.Core\Register-ArgumentCompleter -CommandName Remove-GitBranch -ParameterName Name -ScriptBlock {
    param($Command, $Parameter, $WordToComplete, $CommandAst, $FakeBoundParams)

    gitBranches $WordToComplete $true
}

Write-DebugTiming -Label 'GitTabExpansion'
#endregion

# Needed by some of the helper functions above
$IsAdmin = Test-Administrator

$exportModuleMemberParams = @{
    Function = @(
        'Add-PoshGitToProfile',
        'Expand-GitCommand',
        'Format-GitBranchName',
        'Get-GitBranchStatusColor',
        'Get-GitDirectory',
        'Get-GitStatus',
        'Get-PromptConnectionInfo',
        'Get-PromptPath',
        'New-GitPromptSettings',
        'Remove-GitBranch',
        'Remove-PoshGitFromProfile',
        'Update-AllBranches',
        'Write-GitStatus',
        'Write-GitBranchName',
        'Write-GitBranchStatus',
        'Write-GitIndexStatus',
        'Write-GitStashCount',
        'Write-GitWorkingDirStatus',
        'Write-GitWorkingDirStatusSummary',
        'Write-Prompt',
        'Write-VcsStatus',
        'TabExpansion',
        'tgit'
    )
}

Export-ModuleMember @exportModuleMemberParams
Write-DebugTiming -Label 'Finalization'
