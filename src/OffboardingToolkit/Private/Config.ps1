$script:StepNames = @(
    'DisableSignIn'
    'RevokeSessions'
    'ResetPassword'
    'SetAutoReply'
    'ConvertMailboxToShared'
    'HideFromAddressList'
    'GrantOneDriveAccess'
    'RemoveGroupMemberships'
    'RemoveLicenses'
    'DeviceAction'
)

function Get-DefaultOffboardingConfig {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    $steps = [ordered]@{}
    foreach ($name in $script:StepNames) { $steps[$name] = $true }

    [ordered]@{
        CompanyName           = 'the company'

        # Wildcards allowed. Matching accounts are refused before anything changes.
        ProtectedAccounts     = @('breakglass*@*', 'emergency*@*')

        # Stop if the user holds an Entra ID admin role, unless -AllowPrivileged is used.
        BlockPrivilegedUsers  = $true

        # None = report devices only. Retire = remove company data and management.
        # Wipe = factory reset company-owned devices (personal devices are only ever retired).
        DeviceAction          = 'None'

        AutoReply             = [ordered]@{
            Internal = '{DisplayName} is no longer with {CompanyName}. For anything they were working on, please contact {ManagerName} at {ManagerEmail}.'
            External = 'Thank you for your message. {DisplayName} is no longer with {CompanyName}. Please contact {ManagerName} at {ManagerEmail}, who will be glad to help.'
        }

        ReportPath            = './reports'
        Steps                 = $steps
    }
}

function Read-OffboardingConfig {
    <#
    .SYNOPSIS
    Loads the defaults, then overlays any values from a JSON config file.
    Unknown keys are rejected so a typo cannot silently turn a safety setting off.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([string] $Path)

    $config = Get-DefaultOffboardingConfig
    if ([string]::IsNullOrWhiteSpace($Path)) { return $config }

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Config file not found: $Path"
    }

    try {
        $fromFile = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json -AsHashtable
    }
    catch {
        throw "Config file '$Path' is not valid JSON: $($_.Exception.Message)"
    }

    foreach ($key in $fromFile.Keys) {
        if ($key -like '_*') { continue }   # keys starting with _ are comments
        if (-not $config.Contains($key)) {
            throw "Unknown config setting '$key' in $Path. Valid settings: $($config.Keys -join ', ')."
        }

        if ($key -in 'Steps', 'AutoReply') {
            foreach ($inner in $fromFile[$key].Keys) {
                if (-not $config[$key].Contains($inner)) {
                    throw "Unknown $key setting '$inner' in $Path. Valid values: $($config[$key].Keys -join ', ')."
                }
                $config[$key][$inner] = $fromFile[$key][$inner]
            }
        }
        else {
            $config[$key] = $fromFile[$key]
        }
    }

    $validDeviceActions = 'None', 'Retire', 'Wipe'
    if ($config.DeviceAction -notin $validDeviceActions) {
        throw "DeviceAction must be one of: $($validDeviceActions -join ', '). Found '$($config.DeviceAction)'."
    }

    $config.ProtectedAccounts = @($config.ProtectedAccounts)
    $config
}
