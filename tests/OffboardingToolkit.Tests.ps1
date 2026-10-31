#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $modulePath = Join-Path $PSScriptRoot '../src/OffboardingToolkit/OffboardingToolkit.psd1'
    Import-Module $modulePath -Force

    # Runs a scriptblock inside the module so tests can reach private functions and state.
    function InModule([scriptblock] $Script, [object[]] $ArgumentList = @()) {
        & (Get-Module OffboardingToolkit) $Script @ArgumentList
    }

    function Get-DemoChanges { InModule { $script:Provider.Changes.ToArray() } }

    function Invoke-Live([string] $Upn, [string] $ConfigPath, [switch] $AllowPrivileged) {
        $params = @{ UserPrincipalName = $Upn; Confirm = $false; NoReport = $true; Quiet = $true; PassThru = $true; AllowPrivileged = $AllowPrivileged }
        if ($ConfigPath) { $params.ConfigPath = $ConfigPath }
        Invoke-UserOffboarding @params
    }

    function New-TestConfig([hashtable] $Settings) {
        $path = Join-Path $TestDrive ("config-{0}.json" -f [guid]::NewGuid().ToString('N'))
        $Settings | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $path
        $path
    }

    function Get-Step($Result, [string] $Name) { $Result.Steps | Where-Object Name -eq $Name }

    $jordan = 'jordan.reyes@larkspurlabs.example'
}

AfterAll {
    Remove-Module OffboardingToolkit -ErrorAction SilentlyContinue
}

Describe 'Dry run (-WhatIf)' {
    BeforeEach { Connect-OffboardingToolkit -Demo | Out-Null }

    It 'plans every change but makes none' {
        $r = Invoke-UserOffboarding -UserPrincipalName $jordan -WhatIf -NoReport -Quiet -PassThru
        $r.Mode | Should -Be 'DryRun'
        $r.Outcome | Should -Be 'DryRun'
        (Get-Step $r 'DisableSignIn').Status | Should -Be 'Planned'
        (Get-Step $r 'RemoveLicenses').Status | Should -Be 'Planned'
        Get-DemoChanges | Should -BeNullOrEmpty
    }

    It 'still writes the report files' {
        $r = Invoke-UserOffboarding -UserPrincipalName $jordan -WhatIf -ReportPath $TestDrive -Quiet -PassThru
        $r.ReportFiles | Should -HaveCount 2
        foreach ($f in $r.ReportFiles) { Test-Path $f | Should -BeTrue }
    }

    It 'Get-OffboardingPlan returns one row per step and changes nothing' {
        $plan = @(Get-OffboardingPlan $jordan)
        $plan | Should -HaveCount 11
        $plan[0].Status | Should -Be 'Passed'
        Get-DemoChanges | Should -BeNullOrEmpty
    }
}

Describe 'Live run' {
    BeforeEach { Connect-OffboardingToolkit -Demo | Out-Null }

    It 'succeeds and blocks sign-in before anything else' {
        $r = Invoke-Live $jordan
        $r.Outcome | Should -Be 'Success'
        (Get-DemoChanges)[0] | Should -Match '^DisableUser:'
    }

    It 'converts the mailbox to shared before removing licenses' {
        Invoke-Live $jordan | Out-Null
        $changes = @(Get-DemoChanges)
        $convert = [array]::FindIndex($changes, [Predicate[string]] { param($x) $x -like 'ConvertToShared:*' })
        $license = [array]::FindIndex($changes, [Predicate[string]] { param($x) $x -like 'RemoveLicenses:*' })
        $convert | Should -BeGreaterThan -1
        $license | Should -BeGreaterThan $convert
    }

    It 'never puts the password in the result or report' {
        $r = Invoke-UserOffboarding -UserPrincipalName $jordan -Confirm:$false -ReportPath $TestDrive -Quiet -PassThru
        $json = Get-Content ($r.ReportFiles | Where-Object { $_ -like '*.json' }) -Raw
        $json | Should -Not -Match 'password"\s*:'
        $json | Should -Match 'never shown, logged or stored'
    }

    It 'keeps dynamic and AD-synced groups and explains why' {
        $r = Invoke-Live $jordan
        $groups = Get-Step $r 'RemoveGroupMemberships'
        ($groups.Actions -join ' ') | Should -Not -Match 'All Employees'
        ($groups.Actions -join ' ') | Should -Not -Match 'Finance Share'
        ($groups.Notes -join ' ') | Should -Match 'rule-based'
        ($groups.Notes -join ' ') | Should -Match 'on-premises AD'
    }

    It 'removes distribution lists through Exchange, not Graph' {
        Invoke-Live $jordan | Out-Null
        Get-DemoChanges | Should -Contain 'RemoveFromDistributionGroup:sales-announce@larkspurlabs.example:jordan.reyes@larkspurlabs.example'
    }

    It 'only removes direct licenses; group licenses go with the group' {
        $r = Invoke-Live $jordan
        $lic = Get-Step $r 'RemoveLicenses'
        $lic.Actions | Should -HaveCount 1
        $lic.Actions[0] | Should -Match 'SPE_E3'
        $lic.Actions[0] | Should -Not -Match 'POWER_BI_PRO'
        ($lic.Notes -join ' ') | Should -Match 'POWER_BI_PRO comes from a group'
    }

    It 'is safe to run twice (second run reports NoChange)' {
        Invoke-Live $jordan | Out-Null
        $r = Invoke-Live $jordan
        (Get-Step $r 'DisableSignIn').Status | Should -Be 'NoChange'
        (Get-Step $r 'ConvertMailboxToShared').Status | Should -Be 'NoChange'
        (Get-Step $r 'RemoveLicenses').Status | Should -Be 'NoChange'
    }
}

Describe 'Safety rails' {
    BeforeEach { Connect-OffboardingToolkit -Demo | Out-Null }

    It 'refuses protected (break-glass) accounts and changes nothing' {
        $r = Invoke-Live 'breakglass01@larkspurlabs.example'
        $r.Outcome | Should -Be 'Blocked'
        (Get-Step $r 'DisableSignIn').Status | Should -Be 'NotRun'
        Get-DemoChanges | Should -BeNullOrEmpty
    }

    It 'refuses users with admin roles by default' {
        $r = Invoke-Live 'sam.okafor@larkspurlabs.example'
        $r.Outcome | Should -Be 'Blocked'
        (Get-Step $r 'Preflight').Message | Should -Match 'Exchange Administrator'
        Get-DemoChanges | Should -BeNullOrEmpty
    }

    It 'allows admin users with -AllowPrivileged' {
        $r = Invoke-Live 'sam.okafor@larkspurlabs.example' -AllowPrivileged
        $r.Outcome | Should -Be 'Success'
    }

    It 'refuses users synced from on-premises AD' {
        $r = Invoke-Live 'morgan.blake@larkspurlabs.example'
        $r.Outcome | Should -Be 'Blocked'
        Get-DemoChanges | Should -BeNullOrEmpty
    }

    It 'fails cleanly when the user does not exist' {
        $r = Invoke-Live 'nobody@larkspurlabs.example'
        $r.Outcome | Should -Be 'Failed'
        (Get-Step $r 'Preflight').Message | Should -Match 'was not found'
    }

    It 'keeps Exchange licenses when Exchange Online is not connected' {
        InModule { $script:Provider.ExchangeConnected = $false }
        $r = Invoke-Live $jordan
        (Get-Step $r 'ConvertMailboxToShared').Status | Should -Be 'Skipped'
        (Get-Step $r 'RemoveLicenses').Status | Should -Be 'Skipped'
        (Get-DemoChanges | Where-Object { $_ -like 'RemoveLicenses:*' }) | Should -BeNullOrEmpty
    }

    It 'only reports devices when DeviceAction is None (the default)' {
        $r = Invoke-Live $jordan
        (Get-Step $r 'DeviceAction').Status | Should -Be 'Skipped'
        (Get-DemoChanges | Where-Object { $_ -match 'Device' }) | Should -BeNullOrEmpty
    }

    It 'never wipes a personal device, even when DeviceAction is Wipe' {
        $cfg = New-TestConfig @{ DeviceAction = 'Wipe' }
        Invoke-Live $jordan -ConfigPath $cfg | Out-Null
        $changes = @(Get-DemoChanges)
        $changes | Should -Contain 'WipeDevice:d0c5e1a0-0001-47b1-8e10-0000000000d1'      # company laptop
        $changes | Should -Contain 'RetireDevice:d0c5e1a0-0002-47b1-8e10-0000000000d2'    # personal iPhone
        $changes | Should -Not -Contain 'WipeDevice:d0c5e1a0-0002-47b1-8e10-0000000000d2'
    }

    It 'skips steps that are turned off in the config' {
        $cfg = New-TestConfig @{ Steps = @{ ResetPassword = $false } }
        $r = Invoke-Live $jordan -ConfigPath $cfg
        (Get-Step $r 'ResetPassword').Status | Should -Be 'Skipped'
        (Get-DemoChanges | Where-Object { $_ -like 'ResetPassword:*' }) | Should -BeNullOrEmpty
    }
}

Describe 'Config' {
    It 'rejects unknown settings so a typo cannot turn off a safety check' {
        $cfg = New-TestConfig @{ BlockPrivilegedUser = $false }
        { InModule { param($p) Read-OffboardingConfig -Path $p } @($cfg) } | Should -Throw '*Unknown config setting*'
    }

    It 'rejects an invalid DeviceAction' {
        $cfg = New-TestConfig @{ DeviceAction = 'Nuke' }
        { InModule { param($p) Read-OffboardingConfig -Path $p } @($cfg) } | Should -Throw '*DeviceAction must be one of*'
    }

    It 'New-OffboardingConfig writes a file that loads back cleanly' {
        $path = Join-Path $TestDrive 'new.json'
        New-OffboardingConfig -Path $path | Out-Null
        $loaded = InModule { param($p) Read-OffboardingConfig -Path $p } @($path)
        $loaded.DeviceAction | Should -Be 'None'
        $loaded.BlockPrivilegedUsers | Should -BeTrue
    }
}

Describe 'Helpers' {
    It 'generates a 24-character password with every character type' {
        $plain = InModule { [System.Net.NetworkCredential]::new('', (New-RandomPassword -Length 24)).Password }
        $plain.Length | Should -Be 24
        $plain | Should -Match '[A-Z]'
        $plain | Should -Match '[a-z]'
        $plain | Should -Match '[0-9]'
        $plain | Should -Match '[^A-Za-z0-9]'
    }

    It 'HTML-encodes values in the auto-reply template' {
        $text = InModule { Resolve-MessageTemplate -Template 'Contact {ManagerName}' -Values @{ ManagerName = '<script>' } }
        $text | Should -Be 'Contact &lt;script&gt;'
    }

    It 'matches protected accounts with wildcards' {
        InModule { Test-ProtectedAccount -UserPrincipalName 'breakglass02@contoso.com' -Patterns @('breakglass*@*') } | Should -BeTrue
        InModule { Test-ProtectedAccount -UserPrincipalName 'jane@contoso.com' -Patterns @('breakglass*@*') } | Should -BeFalse
    }
}

Describe 'Graph provider (fake transport, no tenant needed)' {
    BeforeAll {
        # Records every Graph call and returns canned responses, so URLs and bodies can be checked.
        $calls = [System.Collections.Generic.List[object]]::new()
        $responses = @{}
        $graph = {
            param($Method, $Uri, $Body)
            $calls.Add([pscustomobject]@{ Method = $Method; Uri = $Uri; Body = $Body })
            foreach ($key in $responses.Keys) {
                if ($Uri -like $key) {
                    $value = $responses[$key]
                    if ($value -is [scriptblock]) { return & $value }
                    return $value
                }
            }
            $null
        }.GetNewClosure()
        $exchange = {
            param($Command, $Parameters)
            $calls.Add([pscustomobject]@{ Method = $Command; Uri = $Parameters.Identity; Body = $Parameters })
        }.GetNewClosure()
        $provider = InModule { param($g, $e) New-GraphProvider -Name 'test' -ExchangeConnected $true -GraphTransport $g -ExchangeTransport $e } @($graph, $exchange)
    }

    BeforeEach {
        $calls.Clear()
        $responses.Clear()
    }

    It 'disables sign-in with a PATCH on the user' {
        $provider.DisableUser('u1')
        $calls[0].Method | Should -Be 'PATCH'
        $calls[0].Uri | Should -Be 'https://graph.microsoft.com/v1.0/users/u1'
        $calls[0].Body.accountEnabled | Should -BeFalse
    }

    It 'removes group membership with DELETE on the $ref link' {
        $provider.RemoveFromGroup('g1', 'u1')
        $calls[0].Method | Should -Be 'DELETE'
        $calls[0].Uri | Should -Be 'https://graph.microsoft.com/v1.0/groups/g1/members/u1/$ref'
    }

    It 'removes licenses through assignLicense' {
        $provider.RemoveLicenses('u1', @('sku-a', 'sku-b'))
        $calls[0].Uri | Should -Be 'https://graph.microsoft.com/v1.0/users/u1/assignLicense'
        $calls[0].Body.removeLicenses | Should -HaveCount 2
    }

    It 'returns $null instead of throwing when a user is not found' {
        $responses['*/users/*'] = { throw 'Request_ResourceNotFound: 404 NotFound' }
        $provider.GetUser('ghost@contoso.com') | Should -BeNullOrEmpty
    }

    It 'URL-encodes the UPN' {
        $responses['*/users/*'] = [pscustomobject]@{ id = 'u9'; userPrincipalName = "o'neil#1@contoso.com"; displayName = 'Pat' }
        $u = $provider.GetUser("o'neil#1@contoso.com")
        $u.Id | Should -Be 'u9'
        $calls[0].Uri | Should -Match '/users/o%27neil%231%40contoso.com\?'
    }

    It 'follows @odata.nextLink so long lists are not cut off' {
        $responses['*memberOf/microsoft.graph.group*'] = [pscustomobject]@{
            value             = @([pscustomobject]@{ id = 'g1'; displayName = 'One' })
            '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/page2'
        }
        $responses['*/page2'] = [pscustomobject]@{ value = @([pscustomobject]@{ id = 'g2'; displayName = 'Two'; groupTypes = @('Unified') }) }
        $groups = @($provider.GetGroups('u1'))
        $groups | Should -HaveCount 2
        $groups[1].GroupTypes | Should -Contain 'Unified'
    }

    It 'separates direct and group-assigned licenses' {
        $responses['*/subscribedSkus'] = [pscustomobject]@{ value = @(
                [pscustomobject]@{ skuId = 's1'; skuPartNumber = 'SPE_E3'; servicePlans = @([pscustomobject]@{ servicePlanName = 'EXCHANGE_S_ENTERPRISE' }) }
                [pscustomobject]@{ skuId = 's2'; skuPartNumber = 'POWER_BI_PRO'; servicePlans = @([pscustomobject]@{ servicePlanName = 'BI_AZURE_P2' }) }
            )
        }
        $responses['*licenseAssignmentStates*'] = [pscustomobject]@{ licenseAssignmentStates = @(
                [pscustomobject]@{ skuId = 's1'; assignedByGroup = $null }
                [pscustomobject]@{ skuId = 's2'; assignedByGroup = 'grp-1' }
            )
        }
        $lic = @($provider.GetLicenses('u1'))
        $e3 = $lic | Where-Object SkuId -eq 's1'
        $bi = $lic | Where-Object SkuId -eq 's2'
        $e3.Direct | Should -BeTrue
        $e3.IncludesExchange | Should -BeTrue
        $bi.Direct | Should -BeFalse
        $bi.ViaGroupIds | Should -Contain 'grp-1'
    }

    It 'converts the mailbox with Set-Mailbox -Type Shared' {
        $provider.ConvertToShared('jane@contoso.com')
        $calls[0].Method | Should -Be 'Set-Mailbox'
        $calls[0].Body.Type | Should -Be 'Shared'
    }

    It 'sends the reset password in passwordProfile and forces a change at next sign-in' {
        $pw = InModule { New-RandomPassword }
        $provider.ResetPassword('u1', $pw)
        $calls[0].Body.passwordProfile.forceChangePasswordNextSignIn | Should -BeTrue
        $calls[0].Body.passwordProfile.password.Length | Should -Be 24
    }
}
