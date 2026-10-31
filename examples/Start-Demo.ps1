<#
.SYNOPSIS
Runs the toolkit against the built-in fictional tenant. No Microsoft 365 access needed.
Shows a dry run, a live run, a safe re-run and the safety rails, then opens the HTML report.
#>
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive demo script that narrates each section in color.')]
[CmdletBinding()]
param([switch] $NoOpen)

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/OffboardingToolkit/OffboardingToolkit.psd1') -Force
$config = Join-Path $root 'config/offboarding.config.json'
$reports = Join-Path $root 'reports'

Connect-OffboardingToolkit -Demo | Out-Null
$user = 'jordan.reyes@larkspurlabs.example'

Write-Host "`n=== 1. Dry run: what WOULD happen (nothing changes) ===" -ForegroundColor Magenta
Invoke-UserOffboarding -UserPrincipalName $user -Ticket 'CHG-1042' -ConfigPath $config -ReportPath $reports -WhatIf

Write-Host "`n=== 2. Live run (against the demo tenant) ===" -ForegroundColor Magenta
$live = Invoke-UserOffboarding -UserPrincipalName $user -Ticket 'CHG-1042' -ConfigPath $config -ReportPath $reports -Confirm:$false -PassThru

Write-Host "`n=== 3. Run it again: safe to repeat, finds nothing left to do ===" -ForegroundColor Magenta
Invoke-UserOffboarding -UserPrincipalName $user -ConfigPath $config -NoReport -Confirm:$false

Write-Host "`n=== 4. Safety rails ===" -ForegroundColor Magenta
foreach ($u in 'breakglass01@larkspurlabs.example', 'sam.okafor@larkspurlabs.example', 'morgan.blake@larkspurlabs.example') {
    $r = Invoke-UserOffboarding -UserPrincipalName $u -ConfigPath $config -NoReport -Quiet -PassThru -Confirm:$false
    $why = ($r.Steps | Where-Object Status -eq 'Blocked').Message
    Write-Host ("  {0,-36} {1}" -f $u, $r.Outcome) -ForegroundColor Red
    Write-Host "    $why" -ForegroundColor DarkGray
}

$html = $live.ReportFiles | Where-Object { $_ -like '*.html' }
Write-Host "`nHTML report: $html`n" -ForegroundColor Green
if (-not $NoOpen -and $html) { Invoke-Item $html }
