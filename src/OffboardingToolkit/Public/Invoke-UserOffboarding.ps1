function Invoke-UserOffboarding {
    <#
    .SYNOPSIS
    Offboards one or more users: blocks sign-in, signs them out everywhere, resets the
    password, sets an auto-reply, converts the mailbox to shared, hands OneDrive to the
    manager, removes groups and licenses, and optionally retires or wipes devices.

    .DESCRIPTION
    Run with -WhatIf first. A dry run reads the tenant, builds the full plan and writes the
    same report a live run would, but changes nothing.

    Safety rails:
      - Accounts matching ProtectedAccounts in the config are refused.
      - Users holding Entra ID admin roles are refused unless -AllowPrivileged is used.
      - On-premises synced users are refused (they must be disabled in AD).
      - Licenses that include Exchange are kept if the mailbox could not be converted to shared.
      - Devices are only reported unless DeviceAction is set in the config, and personal
        devices are never wiped.

    .PARAMETER UserPrincipalName
    The user to offboard. Accepts pipeline input, including Import-Csv rows with a
    UserPrincipalName column.

    .PARAMETER Ticket
    Optional change or ticket number, recorded in the report.

    .PARAMETER ConfigPath
    JSON config file. Create one with New-OffboardingConfig. Defaults are used if omitted.

    .PARAMETER AllowPrivileged
    Allow offboarding a user who holds admin roles. Their role assignments are not removed.

    .PARAMETER ReportPath
    Folder for the JSON and HTML reports. Overrides ReportPath in the config.

    .PARAMETER NoReport
    Do not write report files.

    .PARAMETER PassThru
    Return the result object (for scripting or bulk runs).

    .PARAMETER Quiet
    Do not print the console summary.

    .EXAMPLE
    Invoke-UserOffboarding -UserPrincipalName jordan.reyes@larkspurlabs.example -WhatIf

    .EXAMPLE
    Invoke-UserOffboarding -UserPrincipalName jordan.reyes@larkspurlabs.example -Ticket CHG-1042 -ConfigPath ./config/offboarding.config.json

    .EXAMPLE
    Import-Csv ./leavers.csv | Invoke-UserOffboarding -Confirm:$false -PassThru | Select-Object UserPrincipalName, Outcome
    #>
    [CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
    param(
        [Parameter(Mandatory, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('UPN', 'Email')]
        [ValidateNotNullOrEmpty()]
        [string] $UserPrincipalName,

        [Parameter(ValueFromPipelineByPropertyName)]
        [string] $Ticket,

        [string] $ConfigPath,

        [switch] $AllowPrivileged,

        [string] $ReportPath,

        [switch] $NoReport,

        [switch] $PassThru,

        [switch] $Quiet
    )

    begin {
        Assert-OffboardingConnection
        $config = Read-OffboardingConfig -Path $ConfigPath
        $outDir = if ($ReportPath) { $ReportPath } else { $config.ReportPath }
    }

    process {
        $dryRun = [bool]$WhatIfPreference
        if (-not $dryRun) {
            $action = 'Offboard user: block sign-in and remove access, groups, licenses and devices as set in the config'
            if (-not $PSCmdlet.ShouldProcess($UserPrincipalName, $action)) { return }
        }

        $engine = @{
            UserPrincipalName = $UserPrincipalName
            Config            = $config
            Provider          = $script:Provider
            DryRun            = $dryRun
            Ticket            = $Ticket
            AllowPrivileged   = [bool]$AllowPrivileged
        }
        $result = Invoke-OffboardingEngine @engine

        if (-not $NoReport) {
            $files = Export-OffboardingReport -Result $result -Path $outDir
            $result.ReportFiles = @($files | ForEach-Object { $_.FullName })
        }

        if (-not $Quiet) { Write-OffboardingConsole -Result $result }
        if ($PassThru) { $result }
    }
}

function Get-OffboardingPlan {
    <#
    .SYNOPSIS
    Shows what Invoke-UserOffboarding would do for a user, as a table, without changing
    anything or writing files.

    .EXAMPLE
    Get-OffboardingPlan jordan.reyes@larkspurlabs.example | Format-Table -Wrap
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromPipelineByPropertyName)]
        [Alias('UPN', 'Email')]
        [string] $UserPrincipalName,

        [string] $ConfigPath,

        [switch] $AllowPrivileged
    )

    begin {
        Assert-OffboardingConnection
        $config = Read-OffboardingConfig -Path $ConfigPath
    }

    process {
        $result = Invoke-OffboardingEngine -UserPrincipalName $UserPrincipalName -Config $config -Provider $script:Provider -DryRun $true -AllowPrivileged ([bool]$AllowPrivileged)
        foreach ($s in $result.Steps) {
            [pscustomobject]@{
                User    = $UserPrincipalName
                Order   = $s.Order
                Step    = $s.Title
                Status  = $s.Status
                Changes = ($s.Actions -join '; ')
                Notes   = (@($s.Message) + @($s.Notes) | Where-Object { $_ }) -join ' '
            }
        }
    }
}

function Export-OffboardingReport {
    <#
    .SYNOPSIS
    Writes a result from Invoke-UserOffboarding -PassThru to JSON and/or HTML.

    .EXAMPLE
    $r = Invoke-UserOffboarding jordan.reyes@larkspurlabs.example -WhatIf -PassThru -NoReport
    Export-OffboardingReport -Result $r -Path ./reports -Format Html
    #>
    [CmdletBinding()]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory, ValueFromPipeline)] $Result,
        [string] $Path = './reports',
        [ValidateSet('Json', 'Html')][string[]] $Format = @('Json', 'Html')
    )

    process {
        # -WhatIf:$false on purpose: a dry run still needs its plan written to disk.
        if (-not (Test-Path -LiteralPath $Path)) { [void](New-Item -ItemType Directory -Path $Path -Force -WhatIf:$false) }

        $safeName = ($Result.UserPrincipalName -replace '[^A-Za-z0-9._-]', '_')
        $base = Join-Path $Path ("{0}_{1}_{2}" -f $Result.RunId, $safeName, $Result.Mode)

        if ('Json' -in $Format) {
            $json = "$base.json"
            $Result | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $json -Encoding utf8 -WhatIf:$false
            Get-Item -LiteralPath $json
        }
        if ('Html' -in $Format) {
            $html = "$base.html"
            ConvertTo-OffboardingHtml -Result $Result | Set-Content -LiteralPath $html -Encoding utf8 -WhatIf:$false
            Get-Item -LiteralPath $html
        }
    }
}

function New-OffboardingConfig {
    <#
    .SYNOPSIS
    Writes a config file with every setting and its default value, ready to edit.

    .EXAMPLE
    New-OffboardingConfig -Path ./config/offboarding.config.json
    #>
    [CmdletBinding(SupportsShouldProcess)]
    [OutputType([System.IO.FileInfo])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [switch] $Force
    )

    if ((Test-Path -LiteralPath $Path) -and -not $Force) {
        throw "$Path already exists. Use -Force to overwrite it."
    }
    if ($PSCmdlet.ShouldProcess($Path, 'Write default offboarding config')) {
        $dir = Split-Path -Path $Path -Parent
        if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir -Force) }
        Get-DefaultOffboardingConfig | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $Path -Encoding utf8
        Get-Item -LiteralPath $Path
    }
}
