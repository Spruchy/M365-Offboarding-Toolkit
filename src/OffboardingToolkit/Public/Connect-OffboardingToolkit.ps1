function Connect-OffboardingToolkit {
    <#
    .SYNOPSIS
    Connects the toolkit to a demo tenant or a real Microsoft 365 tenant.

    .DESCRIPTION
    -Demo loads a fictional in-memory tenant. Nothing leaves your machine and no modules are needed.

    App-only (recommended for real use) signs in as an Entra ID app registration with a
    certificate, so no person's account or MFA prompt is involved and every change is
    tied to that app in the audit logs. See docs/SETUP.md for the permissions to grant.

    -Interactive signs in as you with delegated permissions, for testing in a lab tenant.

    .EXAMPLE
    Connect-OffboardingToolkit -Demo

    .EXAMPLE
    Connect-OffboardingToolkit -TenantId 'contoso.onmicrosoft.com' -ClientId $appId -CertificateThumbprint $thumb -Organization 'contoso.onmicrosoft.com'

    .EXAMPLE
    Connect-OffboardingToolkit -Interactive -TenantId 'contoso.onmicrosoft.com'
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Demo', Justification = 'Selects the Demo parameter set.')]
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Interactive', Justification = 'Selects the Interactive parameter set.')]
    [CmdletBinding(DefaultParameterSetName = 'Demo')]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Demo')]
        [switch] $Demo,

        [Parameter(Mandatory, ParameterSetName = 'AppOnly')]
        [Parameter(ParameterSetName = 'Interactive')]
        [string] $TenantId,

        [Parameter(Mandatory, ParameterSetName = 'AppOnly')]
        [string] $ClientId,

        [Parameter(Mandatory, ParameterSetName = 'AppOnly')]
        [string] $CertificateThumbprint,

        # The tenant's .onmicrosoft.com domain. Exchange Online app-only sign-in needs it.
        [Parameter(ParameterSetName = 'AppOnly')]
        [string] $Organization,

        [Parameter(Mandatory, ParameterSetName = 'Interactive')]
        [switch] $Interactive,

        [Parameter(ParameterSetName = 'AppOnly')]
        [Parameter(ParameterSetName = 'Interactive')]
        [switch] $SkipExchange
    )

    if ($PSCmdlet.ParameterSetName -eq 'Demo') {
        $script:Provider = New-DemoProvider
        Write-Verbose "Connected to $($script:Provider.Name)."
        return [pscustomobject]@{ Tenant = $script:Provider.Name; Kind = 'Demo'; Exchange = $true }
    }

    if (-not (Get-Module -ListAvailable -Name Microsoft.Graph.Authentication)) {
        throw 'Microsoft.Graph.Authentication is not installed. Run: Install-Module Microsoft.Graph.Authentication -Scope CurrentUser'
    }
    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop

    if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
        Connect-MgGraph -TenantId $TenantId -ClientId $ClientId -CertificateThumbprint $CertificateThumbprint -NoWelcome -ErrorAction Stop
    }
    else {
        $scopes = @(
            'User.ReadWrite.All'
            'User.RevokeSessions.All'
            'Directory.Read.All'
            'GroupMember.ReadWrite.All'
            'LicenseAssignment.ReadWrite.All'
            'MailboxSettings.ReadWrite'
            'Files.ReadWrite.All'
            'DeviceManagementManagedDevices.Read.All'
            'DeviceManagementManagedDevices.PrivilegedOperations.All'
        )
        $connect = @{ Scopes = $scopes; NoWelcome = $true; ErrorAction = 'Stop' }
        if ($TenantId) { $connect.TenantId = $TenantId }
        Connect-MgGraph @connect
    }

    $mg = Get-MgContext
    $operator = if ($mg.Account) { $mg.Account } elseif ($mg.AppName) { "$($mg.AppName) (app)" } else { $ClientId }
    $tenantName = if ($TenantId) { $TenantId } else { $mg.TenantId }

    $exchange = $false
    if (-not $SkipExchange) {
        if (-not (Get-Module -ListAvailable -Name ExchangeOnlineManagement)) {
            Write-Warning 'ExchangeOnlineManagement is not installed, so mailbox steps will be skipped and Exchange licenses kept. Install it with: Install-Module ExchangeOnlineManagement -Scope CurrentUser'
        }
        else {
            Import-Module ExchangeOnlineManagement -ErrorAction Stop
            if ($PSCmdlet.ParameterSetName -eq 'AppOnly') {
                if (-not $Organization) { throw 'App-only Exchange sign-in needs -Organization (for example contoso.onmicrosoft.com), or use -SkipExchange.' }
                Connect-ExchangeOnline -AppId $ClientId -CertificateThumbprint $CertificateThumbprint -Organization $Organization -ShowBanner:$false -ErrorAction Stop
            }
            else {
                Connect-ExchangeOnline -ShowBanner:$false -ErrorAction Stop
            }
            $exchange = $true
        }
    }

    $script:Provider = New-GraphProvider -Name $tenantName -Operator $operator -ExchangeConnected $exchange
    [pscustomobject]@{ Tenant = $tenantName; Kind = 'Graph'; Exchange = $exchange; Operator = $operator }
}

function Disconnect-OffboardingToolkit {
    <#
    .SYNOPSIS
    Ends the Graph and Exchange sessions opened by Connect-OffboardingToolkit.
    #>
    [CmdletBinding()]
    param()

    if ($script:Provider) {
        $script:Provider.Disconnect()
        $script:Provider = $null
    }
}
