
Set-StrictMode -Version 'Latest'

$modulesToImport = @(
    # 'Pester' # This module takes ~2 seconds to load.
    'posh-git'
)

foreach ($module in $modulesToImport)
{
    Write-Timing -Status 'BEGIN' -Message ('Import module "{0}"' -f $module)
    Import-Module -Name $module -Global
    Write-Timing -Status 'COMPLETE' -Message ('Import module "{0}"' -f $module)
}

# Prevent posh-git from rewriting the windows/tab title
$GitPromptSettings.EnableWindowTitle = $false
