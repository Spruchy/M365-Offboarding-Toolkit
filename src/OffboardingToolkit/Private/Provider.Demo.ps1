function New-DemoProvider {
    <#
    .SYNOPSIS
    An in-memory fake tenant that implements the same methods as the Graph provider.
    Lets anyone run the toolkit end to end with no Microsoft 365 access, and lets the
    Pester tests check exactly what was changed.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; changes nothing outside the session.')]
    [CmdletBinding()]
    param(
        [string] $DataPath = (Join-Path $script:ModuleRoot 'Data/demo-tenant.json')
    )

    $state = Get-Content -LiteralPath $DataPath -Raw | ConvertFrom-Json -AsHashtable

    $p = [pscustomobject]@{
        Kind              = 'Demo'
        Name              = $state.tenant.name
        Operator          = 'it.admin@larkspurlabs.example (demo)'
        ExchangeConnected = $true
        State             = $state
        # Every write is recorded here so tests can assert on it.
        Changes           = [System.Collections.Generic.List[string]]::new()
    }

    # ---- internal lookups -------------------------------------------------
    $p | Add-Member ScriptMethod FindUser {
        param([string] $Key)
        foreach ($u in $this.State.users) {
            if ($u.id -eq $Key -or $u.userPrincipalName -eq $Key) { return $u }
        }
        $null
    }

    $p | Add-Member ScriptMethod ToUser {
        param($u)
        if ($null -eq $u) { return $null }
        [pscustomobject]@{
            Id                    = $u.id
            UserPrincipalName     = $u.userPrincipalName
            DisplayName           = $u.displayName
            JobTitle              = $u.jobTitle
            Department            = $u.department
            Mail                  = $u.mail
            AccountEnabled        = [bool]$u.accountEnabled
            OnPremisesSyncEnabled = [bool]$u.onPremisesSyncEnabled
        }
    }

    $p | Add-Member ScriptMethod Record {
        param([string] $Change)
        $this.Changes.Add($Change)
    }

    # ---- reads ------------------------------------------------------------
    $p | Add-Member ScriptMethod GetUser {
        param([string] $UserPrincipalName)
        $this.ToUser($this.FindUser($UserPrincipalName))
    }

    $p | Add-Member ScriptMethod GetManager {
        param([string] $UserId)
        $u = $this.FindUser($UserId)
        if ($null -eq $u -or $null -eq $u.managerId) { return $null }
        $this.ToUser($this.FindUser($u.managerId))
    }

    $p | Add-Member ScriptMethod GetDirectoryRoles {
        param([string] $UserId)
        ,@($this.FindUser($UserId).roles)
    }

    $p | Add-Member ScriptMethod GetGroups {
        param([string] $UserId)
        $u = $this.FindUser($UserId)
        $out = foreach ($g in $this.State.groups) {
            if ($u.groupIds -contains $g.id) {
                [pscustomobject]@{
                    Id                    = $g.id
                    DisplayName           = $g.displayName
                    GroupTypes            = @($g.groupTypes)
                    MailEnabled           = [bool]$g.mailEnabled
                    SecurityEnabled       = [bool]$g.securityEnabled
                    OnPremisesSyncEnabled = [bool]$g.onPremisesSyncEnabled
                    Mail                  = $g.mail
                }
            }
        }
        ,@($out)
    }

    $p | Add-Member ScriptMethod GetLicenses {
        param([string] $UserId)
        $u = $this.FindUser($UserId)
        $out = foreach ($l in $u.licenses) {
            $sku = $this.State.skus | Where-Object { $_.skuId -eq $l.skuId } | Select-Object -First 1
            [pscustomobject]@{
                SkuId            = $l.skuId
                SkuPartNumber    = $sku.skuPartNumber
                DisplayName      = $sku.displayName
                Direct           = [bool]$l.direct
                ViaGroupIds      = @($l.viaGroupIds)
                IncludesExchange = [bool]$sku.includesExchange
            }
        }
        ,@($out)
    }

    $p | Add-Member ScriptMethod GetDevices {
        param([string] $UserId)
        $out = foreach ($d in $this.State.devices) {
            if ($d.userId -eq $UserId) {
                [pscustomobject]@{
                    Id              = $d.id
                    DeviceName      = $d.deviceName
                    OperatingSystem = $d.operatingSystem
                    OwnerType       = $d.ownerType
                    ComplianceState = $d.complianceState
                }
            }
        }
        ,@($out)
    }

    $p | Add-Member ScriptMethod GetMailbox {
        param([string] $UserPrincipalName)
        $m = $this.FindUser($UserPrincipalName).mailbox
        if ($null -eq $m) { return $null }
        [pscustomobject]@{
            RecipientTypeDetails          = $m.recipientTypeDetails
            HiddenFromAddressListsEnabled = [bool]$m.hiddenFromAddressListsEnabled
        }
    }

    $p | Add-Member ScriptMethod GetOneDrive {
        param([string] $UserId)
        $d = $this.FindUser($UserId).oneDrive
        if ($null -eq $d) { return $null }
        [pscustomobject]@{ Id = $d.id; WebUrl = $d.webUrl }
    }

    # ---- writes -----------------------------------------------------------
    $p | Add-Member ScriptMethod DisableUser {
        param([string] $UserId)
        $this.FindUser($UserId).accountEnabled = $false
        $this.Record("DisableUser:$UserId")
    }

    $p | Add-Member ScriptMethod RevokeSessions {
        param([string] $UserId)
        $this.Record("RevokeSessions:$UserId")
    }

    $p | Add-Member ScriptMethod ResetPassword {
        param([string] $UserId, [securestring] $Password)
        if ($null -eq $Password -or $Password.Length -lt 16) { throw 'Password was not generated.' }
        $this.Record("ResetPassword:$UserId")
    }

    $p | Add-Member ScriptMethod SetAutoReply {
        param([string] $UserId, [string] $Internal, [string] $External)
        $this.FindUser($UserId).autoReply = @{ internal = $Internal; external = $External }
        $this.Record("SetAutoReply:$UserId")
    }

    $p | Add-Member ScriptMethod ConvertToShared {
        param([string] $UserPrincipalName)
        $this.FindUser($UserPrincipalName).mailbox.recipientTypeDetails = 'SharedMailbox'
        $this.Record("ConvertToShared:$UserPrincipalName")
    }

    $p | Add-Member ScriptMethod HideFromAddressList {
        param([string] $UserPrincipalName)
        $this.FindUser($UserPrincipalName).mailbox.hiddenFromAddressListsEnabled = $true
        $this.Record("HideFromAddressList:$UserPrincipalName")
    }

    $p | Add-Member ScriptMethod GrantOneDriveAccess {
        param([string] $DriveId, [string] $RecipientEmail)
        $this.Record("GrantOneDriveAccess:${DriveId}:$RecipientEmail")
    }

    $p | Add-Member ScriptMethod RemoveFromGroup {
        param([string] $GroupId, [string] $UserId)
        $u = $this.FindUser($UserId)
        $u.groupIds = @($u.groupIds | Where-Object { $_ -ne $GroupId })
        # Group-based licenses go away with the membership, same as in Entra ID.
        $u.licenses = @($u.licenses | Where-Object { $_.direct -or (@($_.viaGroupIds) -notcontains $GroupId) })
        $this.Record("RemoveFromGroup:${GroupId}:$UserId")
    }

    $p | Add-Member ScriptMethod RemoveFromDistributionGroup {
        param([string] $GroupMail, [string] $UserPrincipalName)
        $g = $this.State.groups | Where-Object { $_.mail -eq $GroupMail } | Select-Object -First 1
        $u = $this.FindUser($UserPrincipalName)
        $u.groupIds = @($u.groupIds | Where-Object { $_ -ne $g.id })
        $this.Record("RemoveFromDistributionGroup:${GroupMail}:$UserPrincipalName")
    }

    $p | Add-Member ScriptMethod RemoveLicenses {
        param([string] $UserId, [string[]] $SkuIds)
        $u = $this.FindUser($UserId)
        $u.licenses = @($u.licenses | Where-Object { -not ($_.direct -and $SkuIds -contains $_.skuId) })
        $this.Record("RemoveLicenses:${UserId}:$($SkuIds -join ',')")
    }

    $p | Add-Member ScriptMethod RetireDevice {
        param([string] $DeviceId)
        $this.Record("RetireDevice:$DeviceId")
    }

    $p | Add-Member ScriptMethod WipeDevice {
        param([string] $DeviceId)
        $this.Record("WipeDevice:$DeviceId")
    }

    $p | Add-Member ScriptMethod Disconnect { }

    $p
}
