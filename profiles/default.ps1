
Set-StrictMode -Version 'Latest'

$modulesToImport = @(
    # 'Pester' # This module takes ~2 seconds to load.
    Join-Path -Path $PSScriptRoot -ChildPath '..\modules\posh-git-go-vroom'
)

foreach ($module in $modulesToImport)
{
    Write-Timing -Status 'BEGIN' -Message ('Import module "{0}"' -f $module)
    Import-Module -Name $module -Global
    Write-Timing -Status 'COMPLETE' -Message ('Import module "{0}"' -f $module)
}
