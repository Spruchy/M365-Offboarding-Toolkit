Set-StrictMode -Version Latest

# Module-wide state. The provider is the only thing that talks to a tenant (real or demo),
# which keeps every offboarding step testable without Microsoft 365.
$script:Provider = $null
$script:ModuleRoot = $PSScriptRoot

foreach ($folder in 'Private', 'Public') {
    $path = Join-Path -Path $PSScriptRoot -ChildPath $folder
    foreach ($file in Get-ChildItem -Path $path -Filter '*.ps1' -File | Sort-Object Name) {
        . $file.FullName
    }
}
