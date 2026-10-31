function Get-OffboardingStepDefinition {
    <#
    .SYNOPSIS
    The ordered list of offboarding steps. Order matters:
      - Sign-in is blocked first, so the user cannot act while the rest runs.
      - The mailbox is converted to shared BEFORE licenses are removed. Removing the
        Exchange license from a normal mailbox starts a 30-day countdown to deletion.
      - Group memberships are removed before licenses, because some licenses come from groups.
    Each step receives a context object ($c) and makes changes only through
    Invoke-OffboardingAction, which is what makes dry runs safe.
    #>
    [CmdletBinding()]
    param()

    @(
        [pscustomobject]@{
            Name     = 'Preflight'
            Title    = 'Safety checks and snapshot'
            Critical = $true
            Script   = {
                param($c)
                $p = $c.Provider

                $user = $p.GetUser($c.UserPrincipalName)
                if ($null -eq $user) { throw "User '$($c.UserPrincipalName)' was not found in $($p.Name)." }
                $c.User = $user
                $c.Result.DisplayName = $user.DisplayName

                if (Test-ProtectedAccount -UserPrincipalName $user.UserPrincipalName -Patterns $c.Config.ProtectedAccounts) {
                    Block-Offboarding $c "$($user.UserPrincipalName) matches the ProtectedAccounts list in the config. Protected accounts (such as break-glass admins) are never offboarded by this tool."
                    return
                }

                if ($user.OnPremisesSyncEnabled) {
                    Block-Offboarding $c "$($user.UserPrincipalName) is synced from on-premises Active Directory. Disable the account in AD first; cloud changes to a synced account are overwritten at the next sync. Hybrid support is on the roadmap."
                    return
                }

                $roles = @($p.GetDirectoryRoles($user.Id))
                if ($roles.Count -gt 0) {
                    if ($c.Config.BlockPrivilegedUsers -and -not $c.AllowPrivileged) {
                        Block-Offboarding $c "$($user.DisplayName) holds admin roles: $($roles -join ', '). Remove the roles through your normal change process first, or rerun with -AllowPrivileged after review."
                        return
                    }
                    Add-StepNote $c "Admin roles present and allowed by -AllowPrivileged: $($roles -join ', '). Removing role assignments is not automated; do it in PIM or Entra ID roles."
                }

                $c.Manager = $p.GetManager($user.Id)
                if ($c.Manager) {
                    $c.Result.Manager = "$($c.Manager.DisplayName) <$($c.Manager.UserPrincipalName)>"
                    Add-StepNote $c "Manager: $($c.Result.Manager)"
                }
                else {
                    Add-StepNote $c 'No manager set in Entra ID. The auto-reply and OneDrive handoff steps will be skipped.'
                }

                # Snapshot of everything we might change. It goes in the report so access can be restored if needed.
                $c.Facts.Groups = @($p.GetGroups($user.Id))
                $c.Facts.Licenses = @($p.GetLicenses($user.Id))
                $c.Facts.Devices = @($p.GetDevices($user.Id))
                $c.Facts.Mailbox = if ($p.ExchangeConnected) { $p.GetMailbox($user.UserPrincipalName) } else { $null }

                $before = $c.Result.Before
                $before.AccountEnabled = $user.AccountEnabled
                $before.Groups = @($c.Facts.Groups | ForEach-Object { $_.DisplayName })
                $before.Licenses = @($c.Facts.Licenses | ForEach-Object { if ($_.Direct) { $_.SkuPartNumber } else { "$($_.SkuPartNumber) (via group)" } })
                $before.Devices = @($c.Facts.Devices | ForEach-Object { "$($_.DeviceName) ($($_.OperatingSystem), $($_.OwnerType))" })
                $before.Mailbox = if ($c.Facts.Mailbox) { $c.Facts.Mailbox.RecipientTypeDetails } elseif ($p.ExchangeConnected) { 'None' } else { 'Unknown (Exchange not connected)' }

                Add-StepNote $c ("Found {0} groups, {1} licenses, {2} managed devices." -f $c.Facts.Groups.Count, $c.Facts.Licenses.Count, $c.Facts.Devices.Count)
                $c.Step.Status = 'Passed'
            }
        }

        [pscustomobject]@{
            Name     = 'DisableSignIn'
            Title    = 'Block sign-in'
            Critical = $true
            Script   = {
                param($c)
                if (-not $c.User.AccountEnabled) {
                    Add-StepNote $c 'Sign-in was already blocked.'
                    return
                }
                $id = $c.User.Id
                Invoke-OffboardingAction $c "Block sign-in for $($c.User.UserPrincipalName)" { $c.Provider.DisableUser($id) }
            }
        }

        [pscustomobject]@{
            Name     = 'RevokeSessions'
            Title    = 'Sign out everywhere'
            Critical = $false
            Script   = {
                param($c)
                $id = $c.User.Id
                Invoke-OffboardingAction $c 'Revoke all refresh tokens and browser sessions' { $c.Provider.RevokeSessions($id) }
                Add-StepNote $c 'Apps that cache an access token can keep working for up to about an hour unless the tenant uses Continuous Access Evaluation.'
            }
        }

        [pscustomobject]@{
            Name     = 'ResetPassword'
            Title    = 'Reset password'
            Critical = $false
            Script   = {
                param($c)
                $id = $c.User.Id
                Invoke-OffboardingAction $c 'Set a random 24-character password (never shown, logged or stored)' {
                    $c.Provider.ResetPassword($id, (New-RandomPassword -Length 24))
                }
            }
        }

        [pscustomobject]@{
            Name     = 'SetAutoReply'
            Title    = 'Set out-of-office reply'
            Critical = $false
            Script   = {
                param($c)
                if ($null -eq $c.Manager) { Skip-OffboardingStep $c 'No manager to point senders to.'; return }
                if ($c.Provider.ExchangeConnected -and $null -eq $c.Facts.Mailbox) { Skip-OffboardingStep $c 'User has no mailbox.'; return }

                $values = @{
                    DisplayName  = $c.User.DisplayName
                    CompanyName  = $c.Config.CompanyName
                    ManagerName  = $c.Manager.DisplayName
                    ManagerEmail = if ($c.Manager.Mail) { $c.Manager.Mail } else { $c.Manager.UserPrincipalName }
                }
                $internal = Resolve-MessageTemplate -Template $c.Config.AutoReply.Internal -Values $values
                $external = Resolve-MessageTemplate -Template $c.Config.AutoReply.External -Values $values
                $id = $c.User.Id
                Invoke-OffboardingAction $c "Turn on auto-reply pointing to $($c.Manager.DisplayName)" {
                    $c.Provider.SetAutoReply($id, $internal, $external)
                }
            }
        }

        [pscustomobject]@{
            Name     = 'ConvertMailboxToShared'
            Title    = 'Convert mailbox to shared'
            Critical = $false
            Script   = {
                param($c)
                $c.Facts.MailboxSafe = $false
                if (-not $c.Provider.ExchangeConnected) {
                    Skip-OffboardingStep $c 'Not connected to Exchange Online. Licenses that include Exchange will be kept so the mailbox is not deleted.'
                    return
                }
                $mbx = $c.Facts.Mailbox
                if ($null -eq $mbx) {
                    $c.Facts.MailboxSafe = $true
                    Skip-OffboardingStep $c 'User has no mailbox.'
                    return
                }
                if ($mbx.RecipientTypeDetails -eq 'SharedMailbox') {
                    $c.Facts.MailboxSafe = $true
                    Add-StepNote $c 'Mailbox is already shared.'
                    return
                }

                $upn = $c.User.UserPrincipalName
                Invoke-OffboardingAction $c 'Convert the mailbox to a shared mailbox (keeps all mail, needs no license under 50 GB)' {
                    $c.Provider.ConvertToShared($upn)
                }
                $c.Facts.MailboxSafe = $true
                Add-StepNote $c 'Shared mailboxes over 50 GB, or with an archive or litigation hold, still need an Exchange license.'
            }
        }

        [pscustomobject]@{
            Name     = 'HideFromAddressList'
            Title    = 'Hide from address book'
            Critical = $false
            Script   = {
                param($c)
                if (-not $c.Provider.ExchangeConnected) { Skip-OffboardingStep $c 'Not connected to Exchange Online.'; return }
                if ($null -eq $c.Facts.Mailbox) { Skip-OffboardingStep $c 'User has no mailbox.'; return }
                if ($c.Facts.Mailbox.HiddenFromAddressListsEnabled) { Add-StepNote $c 'Already hidden.'; return }

                $upn = $c.User.UserPrincipalName
                Invoke-OffboardingAction $c 'Hide the mailbox from the Global Address List' { $c.Provider.HideFromAddressList($upn) }
            }
        }

        [pscustomobject]@{
            Name     = 'GrantOneDriveAccess'
            Title    = 'Hand OneDrive to manager'
            Critical = $false
            Script   = {
                param($c)
                if ($null -eq $c.Manager) { Skip-OffboardingStep $c 'No manager set.'; return }
                $drive = $c.Provider.GetOneDrive($c.User.Id)
                if ($null -eq $drive) { Skip-OffboardingStep $c 'User has no OneDrive.'; return }

                $driveId = $drive.Id
                $email = if ($c.Manager.Mail) { $c.Manager.Mail } else { $c.Manager.UserPrincipalName }
                Invoke-OffboardingAction $c "Give $($c.Manager.DisplayName) edit access to the OneDrive and email them the link" {
                    $c.Provider.GrantOneDriveAccess($driveId, $email)
                }
                Add-StepNote $c "OneDrive: $($drive.WebUrl)"
                Add-StepNote $c 'After the account is deleted, OneDrive is kept for the retention period set in the SharePoint admin center (30 days by default).'
            }
        }

        [pscustomobject]@{
            Name     = 'RemoveGroupMemberships'
            Title    = 'Remove group memberships'
            Critical = $false
            Script   = {
                param($c)
                $groups = @($c.Facts.Groups)
                if ($groups.Count -eq 0) { Add-StepNote $c 'Not a member of any groups.'; return }

                # If the mailbox could not be made shared, keep any group that hands out an Exchange license.
                $protectGroups = @()
                if (-not $c.Facts.MailboxSafe) {
                    $protectGroups = @($c.Facts.Licenses | Where-Object IncludesExchange | ForEach-Object { $_.ViaGroupIds })
                }

                $uid = $c.User.Id
                $upn = $c.User.UserPrincipalName
                foreach ($g in $groups) {
                    $gid = $g.Id
                    $name = $g.DisplayName

                    if ($g.GroupTypes -contains 'DynamicMembership') {
                        Add-StepNote $c "Kept '$name': membership is rule-based, so it can't be removed directly. It updates when the user's attributes change."
                        continue
                    }
                    if ($g.OnPremisesSyncEnabled) {
                        Add-StepNote $c "Kept '$name': synced from on-premises AD. Remove the membership in AD."
                        continue
                    }
                    if ($protectGroups -contains $gid) {
                        Add-StepNote $c "Kept '$name': it assigns an Exchange license and the mailbox was not converted to shared."
                        continue
                    }

                    $isExchangeManaged = $g.MailEnabled -and -not ($g.GroupTypes -contains 'Unified')
                    if ($isExchangeManaged) {
                        if (-not $c.Provider.ExchangeConnected) {
                            Add-StepNote $c "Kept '$name': distribution lists and mail-enabled security groups are managed in Exchange Online, which is not connected."
                            continue
                        }
                        $mail = $g.Mail
                        Invoke-OffboardingAction $c "Remove from '$name' (Exchange)" { $c.Provider.RemoveFromDistributionGroup($mail, $upn) }
                        continue
                    }

                    Invoke-OffboardingAction $c "Remove from '$name'" { $c.Provider.RemoveFromGroup($gid, $uid) }
                }
            }
        }

        [pscustomobject]@{
            Name     = 'RemoveLicenses'
            Title    = 'Remove licenses'
            Critical = $false
            Script   = {
                param($c)
                $licenses = @($c.Facts.Licenses)
                if ($licenses.Count -eq 0) { Add-StepNote $c 'No licenses assigned.'; return }

                foreach ($l in $licenses | Where-Object { -not $_.Direct }) {
                    Add-StepNote $c "$($l.SkuPartNumber) comes from a group, so it is removed with the group membership, not here."
                }

                $direct = @($licenses | Where-Object Direct)
                if ($direct.Count -eq 0) { return }

                if (-not $c.Facts.MailboxSafe -and @($direct | Where-Object IncludesExchange).Count -gt 0) {
                    Skip-OffboardingStep $c 'The mailbox was not converted to shared. Removing a license that includes Exchange would start a 30-day countdown to mailbox deletion, so licenses were kept.'
                    return
                }

                $id = $c.User.Id
                $skuIds = @($direct | ForEach-Object { $_.SkuId })
                $names = ($direct | ForEach-Object { $_.SkuPartNumber }) -join ', '
                Invoke-OffboardingAction $c "Remove directly assigned licenses: $names" { $c.Provider.RemoveLicenses($id, $skuIds) }
            }
        }

        [pscustomobject]@{
            Name     = 'DeviceAction'
            Title    = 'Intune device action'
            Critical = $false
            Script   = {
                param($c)
                $devices = @($c.Facts.Devices)
                if ($devices.Count -eq 0) { Add-StepNote $c 'No Intune-managed devices.'; return }

                $mode = $c.Config.DeviceAction
                if ($mode -eq 'None') {
                    foreach ($d in $devices) { Add-StepNote $c "Found $($d.DeviceName) ($($d.OperatingSystem), $($d.OwnerType) device)." }
                    Skip-OffboardingStep $c "DeviceAction is 'None' in the config, so devices are only reported. Collect hardware, then retire or wipe."
                    return
                }

                foreach ($d in $devices) {
                    $did = $d.Id
                    $label = "$($d.DeviceName) ($($d.OperatingSystem), $($d.OwnerType) device)"
                    if ($mode -eq 'Wipe' -and $d.OwnerType -eq 'company') {
                        Invoke-OffboardingAction $c "Wipe ${label}: factory reset" { $c.Provider.WipeDevice($did) }
                    }
                    else {
                        Invoke-OffboardingAction $c "Retire ${label}: removes company apps and data only" { $c.Provider.RetireDevice($did) }
                        if ($mode -eq 'Wipe') { Add-StepNote $c "$($d.DeviceName) is personal, so it was retired instead of wiped." }
                    }
                }
            }
        }
    )
}
