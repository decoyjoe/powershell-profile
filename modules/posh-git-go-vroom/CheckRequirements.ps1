$global:GitMissing = $false
$script:GitCygwin = $false

if (!(Get-Command git -TotalCount 1 -ErrorAction SilentlyContinue)) {
    Write-Warning "git command could not be found. Please create an alias or add it to your PATH."
    $global:GitMissing = $true
    return
}
