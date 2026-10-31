function New-GraphProvider {
    <#
    .SYNOPSIS
    Talks to a real tenant: Microsoft Graph for Entra ID, licenses, OneDrive and Intune,
    and Exchange Online PowerShell for the mailbox steps Graph cannot do.

    .DESCRIPTION
    Both connections are passed in as scriptblocks ("transports"). In normal use they
    call Invoke-MgGraphRequest and the Exchange cmdlets. The Pester tests pass fake
    transports instead, so every Graph URL and request body is checked without a tenant.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an object in memory; changes nothing outside the session.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $Operator = 'unknown',
        [bool] $ExchangeConnected = $false,
        [scriptblock] $GraphTransport = {
            param([string] $Method, [string] $Uri, $Body)
            $request = @{ Method = $Method; Uri = $Uri; OutputType = 'PSObject'; ErrorAction = 'Stop' }
            if ($null -ne $Body) {
                $request.Body = $Body | ConvertTo-Json -Depth 10 -Compress
                $request.ContentType = 'application/json'
            }
            Invoke-MgGraphRequest @request
        },
        [scriptblock] $ExchangeTransport = {
            param([string] $Command, [hashtable] $Parameters)
            & $Command @Parameters
        }
    )

    $p = [pscustomobject]@{
        Kind              = 'Graph'
        Name              = $Name
        Operator          = $Operator
        ExchangeConnected = $ExchangeConnected
        Graph             = $GraphTransport
        Exchange          = $ExchangeTransport
        BaseUri           = 'https://graph.microsoft.com/v1.0'
        SkuCache          = $null
    }

    # ---- plumbing ---------------------------------------------------------
    $p | Add-Member ScriptMethod Call {
        param([string] $Method, [string] $Path, $Body)
        & $this.Graph $Method ($this.BaseUri + $Path) $Body
    }

    # GET that returns $null instead of throwing when the object does not exist.
    $p | Add-Member ScriptMethod TryGet {
        param([string] $Path)
        try { $this.Call('GET', $Path, $null) }
        catch {
            if ($_.Exception.Message -match 'NotFound|404|ResourceNotFound|does not exist') { return $null }
            throw
        }
    }

    # GET that follows @odata.nextLink so large group or device lists are not cut off at 100.
    $p | Add-Member ScriptMethod GetAll {
        param([string] $Path)
        $items = [System.Collections.Generic.List[object]]::new()
        $page = $this.Call('GET', $Path, $null)
        while ($null -ne $page) {
            foreach ($item in @(Get-ObjectProperty $page 'value' @())) { $items.Add($item) }
            $next = Get-ObjectProperty $page '@odata.nextLink'
            $page = if ($next) { & $this.Graph 'GET' $next $null } else { $null }
        }
        , $items.ToArray()
    }

    $p | Add-Member ScriptMethod ToUser {
        param($u)
        if ($null -eq $u) { return $null }
        [pscustomobject]@{
            Id                    = Get-ObjectProperty $u 'id'
            UserPrincipalName     = Get-ObjectProperty $u 'userPrincipalName'
            DisplayName           = Get-ObjectProperty $u 'displayName'
            JobTitle              = Get-ObjectProperty $u 'jobTitle'
            Department            = Get-ObjectProperty $u 'department'
            Mail                  = Get-ObjectProperty $u 'mail'
            AccountEnabled        = [bool](Get-ObjectProperty $u 'accountEnabled' $true)
            OnPremisesSyncEnabled = [bool](Get-ObjectProperty $u 'onPremisesSyncEnabled' $false)
        }
    }

    $p | Add-Member ScriptMethod InvokeExchange {
        param([string] $Command, [hashtable] $Parameters)
        if (-not $this.ExchangeConnected) { throw 'Not connected to Exchange Online.' }
        & $this.Exchange $Command $Parameters
    }

    # ---- reads ------------------------------------------------------------
    $p | Add-Member ScriptMethod GetUser {
        param([string] $UserPrincipalName)
        $select = 'id,userPrincipalName,displayName,jobTitle,department,mail,accountEnabled,onPremisesSyncEnabled'
        $this.ToUser($this.TryGet("/users/$(ConvertTo-UriSegment $UserPrincipalName)?`$select=$select"))
    }

    $p | Add-Member ScriptMethod GetManager {
        param([string] $UserId)
        $this.ToUser($this.TryGet("/users/$UserId/manager?`$select=id,userPrincipalName,displayName,mail"))
    }

    $p | Add-Member ScriptMethod GetDirectoryRoles {
        param([string] $UserId)
        # Active role assignments. PIM-eligible roles that are not activated are not returned.
        $roles = $this.GetAll("/users/$UserId/memberOf/microsoft.graph.directoryRole?`$select=id,displayName")
        , @($roles | ForEach-Object { Get-ObjectProperty $_ 'displayName' })
    }

    $p | Add-Member ScriptMethod GetGroups {
        param([string] $UserId)
        $select = 'id,displayName,groupTypes,mailEnabled,securityEnabled,onPremisesSyncEnabled,mail'
        $groups = $this.GetAll("/users/$UserId/memberOf/microsoft.graph.group?`$select=$select")
        $out = foreach ($g in $groups) {
            [pscustomobject]@{
                Id                    = Get-ObjectProperty $g 'id'
                DisplayName           = Get-ObjectProperty $g 'displayName'
                GroupTypes            = @(Get-ObjectProperty $g 'groupTypes' @())
                MailEnabled           = [bool](Get-ObjectProperty $g 'mailEnabled' $false)
                SecurityEnabled       = [bool](Get-ObjectProperty $g 'securityEnabled' $false)
                OnPremisesSyncEnabled = [bool](Get-ObjectProperty $g 'onPremisesSyncEnabled' $false)
                Mail                  = Get-ObjectProperty $g 'mail'
            }
        }
        , @($out)
    }

    $p | Add-Member ScriptMethod GetSkus {
        if ($null -eq $this.SkuCache) {
            $cache = @{}
            foreach ($s in $this.GetAll('/subscribedSkus')) {
                $plans = @(Get-ObjectProperty $s 'servicePlans' @()) | ForEach-Object { Get-ObjectProperty $_ 'servicePlanName' }
                $cache[[string](Get-ObjectProperty $s 'skuId')] = [pscustomobject]@{
                    SkuPartNumber    = Get-ObjectProperty $s 'skuPartNumber'
                    IncludesExchange = [bool](@($plans) -match '^EXCHANGE_S_')
                }
            }
            $this.SkuCache = $cache
        }
        $this.SkuCache
    }

    $p | Add-Member ScriptMethod GetLicenses {
        param([string] $UserId)
        $u = $this.Call('GET', "/users/$UserId`?`$select=licenseAssignmentStates", $null)
        $skus = $this.GetSkus()

        # One SKU can be assigned directly AND through one or more groups, so group the states.
        $bySku = [ordered]@{}
        foreach ($state in @(Get-ObjectProperty $u 'licenseAssignmentStates' @())) {
            $skuId = [string](Get-ObjectProperty $state 'skuId')
            if (-not $bySku.Contains($skuId)) { $bySku[$skuId] = @{ Direct = $false; Groups = [System.Collections.Generic.List[string]]::new() } }
            $groupId = Get-ObjectProperty $state 'assignedByGroup'
            if ($groupId) { $bySku[$skuId].Groups.Add($groupId) } else { $bySku[$skuId].Direct = $true }
        }

        $out = foreach ($skuId in $bySku.Keys) {
            $info = $skus[$skuId]
            [pscustomobject]@{
                SkuId            = $skuId
                SkuPartNumber    = if ($info) { $info.SkuPartNumber } else { $skuId }
                DisplayName      = if ($info) { $info.SkuPartNumber } else { $skuId }
                Direct           = $bySku[$skuId].Direct
                ViaGroupIds      = $bySku[$skuId].Groups.ToArray()
                IncludesExchange = if ($info) { $info.IncludesExchange } else { $false }
            }
        }
        , @($out)
    }

    $p | Add-Member ScriptMethod GetDevices {
        param([string] $UserId)
        $select = 'id,deviceName,operatingSystem,managedDeviceOwnerType,complianceState'
        $devices = $this.GetAll("/users/$UserId/managedDevices?`$select=$select")
        $out = foreach ($d in $devices) {
            [pscustomobject]@{
                Id              = Get-ObjectProperty $d 'id'
                DeviceName      = Get-ObjectProperty $d 'deviceName'
                OperatingSystem = Get-ObjectProperty $d 'operatingSystem'
                OwnerType       = Get-ObjectProperty $d 'managedDeviceOwnerType' 'unknown'
                ComplianceState = Get-ObjectProperty $d 'complianceState'
            }
        }
        , @($out)
    }

    $p | Add-Member ScriptMethod GetMailbox {
        param([string] $UserPrincipalName)
        try {
            $m = $this.InvokeExchange('Get-EXOMailbox', @{
                    Identity    = $UserPrincipalName
                    Properties  = @('RecipientTypeDetails', 'HiddenFromAddressListsEnabled')
                    ErrorAction = 'Stop'
                })
        }
        catch {
            if ($_.Exception.Message -match "couldn't be found|ManagementObjectNotFound|not found") { return $null }
            throw
        }
        if ($null -eq $m) { return $null }
        [pscustomobject]@{
            RecipientTypeDetails          = [string](Get-ObjectProperty $m 'RecipientTypeDetails')
            HiddenFromAddressListsEnabled = [bool](Get-ObjectProperty $m 'HiddenFromAddressListsEnabled' $false)
        }
    }

    $p | Add-Member ScriptMethod GetOneDrive {
        param([string] $UserId)
        $d = $this.TryGet("/users/$UserId/drive?`$select=id,webUrl")
        if ($null -eq $d) { return $null }
        [pscustomobject]@{ Id = Get-ObjectProperty $d 'id'; WebUrl = Get-ObjectProperty $d 'webUrl' }
    }

    # ---- writes -----------------------------------------------------------
    $p | Add-Member ScriptMethod DisableUser {
        param([string] $UserId)
        [void]$this.Call('PATCH', "/users/$UserId", @{ accountEnabled = $false })
    }

    $p | Add-Member ScriptMethod RevokeSessions {
        param([string] $UserId)
        [void]$this.Call('POST', "/users/$UserId/revokeSignInSessions", $null)
    }

    $p | Add-Member ScriptMethod ResetPassword {
        param([string] $UserId, [securestring] $Password)
        $plain = [System.Net.NetworkCredential]::new('', $Password).Password
        try {
            [void]$this.Call('PATCH', "/users/$UserId", @{
                    passwordProfile = @{ password = $plain; forceChangePasswordNextSignIn = $true }
                })
        }
        finally { $plain = $null }
    }

    $p | Add-Member ScriptMethod SetAutoReply {
        param([string] $UserId, [string] $Internal, [string] $External)
        [void]$this.Call('PATCH', "/users/$UserId/mailboxSettings", @{
                automaticRepliesSetting = @{
                    status                 = 'alwaysEnabled'
                    externalAudience       = 'all'
                    internalReplyMessage   = $Internal
                    externalReplyMessage   = $External
                }
            })
    }

    $p | Add-Member ScriptMethod ConvertToShared {
        param([string] $UserPrincipalName)
        [void]$this.InvokeExchange('Set-Mailbox', @{ Identity = $UserPrincipalName; Type = 'Shared'; ErrorAction = 'Stop' })
    }

    $p | Add-Member ScriptMethod HideFromAddressList {
        param([string] $UserPrincipalName)
        [void]$this.InvokeExchange('Set-Mailbox', @{ Identity = $UserPrincipalName; HiddenFromAddressListsEnabled = $true; ErrorAction = 'Stop' })
    }

    $p | Add-Member ScriptMethod GrantOneDriveAccess {
        param([string] $DriveId, [string] $RecipientEmail)
        [void]$this.Call('POST', "/drives/$DriveId/root/invite", @{
                recipients     = @(@{ email = $RecipientEmail })
                roles          = @('write')
                requireSignIn  = $true
                sendInvitation = $true
                message        = 'You have been given access to this OneDrive as part of an offboarding. Please move anything the team needs before it is removed.'
            })
    }

    $p | Add-Member ScriptMethod RemoveFromGroup {
        param([string] $GroupId, [string] $UserId)
        [void]$this.Call('DELETE', "/groups/$GroupId/members/$UserId/" + '$ref', $null)
    }

    $p | Add-Member ScriptMethod RemoveFromDistributionGroup {
        param([string] $GroupMail, [string] $UserPrincipalName)
        [void]$this.InvokeExchange('Remove-DistributionGroupMember', @{
                Identity                        = $GroupMail
                Member                          = $UserPrincipalName
                BypassSecurityGroupManagerCheck = $true
                Confirm                         = $false
                ErrorAction                     = 'Stop'
            })
    }

    $p | Add-Member ScriptMethod RemoveLicenses {
        param([string] $UserId, [string[]] $SkuIds)
        [void]$this.Call('POST', "/users/$UserId/assignLicense", @{
                addLicenses    = @()
                removeLicenses = @($SkuIds)
            })
    }

    $p | Add-Member ScriptMethod RetireDevice {
        param([string] $DeviceId)
        [void]$this.Call('POST', "/deviceManagement/managedDevices/$DeviceId/retire", $null)
    }

    $p | Add-Member ScriptMethod WipeDevice {
        param([string] $DeviceId)
        [void]$this.Call('POST', "/deviceManagement/managedDevices/$DeviceId/wipe", @{ keepEnrollmentData = $false; keepUserData = $false })
    }

    $p | Add-Member ScriptMethod Disconnect {
        if (Get-Command Disconnect-MgGraph -ErrorAction SilentlyContinue) { [void](Disconnect-MgGraph -ErrorAction SilentlyContinue) }
        if ($this.ExchangeConnected -and (Get-Command Disconnect-ExchangeOnline -ErrorAction SilentlyContinue)) {
            Disconnect-ExchangeOnline -Confirm:$false -ErrorAction SilentlyContinue
        }
    }

    $p
}
