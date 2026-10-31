function Get-ObjectProperty {
    <#
    .SYNOPSIS
    Reads a property from a hashtable or object without tripping Set-StrictMode
    when Microsoft Graph leaves a property out of a response.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowNull()] $InputObject,
        [Parameter(Mandatory)][string] $Name,
        $Default = $null
    )

    if ($null -eq $InputObject) { return $Default }

    if ($InputObject -is [System.Collections.IDictionary]) {
        if ($InputObject.Contains($Name)) { return $InputObject[$Name] }
        return $Default
    }

    $prop = $InputObject.PSObject.Properties[$Name]
    if ($null -ne $prop) { return $prop.Value }
    return $Default
}

function ConvertTo-UriSegment {
    # Escapes a value (for example a UPN containing an apostrophe or #) for use in a Graph URL path.
    param([Parameter(Mandatory)][string] $Value)
    [uri]::EscapeDataString($Value)
}

function New-RandomPassword {
    <#
    .SYNOPSIS
    Builds a random password as a SecureString. The plain-text value is never
    returned, logged or written to the report.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; changes nothing outside the session.')]
    [CmdletBinding()]
    [OutputType([securestring])]
    param([ValidateRange(16, 256)][int] $Length = 24)

    $upper = 'ABCDEFGHJKLMNPQRSTUVWXYZ'
    $lower = 'abcdefghijkmnopqrstuvwxyz'
    $digit = '23456789'
    $symbol = '!@#$%^&*-_=+?'
    $all = $upper + $lower + $digit + $symbol

    # One character from each set guarantees Entra ID complexity rules are met.
    $chars = [System.Collections.Generic.List[char]]::new()
    foreach ($set in $upper, $lower, $digit, $symbol) {
        $chars.Add($set[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($set.Length)])
    }
    while ($chars.Count -lt $Length) {
        $chars.Add($all[[System.Security.Cryptography.RandomNumberGenerator]::GetInt32($all.Length)])
    }

    # Fisher-Yates shuffle so the guaranteed characters are not always first.
    for ($i = $chars.Count - 1; $i -gt 0; $i--) {
        $j = [System.Security.Cryptography.RandomNumberGenerator]::GetInt32($i + 1)
        $tmp = $chars[$i]; $chars[$i] = $chars[$j]; $chars[$j] = $tmp
    }

    $secure = [securestring]::new()
    foreach ($c in $chars) { $secure.AppendChar($c) }
    $chars.Clear()
    $secure.MakeReadOnly()
    $secure
}

function Resolve-MessageTemplate {
    <#
    .SYNOPSIS
    Fills {Token} placeholders in an auto-reply template. Values are HTML-encoded
    because Exchange treats auto-reply text as HTML.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Template,
        [Parameter(Mandatory)][hashtable] $Values
    )

    $text = $Template
    foreach ($key in $Values.Keys) {
        $safe = [System.Net.WebUtility]::HtmlEncode([string]$Values[$key])
        $text = $text.Replace('{' + $key + '}', $safe)
    }
    $text
}

function Test-ProtectedAccount {
    <#
    .SYNOPSIS
    True when a UPN matches any wildcard pattern in the ProtectedAccounts list
    (for example break-glass accounts that must never be disabled).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $UserPrincipalName,
        [AllowNull()][AllowEmptyCollection()][string[]] $Patterns
    )

    foreach ($pattern in @($Patterns)) {
        if ([string]::IsNullOrWhiteSpace($pattern)) { continue }
        if ($UserPrincipalName -like $pattern) { return $true }
    }
    $false
}

function Assert-OffboardingConnection {
    if ($null -eq $script:Provider) {
        throw 'Not connected. Run Connect-OffboardingToolkit -Demo to try the toolkit, or Connect-OffboardingToolkit -TenantId ... for a real tenant.'
    }
}
