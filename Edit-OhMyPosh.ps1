
$ompModules = Get-Module -ListAvailable -Name "oh-my-posh" |
    Where-Object { $_.Version.Major -eq 2 }

    $ompModules
if (-not $ompModules)
{
    return
}

foreach ($omp in $ompModules)
{
    $psm1Path = Join-Path $omp.ModuleBase "$($omp.Name).psm1" -Resolve
    $content = Get-Content $psm1Path -Raw
    $targetLine = [regex]::Escape('#requires -Version 2 -Modules posh-git')

    if ($content -notmatch $targetLine) {
        Write-Warning "Attempted to patch out oh-my-posh's requirement for posh-git but we couldn't find a match for ""${targetLine}"" line in ""${psm1Path}""."
        return
    }

    Write-Warning "Monkey patching oh-my-posh ${psm1Path} to remove posh-git dependency."

    $newContent = $content -replace $targetLine, ''
    [IO.File]::WriteAllText($psm1Path, $newContent)
}
