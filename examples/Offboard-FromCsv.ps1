<#
.SYNOPSIS
Bulk offboarding from a CSV with UserPrincipalName and Ticket columns.
Run with -WhatIf first and review the reports before running for real.

.EXAMPLE
./examples/Offboard-FromCsv.ps1 -CsvPath ./examples/leavers.csv -Demo -WhatIf
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
param(
    [Parameter(Mandatory)][string] $CsvPath,
    [string] $ConfigPath = (Join-Path (Split-Path $PSScriptRoot -Parent) 'config/offboarding.config.json'),
    [switch] $Demo
)

$root = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $root 'src/OffboardingToolkit/OffboardingToolkit.psd1') -Force
if ($Demo) { Connect-OffboardingToolkit -Demo | Out-Null }

$rows = @(Import-Csv -LiteralPath $CsvPath)

# One confirmation for the whole batch instead of one per user. Skipped for -WhatIf.
if (-not $WhatIfPreference -and -not $PSCmdlet.ShouldProcess("$($rows.Count) users from $CsvPath", 'Offboard')) { return }

$results = $rows | Invoke-UserOffboarding -ConfigPath $ConfigPath -Quiet -PassThru -WhatIf:$WhatIfPreference -Confirm:$false

$results | Select-Object UserPrincipalName, Ticket, Mode, Outcome | Format-Table -AutoSize
