@{
    RootModule           = 'OffboardingToolkit.psm1'
    ModuleVersion        = '1.0.0'
    GUID                 = '6f0f7a52-3c1e-4d7b-9a41-2b8e5d0c9f13'
    Author               = 'Alex Spruch'
    Copyright            = '(c) Alex Spruch. MIT License.'
    Description          = 'Safe, auditable Microsoft 365 user offboarding through Microsoft Graph and Exchange Online. Includes a dry-run mode, a protected-account guard, before/after snapshots and JSON + HTML audit reports. Ships with a demo tenant so it can be tried without any Microsoft 365 access.'
    PowerShellVersion    = '7.2'
    CompatiblePSEditions = @('Core')

    # Microsoft.Graph.Authentication and ExchangeOnlineManagement are only needed for live
    # tenants, so they are loaded on demand by Connect-OffboardingToolkit instead of being
    # listed in RequiredModules. Demo mode has no dependencies.

    FunctionsToExport    = @(
        'Connect-OffboardingToolkit'
        'Disconnect-OffboardingToolkit'
        'Get-OffboardingPlan'
        'Invoke-UserOffboarding'
        'Export-OffboardingReport'
        'New-OffboardingConfig'
    )
    CmdletsToExport      = @()
    VariablesToExport    = @()
    AliasesToExport      = @()

    PrivateData          = @{
        PSData = @{
            Tags       = @('Microsoft365', 'EntraID', 'MicrosoftGraph', 'Intune', 'ExchangeOnline', 'Offboarding', 'Automation')
            LicenseUri = 'https://opensource.org/licenses/MIT'
        }
    }
}
