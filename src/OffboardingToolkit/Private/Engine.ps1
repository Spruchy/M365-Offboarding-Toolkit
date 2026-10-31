function Invoke-OffboardingAction {
    <#
    .SYNOPSIS
    The single choke point for every change the toolkit makes. In a dry run the change
    is recorded as planned and NOT executed; in a live run it is executed, then recorded.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] $Context,
        [Parameter(Mandatory)][string] $Description,
        [Parameter(Mandatory)][scriptblock] $Action
    )

    if ($Context.DryRun) {
        $Context.Step.Actions.Add($Description)
        return
    }
    & $Action
    $Context.Step.Actions.Add($Description)
}

function Add-StepNote {
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $Note)
    $Context.Step.Notes.Add($Note)
}

function Skip-OffboardingStep {
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $Reason)
    $Context.Step.Status = 'Skipped'
    $Context.Step.Message = $Reason
}

function Block-Offboarding {
    # Used by preflight checks. Nothing after a blocked step runs.
    param([Parameter(Mandatory)] $Context, [Parameter(Mandatory)][string] $Reason)
    $Context.Step.Status = 'Blocked'
    $Context.Step.Message = $Reason
}

function Invoke-OffboardingEngine {
    <#
    .SYNOPSIS
    Runs every step in order against the connected provider and returns a result
    object that becomes the audit report.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $UserPrincipalName,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Config,
        [Parameter(Mandatory)] $Provider,
        [bool] $DryRun = $true,
        [string] $Ticket,
        [bool] $AllowPrivileged = $false
    )

    $started = Get-Date
    $result = [pscustomobject][ordered]@{
        RunId             = '{0}-{1}' -f $started.ToString('yyyyMMdd-HHmmss'), ([guid]::NewGuid().ToString('N').Substring(0, 6))
        ToolVersion       = $MyInvocation.MyCommand.Module.Version.ToString()
        Mode              = if ($DryRun) { 'DryRun' } else { 'Live' }
        Tenant            = $Provider.Name
        ProviderKind      = $Provider.Kind
        Operator          = $Provider.Operator
        Ticket            = $Ticket
        UserPrincipalName = $UserPrincipalName
        DisplayName       = $null
        Manager           = $null
        StartedAt         = $started.ToUniversalTime().ToString('o')
        CompletedAt       = $null
        Outcome           = $null
        Summary           = $null
        Before            = [ordered]@{}
        Steps             = [System.Collections.Generic.List[object]]::new()
        ReportFiles       = @()
    }

    $ctx = [pscustomobject]@{
        Provider          = $Provider
        Config            = $Config
        DryRun            = $DryRun
        AllowPrivileged   = $AllowPrivileged
        UserPrincipalName = $UserPrincipalName
        User              = $null
        Manager           = $null
        Facts             = @{}
        Result            = $result
        Step              = $null
    }

    $stop = $false
    $order = 0
    foreach ($def in Get-OffboardingStepDefinition) {
        $order++
        $record = [pscustomobject][ordered]@{
            Order      = $order
            Name       = $def.Name
            Title      = $def.Title
            Status     = 'Pending'
            Message    = ''
            Actions    = [System.Collections.Generic.List[string]]::new()
            Notes      = [System.Collections.Generic.List[string]]::new()
            DurationMs = 0
        }
        $result.Steps.Add($record)

        if ($stop) {
            $record.Status = 'NotRun'
            $record.Message = 'Not run because an earlier step stopped the offboarding.'
            continue
        }
        if ($def.Name -ne 'Preflight' -and -not $Config.Steps[$def.Name]) {
            $record.Status = 'Skipped'
            $record.Message = 'Turned off in the config file.'
            continue
        }

        $ctx.Step = $record
        $record.Status = 'Running'
        $timer = [System.Diagnostics.Stopwatch]::StartNew()
        try {
            & $def.Script $ctx
            if ($record.Status -eq 'Running') {
                $record.Status = if ($record.Actions.Count -eq 0) { 'NoChange' } elseif ($DryRun) { 'Planned' } else { 'Completed' }
            }
        }
        catch {
            $record.Status = 'Failed'
            $record.Message = $_.Exception.Message
            if ($def.Critical) { $stop = $true }
        }
        finally {
            $timer.Stop()
            $record.DurationMs = [int]$timer.ElapsedMilliseconds
        }

        if ($record.Status -eq 'Blocked') { $stop = $true }
    }

    $counts = [ordered]@{}
    foreach ($s in 'Passed', 'Completed', 'Planned', 'NoChange', 'Skipped', 'Failed', 'Blocked', 'NotRun') {
        $counts[$s] = @($result.Steps | Where-Object Status -eq $s).Count
    }
    $result.Summary = [pscustomobject]$counts

    $result.Outcome =
    if ($counts.Blocked -gt 0) { 'Blocked' }
    elseif ($counts.NotRun -gt 0) { 'Failed' }
    elseif ($counts.Failed -gt 0) { 'CompletedWithErrors' }
    elseif ($DryRun) { 'DryRun' }
    else { 'Success' }

    $result.CompletedAt = (Get-Date).ToUniversalTime().ToString('o')
    $result
}
