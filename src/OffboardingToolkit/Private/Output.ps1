function ConvertTo-OffboardingHtml {
    <#
    .SYNOPSIS
    Renders a result object as a single self-contained HTML page (no external files),
    suitable for attaching to a ticket or printing to PDF.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)] $Result)

    $enc = { param($s) [System.Net.WebUtility]::HtmlEncode([string]$s) }
    $list = {
        param($items)
        $arr = @($items | Where-Object { $_ })
        if ($arr.Count -eq 0) { return '<span class="muted">None</span>' }
        '<ul>' + (($arr | ForEach-Object { '<li>' + (& $enc $_) + '</li>' }) -join '') + '</ul>'
    }

    $verb = if ($Result.Mode -eq 'DryRun') { 'Would' } else { 'Done' }
    $rows = foreach ($s in $Result.Steps) {
        $actions = if ($s.Actions.Count) {
            '<ul class="actions">' + (($s.Actions | ForEach-Object { "<li><b>$verb</b>: " + (& $enc $_) + '</li>' }) -join '') + '</ul>'
        }
        else { '' }
        $notes = if ($s.Notes.Count) {
            '<ul class="notes">' + (($s.Notes | ForEach-Object { '<li>' + (& $enc $_) + '</li>' }) -join '') + '</ul>'
        }
        else { '' }
        $message = if ($s.Message) { '<p class="msg">' + (& $enc $s.Message) + '</p>' } else { '' }
        @"
<tr>
  <td class="num">$($s.Order)</td>
  <td><strong>$(& $enc $s.Title)</strong><div class="muted small">$(& $enc $s.Name)</div></td>
  <td><span class="badge s-$($s.Status.ToLower())">$(& $enc $s.Status)</span></td>
  <td>$message$actions$notes</td>
  <td class="num muted">$($s.DurationMs) ms</td>
</tr>
"@
    }

    $summary = ($Result.Summary.PSObject.Properties | Where-Object { $_.Value -gt 0 } | ForEach-Object {
            "<span class=`"badge s-$($_.Name.ToLower())`">$($_.Value) $($_.Name)</span>"
        }) -join ' '

    $template = Get-Content -LiteralPath (Join-Path $script:ModuleRoot 'Templates/report.html') -Raw
    $tokens = @{
        '{{TITLE}}'       = & $enc "Offboarding report: $($Result.DisplayName)"
        '{{DISPLAYNAME}}' = & $enc ($(if ($Result.DisplayName) { $Result.DisplayName } else { $Result.UserPrincipalName }))
        '{{UPN}}'         = & $enc $Result.UserPrincipalName
        '{{MANAGER}}'     = & $enc ($(if ($Result.Manager) { $Result.Manager } else { 'Not set' }))
        '{{MODE}}'        = & $enc $Result.Mode
        '{{MODECLASS}}'   = $Result.Mode.ToLower()
        '{{OUTCOME}}'     = & $enc $Result.Outcome
        '{{OUTCOMECLASS}}' = $Result.Outcome.ToLower()
        '{{TENANT}}'      = & $enc $Result.Tenant
        '{{OPERATOR}}'    = & $enc $Result.Operator
        '{{TICKET}}'      = & $enc ($(if ($Result.Ticket) { $Result.Ticket } else { 'None' }))
        '{{STARTED}}'     = & $enc $Result.StartedAt
        '{{COMPLETED}}'   = & $enc $Result.CompletedAt
        '{{RUNID}}'       = & $enc $Result.RunId
        '{{VERSION}}'     = & $enc $Result.ToolVersion
        '{{SUMMARY}}'     = $summary
        '{{ROWS}}'        = ($rows -join "`n")
        '{{B_GROUPS}}'    = & $list (Get-ObjectProperty $Result.Before 'Groups')
        '{{B_LICENSES}}'  = & $list (Get-ObjectProperty $Result.Before 'Licenses')
        '{{B_DEVICES}}'   = & $list (Get-ObjectProperty $Result.Before 'Devices')
        '{{B_MAILBOX}}'   = & $enc (Get-ObjectProperty $Result.Before 'Mailbox' 'Not captured')
        '{{B_ENABLED}}'   = & $enc (Get-ObjectProperty $Result.Before 'AccountEnabled' 'Not captured')
        '{{DRYNOTE}}'     = if ($Result.Mode -eq 'DryRun') { '<div class="banner">Dry run: nothing was changed. This is the plan of what a live run would do.</div>' } else { '' }
    }
    foreach ($k in $tokens.Keys) { $template = $template.Replace($k, [string]$tokens[$k]) }
    $template
}

function Write-OffboardingConsole {
    <#
    .SYNOPSIS
    Prints a short, colored summary for the person running the tool. The full
    detail lives in the returned object and the report files.
    #>
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidUsingWriteHost', '', Justification = 'Interactive, colored summary for the operator. Data is returned on the output stream with -PassThru.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)] $Result)

    $colors = @{
        Passed = 'Green'; Completed = 'Green'; Planned = 'Cyan'; NoChange = 'DarkGray'
        Skipped = 'Yellow'; Failed = 'Red'; Blocked = 'Red'; NotRun = 'DarkGray'
    }
    $verb = if ($Result.Mode -eq 'DryRun') { 'would' } else { 'did' }

    Write-Host ''
    $who = if ($Result.DisplayName) { "$($Result.DisplayName) <$($Result.UserPrincipalName)>" } else { $Result.UserPrincipalName }
    Write-Host "Offboarding $who" -ForegroundColor White
    Write-Host ("  Mode: {0}   Tenant: {1}   Run: {2}" -f $Result.Mode, $Result.Tenant, $Result.RunId) -ForegroundColor DarkGray
    Write-Host ''

    foreach ($s in $Result.Steps) {
        $color = $colors[$s.Status]
        Write-Host ('  {0,-10}' -f $s.Status) -ForegroundColor $color -NoNewline
        Write-Host (' {0}' -f $s.Title)
        foreach ($a in $s.Actions) { Write-Host "             $verb`: $a" -ForegroundColor DarkCyan }
        if ($s.Message) { Write-Host "             $($s.Message)" -ForegroundColor DarkYellow }
    }

    Write-Host ''
    $outcomeColor = switch ($Result.Outcome) { 'Success' { 'Green' } 'DryRun' { 'Cyan' } 'CompletedWithErrors' { 'Yellow' } default { 'Red' } }
    Write-Host "  Outcome: $($Result.Outcome)" -ForegroundColor $outcomeColor
    foreach ($f in @($Result.ReportFiles)) { Write-Host "  Report:  $f" -ForegroundColor DarkGray }
    Write-Host ''
}
