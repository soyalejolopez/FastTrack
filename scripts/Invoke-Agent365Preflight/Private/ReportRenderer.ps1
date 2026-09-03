<#
    .SYNOPSIS
        Renders a self-contained, customer-facing HTML report for the Microsoft
        Agent 365 pre-flight checker.

    .DESCRIPTION
        Exposes New-Agent365PreflightHtml, which converts a pre-flight $Report
        object into a single accessible, printable, offline HTML document. The
        renderer has no external dependencies: no remote fonts, CSS, JavaScript,
        images, or other network assets are used. All report-derived text is
        HTML-encoded and all URLs are scheme-validated before emission.

    .NOTES
        THIS CODE IS PROVIDED *AS IS* WITHOUT WARRANTY OF ANY KIND, EITHER
        EXPRESSED OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED
        WARRANTIES OF MERCHANTABILITY AND/OR FITNESS FOR A PARTICULAR PURPOSE.

        Sample scripts are not supported under any Microsoft standard support
        program or service. This module is self-contained and does not depend on
        other repository helpers.

        The generated report is a *technical* pre-flight aid. It is NOT a
        security assessment, audit, or compliance certification.
#>

Set-StrictMode -Version 2.0

#region Private helpers

function Get-A365Member {
    <# Safely read a property/key from a PSObject or dictionary. #>
    [CmdletBinding()]
    param(
        [object]$Object,
        [string]$Name,
        [object]$Default = $null
    )

    if ($null -eq $Object) { return $Default }

    if ($Object -is [System.Collections.IDictionary]) {
        if ($Object.Contains($Name)) {
            $value = $Object[$Name]
            if ($null -eq $value) { return $Default }
            return $value
        }
        return $Default
    }

    $property = $Object.PSObject.Properties[$Name]
    if ($null -ne $property) {
        $value = $property.Value
        if ($null -eq $value) { return $Default }
        return $value
    }

    return $Default
}

function ConvertTo-A365Html {
    <# HTML-encode any value for safe use in element or attribute context. #>
    [CmdletBinding()]
    param([object]$Text)

    if ($null -eq $Text) { return '' }
    return [System.Net.WebUtility]::HtmlEncode([string]$Text)
}

function Get-A365Bool {
    [CmdletBinding()]
    param([object]$Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [bool]) { return $Value }
    $text = ([string]$Value).Trim().ToLowerInvariant()
    return (@('true', 'yes', '1', 'enabled', 'on', 'available', 'ga') -contains $text)
}

function Get-A365SafeUrl {
    <# Return an absolute http/https URL, or $null when unsafe/invalid. #>
    [CmdletBinding()]
    param([object]$Url)

    if ($null -eq $Url) { return $null }
    $text = [string]$Url
    if ([string]::IsNullOrWhiteSpace($text)) { return $null }
    $text = $text.Trim()

    $uri = $null
    if ([System.Uri]::TryCreate($text, [System.UriKind]::Absolute, [ref]$uri)) {
        if ($uri.Scheme -eq 'http' -or $uri.Scheme -eq 'https') {
            return $uri.AbsoluteUri
        }
    }
    return $null
}

function Get-A365Link {
    <# Build a safe anchor; falls back to encoded text when URL is unsafe. #>
    [CmdletBinding()]
    param(
        [object]$Url,
        [string]$Text,
        [string]$Class = 'doc-link'
    )

    $safe = Get-A365SafeUrl $Url
    if ([string]::IsNullOrWhiteSpace($Text)) { $label = $safe } else { $label = $Text }

    if ($null -eq $safe) {
        if ([string]::IsNullOrWhiteSpace($Text)) { return '' }
        return (ConvertTo-A365Html $Text)
    }

    $encUrl = ConvertTo-A365Html $safe
    $encLabel = ConvertTo-A365Html $label
    return ('<a class="' + $Class + '" href="' + $encUrl + '" rel="noopener noreferrer">' + $encLabel + '</a>')
}

function Get-A365Slug {
    [CmdletBinding()]
    param([string]$Text)

    if ([string]::IsNullOrWhiteSpace($Text)) { return 'section' }
    $slug = $Text.ToLowerInvariant()
    $slug = [System.Text.RegularExpressions.Regex]::Replace($slug, '[^a-z0-9]+', '-')
    $slug = $slug.Trim('-')
    if ([string]::IsNullOrWhiteSpace($slug)) { return 'section' }
    return $slug
}

function Join-A365List {
    [CmdletBinding()]
    param(
        [object]$List,
        [string]$Separator = ', '
    )

    if ($null -eq $List) { return '' }
    if ($List -is [string]) { return $List }

    if ($List -is [System.Collections.IEnumerable]) {
        $items = @($List | ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
        return ($items -join $Separator)
    }
    return [string]$List
}

function Format-A365Date {
    [CmdletBinding()]
    param([object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return ($Value.ToUniversalTime().ToString('yyyy-MM-dd HH:mm:ss') + ' UTC') }

    $text = [string]$Value
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }

    $parsed = [datetime]::MinValue
    $styles = [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, $styles, [ref]$parsed)) {
        return ($parsed.ToString('yyyy-MM-dd HH:mm:ss') + ' UTC')
    }
    return $text
}

function Format-A365ReviewDate {
    <#
        Render a guidance ReviewDate as a calendar date only (yyyy-MM-dd). A review
        date carries no meaningful time-of-day, and ConvertFrom-Json coerces a bare
        "yyyy-MM-dd" string into a midnight [datetime]; formatting it through the
        general timestamp helper would surface a spurious "00:00:00 UTC". The date is
        rendered as-is with no timezone conversion so the calendar day never shifts.
    #>
    [CmdletBinding()]
    param([object]$Value)

    if ($null -eq $Value) { return '' }
    if ($Value -is [datetime]) { return $Value.ToString('yyyy-MM-dd') }

    $text = ([string]$Value).Trim()
    if ([string]::IsNullOrWhiteSpace($text)) { return '' }
    if ($text -match '^\d{4}-\d{2}-\d{2}') { return $text.Substring(0, 10) }

    $parsed = [datetime]::MinValue
    if ([datetime]::TryParse($text, [System.Globalization.CultureInfo]::InvariantCulture, [System.Globalization.DateTimeStyles]::None, [ref]$parsed)) {
        return $parsed.ToString('yyyy-MM-dd')
    }
    return $text
}

function Get-A365StatusMeta {
    [CmdletBinding()]
    param([string]$Status)

    switch ($Status) {
        'Passed'           { return @{ Label = 'Passed';            Class = 's-pass';     Glyph = [char]0x2713 } }
        'Blocker'          { return @{ Label = 'Blocker';           Class = 's-block';    Glyph = [char]0x2715 } }
        'ActionRequired'   { return @{ Label = 'Action required';   Class = 's-action';   Glyph = '!' } }
        'Advisory'         { return @{ Label = 'Advisory';          Class = 's-advisory'; Glyph = 'i' } }
        'ManualValidation' { return @{ Label = 'Manual validation'; Class = 's-manual';   Glyph = '?' } }
        'NotApplicable'    { return @{ Label = 'Not applicable';    Class = 's-na';       Glyph = [char]0x2013 } }
        'NotAuthorized'    { return @{ Label = 'Not authorized';    Class = 's-noauth';   Glyph = [char]0x00D8 } }
        'Error'            { return @{ Label = 'Error';             Class = 's-error';    Glyph = '!' } }
        default {
            if ([string]::IsNullOrWhiteSpace($Status)) { $label = 'Unknown' } else { $label = $Status }
            return @{ Label = $label; Class = 's-unknown'; Glyph = [char]0x2022 }
        }
    }
}

function Get-A365VerdictMeta {
    [CmdletBinding()]
    param([string]$Label)

    switch -Regex ($Label) {
        'Ready for pilot'               { return @{ Class = 'v-ready';      Glyph = [char]0x2713 } }
        'Blocked'                       { return @{ Class = 'v-blocked';    Glyph = [char]0x2715 } }
        'Incomplete'                    { return @{ Class = 'v-incomplete'; Glyph = '!' } }
        'Technical pre-?flight'         { return @{ Class = 'v-complete';   Glyph = [char]0x2713 } }
        default                         { return @{ Class = 'v-neutral';    Glyph = [char]0x2022 } }
    }
}

function Get-A365StatusPill {
    [CmdletBinding()]
    param([string]$Status)

    $meta = Get-A365StatusMeta $Status
    return ('<span class="pill ' + $meta.Class + '"><span class="pill-glyph" aria-hidden="true">' +
        (ConvertTo-A365Html $meta.Glyph) + '</span><span class="pill-label">' +
        (ConvertTo-A365Html $meta.Label) + '</span></span>')
}

function Format-A365Details {
    <# Recursively render arbitrary detail objects as encoded nested markup. #>
    [CmdletBinding()]
    param(
        [object]$Value,
        [int]$Depth = 0
    )

    if ($null -eq $Value) { return '' }
    if ($Depth -gt 4) { return (ConvertTo-A365Html ([string]$Value)) }

    if ($Value -is [string] -or $Value -is [bool] -or $Value -is [datetime] -or $Value -is [ValueType]) {
        if ($Value -is [datetime]) { return (ConvertTo-A365Html (Format-A365Date $Value)) }
        return (ConvertTo-A365Html ([string]$Value))
    }

    if ($Value -is [System.Collections.IDictionary]) {
        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append('<dl class="kv">')
        foreach ($key in $Value.Keys) {
            [void]$builder.Append('<dt>' + (ConvertTo-A365Html ([string]$key)) + '</dt><dd>' +
                (Format-A365Details -Value $Value[$key] -Depth ($Depth + 1)) + '</dd>')
        }
        [void]$builder.Append('</dl>')
        return $builder.ToString()
    }

    if ($Value -is [System.Collections.IEnumerable]) {
        $items = @($Value)
        if ($items.Count -eq 0) { return '<span class="muted">(none)</span>' }
        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append('<ul class="detail-list">')
        foreach ($item in $items) {
            [void]$builder.Append('<li>' + (Format-A365Details -Value $item -Depth ($Depth + 1)) + '</li>')
        }
        [void]$builder.Append('</ul>')
        return $builder.ToString()
    }

    $props = @($Value.PSObject.Properties)
    if ($props.Count -gt 0) {
        $builder = [System.Text.StringBuilder]::new()
        [void]$builder.Append('<dl class="kv">')
        foreach ($prop in $props) {
            [void]$builder.Append('<dt>' + (ConvertTo-A365Html $prop.Name) + '</dt><dd>' +
                (Format-A365Details -Value $prop.Value -Depth ($Depth + 1)) + '</dd>')
        }
        [void]$builder.Append('</dl>')
        return $builder.ToString()
    }

    return (ConvertTo-A365Html ([string]$Value))
}

function Get-A365Int {
    [CmdletBinding()]
    param([object]$Value, [int]$Default = 0)

    if ($null -eq $Value) { return $Default }
    if ($Value -is [int]) { return $Value }
    $n = 0
    if ([int]::TryParse([string]$Value, [ref]$n)) { return $n }
    return $Default
}

function Get-A365SeverityRank {
    <# Lower rank == higher priority in the Path to Ready. #>
    [CmdletBinding()]
    param([string]$Status)

    switch ($Status) {
        'Blocker'          { return 1 }
        'NotAuthorized'    { return 2 }
        'Error'            { return 2 }
        'ActionRequired'   { return 3 }
        'ManualValidation' { return 4 }
        'Advisory'         { return 5 }
        default            { return 6 }
    }
}

function Get-A365ReportKey {
    <# Deterministic, non-sensitive key for scoping local browser progress. #>
    [CmdletBinding()]
    param([string]$Seed)

    if ([string]::IsNullOrWhiteSpace($Seed)) { return 'default' }
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($Seed)
        $sha = [System.Security.Cryptography.SHA1]::Create()
        try { $hash = $sha.ComputeHash($bytes) } finally { $sha.Dispose() }
        return (-join ($hash[0..7] | ForEach-Object { $_.ToString('x2') }))
    } catch {
        return 'default'
    }
}

function New-A365PathItem {
    <# Normalize an explicit PathToReady item or a raw result into a path row. #>
    [CmdletBinding()]
    param(
        [object]$Source,
        [hashtable]$SlugById,
        [bool]$Explicit
    )

    $id = [string](Get-A365Member $Source 'Id' '')
    $status = [string](Get-A365Member $Source 'Status' '')
    $title = [string](Get-A365Member $Source 'Title' $id)
    if ([string]::IsNullOrWhiteSpace($title)) { $title = 'Untitled action' }

    if ($Explicit) {
        $owner = [string](Get-A365Member $Source 'OwnerRole' '')
        $evidence = [string](Get-A365Member $Source 'EvidenceNeeded' '')
        $changeType = [string](Get-A365Member $Source 'ChangeType' '')
    } else {
        $owner = [string](Get-A365Member $Source 'RequiredRole' '')
        $evidence = ''
        if ($status -eq 'ManualValidation') { $evidence = [string](Get-A365Member $Source 'Expected' '') }
        $changeType = ''
    }

    $cardId = $null
    $hasCard = $false
    if ($id -and $SlugById -and $SlugById.ContainsKey($id)) {
        $cardId = $SlugById[$id]
        $hasCard = $true
    }

    return @{
        Id                 = $id
        Title              = $title
        Status             = $status
        Rank               = (Get-A365SeverityRank $status)
        PriorityNum        = (Get-A365Int (Get-A365Member $Source 'Priority' 2147483647) 2147483647)
        Owner              = $owner
        RequiredPermission = [string](Get-A365Member $Source 'RequiredPermission' '')
        Remediation        = [string](Get-A365Member $Source 'Remediation' '')
        EvidenceNeeded     = $evidence
        DocsUrl            = (Get-A365Member $Source 'DocsUrl')
        Phase              = [string](Get-A365Member $Source 'Phase' '')
        ChangeType         = $changeType
        CardId             = $cardId
        HasCard            = $hasCard
    }
}

function Get-A365PhaseMeta {
    [CmdletBinding()]
    param([int]$Rank)

    switch ($Rank) {
        1 { return @{ Id = 'unblock';   Title = 'Resolve blockers';          Description = 'Must be fixed before a pilot can proceed.' } }
        2 { return @{ Id = 'authorize'; Title = 'Restore authorization';     Description = 'Grant the missing consent or role, then re-run to collect the evidence.' } }
        3 { return @{ Id = 'action';    Title = 'Complete required actions';  Description = 'Required before the technical pass criteria are met.' } }
        4 { return @{ Id = 'manual';    Title = 'Confirm manual validations'; Description = 'Needs a person to confirm and attest.' } }
        default { return @{ Id = 'advisory'; Title = 'Review advisories'; Description = 'Recommended, but not required to pass.' } }
    }
}

function Build-A365SeverityPhases {
    [CmdletBinding()]
    param([object[]]$Items)

    $phases = [System.Collections.Generic.List[object]]::new()
    foreach ($rank in 1, 2, 3, 4, 5) {
        $bucket = @($Items | Where-Object { $_.Rank -eq $rank })
        if ($bucket.Count -eq 0) { continue }
        $meta = Get-A365PhaseMeta $rank
        $sorted = @($bucket | Sort-Object -Property @{ Expression = { $_.PriorityNum } }, @{ Expression = { [string]$_.Title } })
        [void]$phases.Add(@{ Id = $meta.Id; Title = $meta.Title; Description = $meta.Description; Items = $sorted })
    }
    return @($phases.ToArray())
}

function Get-A365PathModel {
    <#
        Build an ordered list of Path-to-Ready phases. Prefers the backend
        PathToReady contract when present; otherwise derives phases from the
        actionable results so backward reports still render a path.
    #>
    [CmdletBinding()]
    param(
        [object]$Report,
        [object[]]$Results,
        [hashtable]$SlugById
    )

    $explicit = Get-A365Member $Report 'PathToReady'
    if ($null -ne $explicit) {
        $items = @(Get-A365Member $explicit 'Items' @())
        if ($items.Count -gt 0) {
            $norm = @()
            foreach ($it in $items) { $norm += (New-A365PathItem -Source $it -SlugById $SlugById -Explicit $true) }

            $phaseDefs = @(Get-A365Member $explicit 'Phases' @())
            if ($phaseDefs.Count -gt 0) {
                $phases = [System.Collections.Generic.List[object]]::new()
                $known = @()
                foreach ($pd in $phaseDefs) {
                    $phaseId = [string](Get-A365Member $pd 'Id' '')
                    $known += $phaseId
                    $pitems = @($norm | Where-Object { $_.Phase -eq $phaseId } |
                        Sort-Object -Property @{ Expression = { $_.Rank } }, @{ Expression = { $_.PriorityNum } })
                    if ($pitems.Count -eq 0) { continue }
                    [void]$phases.Add(@{
                        Id          = $phaseId
                        Title       = [string](Get-A365Member $pd 'Title' $phaseId)
                        Description = [string](Get-A365Member $pd 'Description' '')
                        Items       = $pitems
                    })
                }
                $orphans = @($norm | Where-Object { $known -notcontains $_.Phase } |
                    Sort-Object -Property @{ Expression = { $_.Rank } }, @{ Expression = { $_.PriorityNum } })
                if ($orphans.Count -gt 0) {
                    [void]$phases.Add(@{ Id = 'additional'; Title = 'Additional actions'; Description = ''; Items = $orphans })
                }
                return @($phases.ToArray())
            }

            return (Build-A365SeverityPhases -Items $norm)
        }
    }

    $statuses = @('Blocker', 'NotAuthorized', 'Error', 'ActionRequired', 'ManualValidation', 'Advisory')
    $actionable = @($Results | Where-Object { $statuses -contains [string](Get-A365Member $_ 'Status' '') })
    $norm = @()
    foreach ($r in $actionable) { $norm += (New-A365PathItem -Source $r -SlugById $SlugById -Explicit $false) }
    return (Build-A365SeverityPhases -Items $norm)
}

function Get-A365PassModel {
    <# Normalize PassCriteria, deriving from results when the backend field is absent. #>
    [CmdletBinding()]
    param(
        [object]$Report,
        [object]$Verdict,
        [object[]]$Results
    )

    $pc = Get-A365Member $Report 'PassCriteria'
    if ($null -ne $pc) {
        $b = Get-A365Int (Get-A365Member $pc 'BlockerCount' 0)
        $a = Get-A365Int (Get-A365Member $pc 'ActionRequiredCount' 0)
        $na = Get-A365Int (Get-A365Member $pc 'NotAuthorizedCount' 0)
        $er = Get-A365Int (Get-A365Member $pc 'ErrorCount' 0)
        $mm = Get-A365Int (Get-A365Member $pc 'RequiredManualUnresolvedCount' 0)
        $isSatMember = Get-A365Member $pc 'IsSatisfied'
        if ($null -ne $isSatMember) { $sat = (Get-A365Bool $isSatMember) } else { $sat = (($b + $a + $na + $er + $mm) -eq 0) }
        return @{
            BlockerCount                  = $b
            ActionRequiredCount           = $a
            NotAuthorizedCount            = $na
            ErrorCount                    = $er
            RequiredManualUnresolvedCount = $mm
            IsSatisfied                   = $sat
            Summary                       = [string](Get-A365Member $pc 'Summary' '')
            Source                        = 'report'
        }
    }

    $b = 0; $a = 0; $na = 0; $er = 0; $mm = 0
    foreach ($r in $Results) {
        switch ([string](Get-A365Member $r 'Status' '')) {
            'Blocker'        { $b++ }
            'ActionRequired' { $a++ }
            'NotAuthorized'  { $na++ }
            'Error'          { $er++ }
            'ManualValidation' {
                $applied = Get-A365Bool (Get-A365Member (Get-A365Member $r 'Attestation') 'Applied')
                if (-not $applied) { $mm++ }
            }
        }
    }
    if (@($Results).Count -eq 0 -and $null -ne $Verdict) {
        $b = Get-A365Int (Get-A365Member $Verdict 'BlockerCount' 0)
        $a = Get-A365Int (Get-A365Member $Verdict 'ActionRequiredCount' 0)
    }
    return @{
        BlockerCount                  = $b
        ActionRequiredCount           = $a
        NotAuthorizedCount            = $na
        ErrorCount                    = $er
        RequiredManualUnresolvedCount = $mm
        IsSatisfied                   = (($b + $a + $na + $er + $mm) -eq 0)
        Summary                       = ''
        Source                        = 'derived'
    }
}

function Get-A365RerunModel {
    <#
        Normalize the Rerun contract. In sanitized mode only the sanitized
        command is surfaced and tenant/path fields are withheld, so no
        environment identifiers can leak from a full report rendered sanitized.
    #>
    [CmdletBinding()]
    param([object]$Report, [bool]$IsSanitized)

    $rr = Get-A365Member $Report 'Rerun'
    if ($null -eq $rr) { return @{ HasCommand = $false; ShowMeta = $false } }

    if ($IsSanitized) {
        $cmd = [string](Get-A365Member $rr 'SanitizedCommand' '')
        return @{
            HasCommand = -not [string]::IsNullOrWhiteSpace($cmd)
            Command    = $cmd
            ShowMeta   = $false
            Stage      = [string](Get-A365Member $rr 'Stage' '')
        }
    }

    $cmd = [string](Get-A365Member $rr 'Command' '')
    return @{
        HasCommand   = -not [string]::IsNullOrWhiteSpace($cmd)
        Command      = $cmd
        ShowMeta     = $true
        TenantTarget = [string](Get-A365Member $rr 'TenantTarget' '')
        OutputPath   = [string](Get-A365Member $rr 'OutputPath' '')
        AnswersPath  = [string](Get-A365Member $rr 'AnswersPath' '')
        Stage        = [string](Get-A365Member $rr 'Stage' '')
        UseDeviceCode = (Get-A365Bool (Get-A365Member $rr 'UseDeviceCode'))
    }
}

function Get-A365GuidanceModel {
    <#
        Normalize a canonical structured Guidance object (attached to a gate or a
        Result's AttestationDefinition in the 1.3 model). Returns $null when no
        usable guidance is present so older reports degrade to the existing
        evidence text and documentation link.
    #>
    [CmdletBinding()]
    param([object]$Guidance)

    if ($null -eq $Guidance) { return $null }

    $intent = [string](Get-A365Member $Guidance 'Intent' '')
    $why    = [string](Get-A365Member $Guidance 'WhyItMatters' '')
    $who    = [string](Get-A365Member $Guidance 'WhoShouldAnswer' '')
    $noRem  = [string](Get-A365Member $Guidance 'NoRemediation' '')
    $naText = [string](Get-A365Member $Guidance 'NotApplicableGuidance' '')
    $search = [string](Get-A365Member $Guidance 'SearchText' '')
    $review = Get-A365Member $Guidance 'ReviewDate'

    $yes = @(@(Get-A365Member $Guidance 'YesCriteria' @()) |
        ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    $evidence = @(@(Get-A365Member $Guidance 'EvidenceToRetain' @()) |
        ForEach-Object { [string]$_ } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    $steps = @()
    foreach ($vs in @(Get-A365Member $Guidance 'VerificationSteps' @())) {
        if ($null -eq $vs) { continue }
        $steps += @{
            Order       = (Get-A365Int (Get-A365Member $vs 'Order' 0) 0)
            Title       = [string](Get-A365Member $vs 'Title' '')
            Instruction = [string](Get-A365Member $vs 'Instruction' '')
            Location    = [string](Get-A365Member $vs 'Location' '')
        }
    }
    $steps = @($steps | Sort-Object -Property @{ Expression = { $_.Order } })

    $sources = @()
    foreach ($ps in @(Get-A365Member $Guidance 'PublicSources' @())) {
        if ($null -eq $ps) { continue }
        $url = [string](Get-A365Member $ps 'Url' '')
        if ([string]::IsNullOrWhiteSpace($url)) { continue }
        $title = [string](Get-A365Member $ps 'Title' '')
        $sources += @{ Title = $(if ($title) { $title } else { $url }); Url = $url }
    }

    $hasContent = $intent -or $why -or $who -or $noRem -or $naText -or
        ($yes.Count -gt 0) -or ($evidence.Count -gt 0) -or ($steps.Count -gt 0) -or ($sources.Count -gt 0)
    if (-not $hasContent) { return $null }

    return @{
        Intent                = $intent
        WhyItMatters          = $why
        WhoShouldAnswer       = $who
        YesCriteria           = @($yes)
        EvidenceToRetain      = @($evidence)
        VerificationSteps     = @($steps)
        NoRemediation         = $noRem
        NotApplicableGuidance = $naText
        PublicSources         = @($sources)
        ReviewDate            = $review
        SearchText            = $search
    }
}

function Get-A365GateGuidance {
    <#
        Resolve the canonical Guidance for a gate or result. Prefers the object's
        own Guidance, then its AttestationDefinition.Guidance, then falls back to
        the matching Result's AttestationDefinition.Guidance. Any missing hop is
        tolerated so old reports never throw.
    #>
    [CmdletBinding()]
    param([object]$Gate, [object]$Result)

    $g = Get-A365Member $Gate 'Guidance'
    if ($null -eq $g) {
        $def = Get-A365Member $Gate 'AttestationDefinition'
        if ($null -ne $def) { $g = Get-A365Member $def 'Guidance' }
    }
    if ($null -eq $g -and $null -ne $Result) {
        $rdef = Get-A365Member $Result 'AttestationDefinition'
        if ($null -ne $rdef) { $g = Get-A365Member $rdef 'Guidance' }
        if ($null -eq $g) { $g = Get-A365Member $Result 'Guidance' }
    }
    return (Get-A365GuidanceModel $g)
}

function Format-A365GuidanceSections {
    <#
        Emit the progressive answer-guidance sections as a list of raw HTML lines
        (already encoded). This is the single source of truth cloned into the
        guidance dialog by JS, printed inline, and shown when JS is unavailable.
        Sections render only when their canonical content is present; the N/A rule
        always renders so the reader learns whether "Not applicable" is permitted.
    #>
    [CmdletBinding()]
    param(
        [object]$Guidance,
        [bool]$AllowNa,
        [string]$Observed = '',
        [bool]$ObservedRedacted = $false,
        [string]$EvidenceNeeded = '',
        [object]$DocsUrl = $null
    )

    $out = [System.Collections.Generic.List[string]]::new()

    # Requirement 4: current collected observation, clearly secondary and never a substitute for criteria.
    if ($ObservedRedacted) {
        [void]$out.Add('<div class="g-observed" data-guidance-observed><p class="g-observed-label">What the scan observed</p><p class="g-observed-value muted">[redacted in sanitized report]</p><p class="g-observed-note">Context only &mdash; it does not replace the acceptance criteria below.</p></div>')
    } elseif (-not [string]::IsNullOrWhiteSpace($Observed)) {
        [void]$out.Add('<div class="g-observed" data-guidance-observed><p class="g-observed-label">What the scan observed</p><p class="g-observed-value">' + (ConvertTo-A365Html $Observed) + '</p><p class="g-observed-note">Context only &mdash; it does not replace the acceptance criteria below.</p></div>')
    }

    if ($null -eq $Guidance) {
        $frag = ''
        if (-not [string]::IsNullOrWhiteSpace($EvidenceNeeded)) {
            $frag += '<p>' + (ConvertTo-A365Html $EvidenceNeeded) + '</p>'
        }
        $noteDoc = Get-A365Link $DocsUrl 'Documentation' 'source-link'
        if ($noteDoc) { $frag += '<p class="small">' + $noteDoc + '</p>' }
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">Manual evidence guidance</h4><p class="muted">Structured answer guidance is not available in this report. Confirm the evidence needed above and consult the linked documentation before answering.</p>' + $frag + '</section>')
        # Requirement 3 (item 8): the N/A rule is always communicated.
        if ($AllowNa) {
            [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">When Not applicable is valid</h4><p>Mark this gate <strong>Not applicable</strong> only when it genuinely does not apply to this tenant, and record a justification.</p></section>')
        } else {
            [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">When Not applicable is valid</h4><p><strong>Explicit &ldquo;Not applicable&rdquo; is not allowed for this gate.</strong> It must be confirmed Yes or answered No.</p></section>')
        }
        return $out.ToArray()
    }

    # 1. What you are confirming
    if (-not [string]::IsNullOrWhiteSpace($Guidance.Intent)) {
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">What you are confirming</h4><p>' + (ConvertTo-A365Html $Guidance.Intent) + '</p></section>')
    }
    # 2. Why this matters
    if (-not [string]::IsNullOrWhiteSpace($Guidance.WhyItMatters)) {
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">Why this matters</h4><p>' + (ConvertTo-A365Html $Guidance.WhyItMatters) + '</p></section>')
    }
    # 3. Who should confirm it
    if (-not [string]::IsNullOrWhiteSpace($Guidance.WhoShouldAnswer)) {
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">Who should confirm it</h4><p>' + (ConvertTo-A365Html $Guidance.WhoShouldAnswer) + '</p></section>')
    }
    # 4. Answer Yes when (acceptance criteria checklist)
    if (@($Guidance.YesCriteria).Count -gt 0) {
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">Answer Yes when</h4><ul class="g-check g-check-yes">')
        foreach ($c in $Guidance.YesCriteria) {
            [void]$out.Add('<li data-guidance-yes-item>' + (ConvertTo-A365Html ([string]$c)) + '</li>')
        }
        [void]$out.Add('</ul></section>')
    }
    # 5. Evidence to retain checklist
    if (@($Guidance.EvidenceToRetain).Count -gt 0) {
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">Evidence to retain</h4><ul class="g-check g-check-evidence">')
        foreach ($e in $Guidance.EvidenceToRetain) {
            [void]$out.Add('<li data-guidance-evidence-item>' + (ConvertTo-A365Html ([string]$e)) + '</li>')
        }
        [void]$out.Add('</ul></section>')
    }
    # 6. How to verify (ordered steps with portal/process locations)
    if (@($Guidance.VerificationSteps).Count -gt 0) {
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">How to verify</h4><ol class="g-steps">')
        $stepNum = 0
        foreach ($st in $Guidance.VerificationSteps) {
            $stepNum++
            $stTitle = [string]$st.Title
            if ([string]::IsNullOrWhiteSpace($stTitle)) { $stTitle = 'Step ' + $stepNum }
            $stLoc = [string]$st.Location
            $stInstr = [string]$st.Instruction
            $locHtml = if (-not [string]::IsNullOrWhiteSpace($stLoc)) { '<span class="g-step-loc">' + (ConvertTo-A365Html $stLoc) + '</span>' } else { '' }
            $instrHtml = if (-not [string]::IsNullOrWhiteSpace($stInstr)) { '<p class="g-step-instr">' + (ConvertTo-A365Html $stInstr) + '</p>' } else { '' }
            [void]$out.Add('<li><div class="g-step-head"><span class="g-step-title">' + (ConvertTo-A365Html $stTitle) + '</span>' + $locHtml + '</div>' + $instrHtml + '</li>')
        }
        [void]$out.Add('</ol></section>')
    }
    # 7. If the answer is No
    if (-not [string]::IsNullOrWhiteSpace($Guidance.NoRemediation)) {
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">If the answer is No</h4><p>' + (ConvertTo-A365Html $Guidance.NoRemediation) + '</p></section>')
    }
    # 8. When Not applicable is valid (only when permitted; otherwise explicit N/A is disallowed)
    if ($AllowNa) {
        $naBody = if (-not [string]::IsNullOrWhiteSpace($Guidance.NotApplicableGuidance)) {
            '<p>' + (ConvertTo-A365Html $Guidance.NotApplicableGuidance) + '</p>'
        } else {
            '<p>Mark this gate <strong>Not applicable</strong> only when it genuinely does not apply to this tenant, and record a justification.</p>'
        }
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">When Not applicable is valid</h4>' + $naBody + '</section>')
    } else {
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">When Not applicable is valid</h4><p><strong>Explicit &ldquo;Not applicable&rdquo; is not allowed for this gate.</strong> It must be confirmed Yes or answered No.</p></section>')
    }
    # 9. Public sources
    if (@($Guidance.PublicSources).Count -gt 0) {
        [void]$out.Add('<section class="g-sec"><h4 class="g-sec-title">Public sources</h4><ul class="g-sources">')
        foreach ($src in $Guidance.PublicSources) {
            $srcLink = Get-A365Link $src.Url $src.Title 'source-link'
            if ($srcLink) { [void]$out.Add('<li>' + $srcLink + '</li>') }
        }
        [void]$out.Add('</ul></section>')
    }
    # 10. Reviewed date
    $reviewText = Format-A365ReviewDate $Guidance.ReviewDate
    if (-not [string]::IsNullOrWhiteSpace($reviewText)) {
        [void]$out.Add('<p class="g-review">Guidance reviewed ' + (ConvertTo-A365Html $reviewText) + '.</p>')
    }

    return $out.ToArray()
}

function Get-A365GateModel {
    <#
        Normalize ManuallyAttestableGates, deriving from ManualAttestations if
        absent. Also resolves the owning role, no-answer status, current status,
        the current collected observation, and the canonical structured Guidance
        (1.3+) with graceful fallback to the matching Result so older reports
        still render without the guidance surface.
    #>
    [CmdletBinding()]
    param([object]$Report, [object[]]$Attestations, [object[]]$Results)

    $resultById = @{}
    foreach ($rr in @($Results)) {
        $rk = [string](Get-A365Member $rr 'Id' '')
        if ($rk -and -not $resultById.ContainsKey($rk)) { $resultById[$rk] = $rr }
    }

    $gates = @(Get-A365Member $Report 'ManuallyAttestableGates' @())
    if ($gates.Count -gt 0) {
        return @($gates | ForEach-Object {
            $gid = [string](Get-A365Member $_ 'Id' '')
            $match = $null
            if ($gid -and $resultById.ContainsKey($gid)) { $match = $resultById[$gid] }
            $obs = ''
            $sens = $false
            $matchStatus = ''
            $matchRole = ''
            if ($null -ne $match) {
                $obs = [string](Get-A365Member $match 'Observed' '')
                $sens = Get-A365Bool (Get-A365Member $match 'IsSensitive')
                $matchStatus = [string](Get-A365Member $match 'Status' '')
                $matchRole = [string](Get-A365Member $match 'RequiredRole' '')
            }
            @{
                Id                 = $gid
                Title              = [string](Get-A365Member $_ 'Title' (Get-A365Member $_ 'Id' ''))
                Required           = (Get-A365Bool (Get-A365Member $_ 'Required'))
                AllowNotApplicable = (Get-A365Bool (Get-A365Member $_ 'AllowNotApplicable'))
                EvidenceNeeded     = [string](Get-A365Member $_ 'EvidenceNeeded' '')
                DocsUrl            = (Get-A365Member $_ 'DocsUrl')
                NoStatus           = [string](Get-A365Member $_ 'NoStatus' '')
                Status             = [string](Get-A365Member $_ 'Status' $matchStatus)
                RequiredRole       = [string](Get-A365Member $_ 'RequiredRole' $matchRole)
                Observed           = $obs
                IsSensitive        = $sens
                Guidance           = (Get-A365GateGuidance $_ $match)
            }
        })
    }

    return @($Attestations | ForEach-Object {
        $gid = [string](Get-A365Member $_ 'Id' '')
        $match = $null
        if ($gid -and $resultById.ContainsKey($gid)) { $match = $resultById[$gid] }
        $obs = ''
        $sens = $false
        $matchStatus = ''
        $matchRole = ''
        if ($null -ne $match) {
            $obs = [string](Get-A365Member $match 'Observed' '')
            $sens = Get-A365Bool (Get-A365Member $match 'IsSensitive')
            $matchStatus = [string](Get-A365Member $match 'Status' '')
            $matchRole = [string](Get-A365Member $match 'RequiredRole' '')
        }
        @{
            Id                 = $gid
            Title              = [string](Get-A365Member $_ 'Question' (Get-A365Member $_ 'Id' ''))
            Required           = (Get-A365Bool (Get-A365Member $_ 'Required'))
            AllowNotApplicable = $false
            EvidenceNeeded     = [string](Get-A365Member $_ 'EvidenceReference' '')
            DocsUrl            = $null
            NoStatus           = [string](Get-A365Member $_ 'NoStatus' '')
            Status             = [string](Get-A365Member $_ 'Status' $matchStatus)
            RequiredRole       = [string](Get-A365Member $_ 'RequiredRole' $matchRole)
            Observed           = $obs
            IsSensitive        = $sens
            Guidance           = (Get-A365GateGuidance $_ $match)
        }
    })
}

#endregion Private helpers
#region Static assets

function Get-A365Css {
    $css = @'
:root {
  color-scheme: light dark;
  --font-sans: "Segoe UI Variable Text", "Segoe UI Variable", "Segoe UI", "Aptos", -apple-system, BlinkMacSystemFont, system-ui, "Helvetica Neue", Arial, sans-serif;
  --font-display: "Segoe UI Variable Display", "Segoe UI Variable", "Segoe UI", "Aptos", -apple-system, system-ui, sans-serif;
  --font-mono: "Cascadia Code", "Cascadia Mono", ui-monospace, "SFMono-Regular", "Consolas", "Liberation Mono", Menlo, monospace;

  --bg: #faf9f8;
  --bg-elevated: #ffffff;
  --bg-sunken: #f3f2f1;
  --surface-border: #e1dfdd;
  --surface-border-strong: #c8c6c4;
  --text: #201f1e;
  --text-secondary: #484644;
  --text-muted: #605e5c;
  --brand: #0078d4;
  --brand-strong: #005a9e;
  --link: #0067b8;
  --focus: #0067b8;

  --pass: #0e6a0e;
  --pass-bg: #dff6dd;
  --block: #a4262c;
  --block-bg: #fde7e9;
  --action: #8a6d00;
  --action-bg: #fff4ce;
  --advisory: #0067b8;
  --advisory-bg: #eff6fc;
  --manual: #605e5c;
  --manual-bg: #f3f2f1;
  --neutral: #605e5c;
  --neutral-bg: #f3f2f1;

  --shadow-sm: 0 1px 2px rgba(0,0,0,.10), 0 0 1px rgba(0,0,0,.10);
  --shadow-md: 0 2px 8px rgba(0,0,0,.10), 0 1px 2px rgba(0,0,0,.06);
  --radius: 8px;
  --radius-lg: 12px;
  --maxw: 1160px;
}

@media (prefers-color-scheme: dark) {
  :root:not([data-theme="light"]) {
    --bg: #1b1a19;
    --bg-elevated: #252423;
    --bg-sunken: #201f1e;
    --surface-border: #3b3a39;
    --surface-border-strong: #484644;
    --text: #f3f2f1;
    --text-secondary: #d2d0ce;
    --text-muted: #a19f9d;
    --brand: #60cdff;
    --brand-strong: #99ebff;
    --link: #60cdff;
    --focus: #60cdff;
    --pass: #6ccb5f;
    --pass-bg: #143b10;
    --block: #f1707b;
    --block-bg: #442726;
    --action: #ffd966;
    --action-bg: #433a13;
    --advisory: #60cdff;
    --advisory-bg: #14313d;
    --manual: #c8c6c4;
    --manual-bg: #2d2c2b;
    --neutral: #c8c6c4;
    --neutral-bg: #2d2c2b;
    --shadow-sm: 0 1px 2px rgba(0,0,0,.5);
    --shadow-md: 0 2px 10px rgba(0,0,0,.55);
  }
}

:root[data-theme="dark"] {
  --bg: #1b1a19;
  --bg-elevated: #252423;
  --bg-sunken: #201f1e;
  --surface-border: #3b3a39;
  --surface-border-strong: #484644;
  --text: #f3f2f1;
  --text-secondary: #d2d0ce;
  --text-muted: #a19f9d;
  --brand: #60cdff;
  --brand-strong: #99ebff;
  --link: #60cdff;
  --focus: #60cdff;
  --pass: #6ccb5f;
  --pass-bg: #143b10;
  --block: #f1707b;
  --block-bg: #442726;
  --action: #ffd966;
  --action-bg: #433a13;
  --advisory: #60cdff;
  --advisory-bg: #14313d;
  --manual: #c8c6c4;
  --manual-bg: #2d2c2b;
  --neutral: #c8c6c4;
  --neutral-bg: #2d2c2b;
  --shadow-sm: 0 1px 2px rgba(0,0,0,.5);
  --shadow-md: 0 2px 10px rgba(0,0,0,.55);
}

* { box-sizing: border-box; }

html { -webkit-text-size-adjust: 100%; }

body {
  margin: 0;
  font-family: var(--font-sans);
  font-size: 16px;
  line-height: 1.55;
  color: var(--text);
  background: var(--bg);
  -webkit-font-smoothing: antialiased;
  text-rendering: optimizeLegibility;
}

.wrap { max-width: var(--maxw); margin: 0 auto; padding: 0 clamp(16px, 4vw, 40px); }

h1, h2, h3, h4 { font-family: var(--font-display); line-height: 1.2; color: var(--text); }
h1 { font-size: clamp(1.6rem, 1.1rem + 2.2vw, 2.4rem); font-weight: 700; margin: 0; letter-spacing: -.01em; }
h2 { font-size: clamp(1.25rem, 1rem + 1vw, 1.6rem); font-weight: 600; margin: 0 0 .5rem; }
h3 { font-size: 1.1rem; font-weight: 600; margin: 0 0 .35rem; }
p { margin: 0 0 .75rem; }
a { color: var(--link); text-underline-offset: 2px; }
a:hover { text-decoration: underline; }

:focus-visible { outline: 3px solid var(--focus); outline-offset: 2px; border-radius: 3px; }

.muted { color: var(--text-muted); }
.mono { font-family: var(--font-mono); font-size: .92em; overflow-wrap: anywhere; word-break: break-word; }
.small { font-size: .85rem; }
.nowrap { white-space: nowrap; }
.visually-hidden {
  position: absolute !important; width: 1px; height: 1px; padding: 0; margin: -1px;
  overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0;
}

.skip-link {
  position: absolute; left: 12px; top: -60px; z-index: 100;
  background: var(--brand); color: #fff; padding: 10px 16px; border-radius: 0 0 var(--radius) var(--radius);
  font-weight: 600; transition: top .15s ease;
}
.skip-link:focus { top: 0; }

.site-header {
  border-bottom: 1px solid var(--surface-border);
  background: var(--bg-elevated);
}
.site-header .wrap {
  display: flex; flex-wrap: wrap; gap: 16px 24px; align-items: center;
  justify-content: space-between; padding-top: 20px; padding-bottom: 20px;
}
.brand-lockup { display: flex; align-items: center; gap: 14px; }
.brand-mark {
  width: 40px; height: 40px; flex: none; border-radius: 9px;
  background: linear-gradient(135deg, var(--brand) 0%, var(--brand-strong) 100%);
  display: grid; place-items: center; color: #fff; font-weight: 700; font-size: 1.05rem;
  box-shadow: var(--shadow-sm);
}
.brand-text .kicker { font-size: .72rem; letter-spacing: .14em; text-transform: uppercase; color: var(--text-muted); font-weight: 600; }
.brand-text .title { font-family: var(--font-display); font-weight: 600; font-size: 1.06rem; }
.header-meta { display: flex; flex-wrap: wrap; gap: 8px 18px; align-items: center; font-size: .85rem; color: var(--text-secondary); }
.header-meta .hm { display: inline-flex; gap: 6px; align-items: baseline; }
.header-meta .hm b { font-weight: 600; color: var(--text); }

.theme-toggle {
  font: inherit; font-size: .85rem; cursor: pointer;
  background: var(--bg-sunken); color: var(--text); border: 1px solid var(--surface-border-strong);
  border-radius: 999px; padding: 7px 14px; min-height: 40px; display: inline-flex; gap: 8px; align-items: center;
}
.theme-toggle:hover { border-color: var(--brand); }

.disclaimer-banner {
  background: var(--advisory-bg); border: 1px solid var(--surface-border);
  border-left: 4px solid var(--brand);
  border-radius: var(--radius); padding: 14px 18px; margin: 20px 0;
  display: flex; gap: 12px; align-items: flex-start;
}
.disclaimer-banner .db-icon { font-size: 1.1rem; line-height: 1.4; flex: none; }
.disclaimer-banner strong { color: var(--text); }

.section { margin: 34px 0; }
.section > .section-head { display: flex; flex-wrap: wrap; gap: 6px 14px; align-items: baseline; margin-bottom: 14px; }
.section > .section-head .section-sub { color: var(--text-muted); font-size: .9rem; }

.card {
  background: var(--bg-elevated); border: 1px solid var(--surface-border);
  border-radius: var(--radius-lg); box-shadow: var(--shadow-sm); padding: clamp(16px, 3vw, 26px);
}

.hero {
  position: relative; overflow: hidden;
  --verdict-color: var(--neutral);
  border: 1px solid var(--surface-border);
  border-radius: var(--radius-lg); box-shadow: var(--shadow-md);
  background: var(--bg-elevated); padding: clamp(20px, 4vw, 34px);
  display: grid; grid-template-columns: auto 1fr; gap: clamp(18px, 4vw, 34px); align-items: center;
}
.hero::before {
  content: ""; position: absolute; inset: 0; pointer-events: none;
  background: radial-gradient(120% 140% at 100% 0%, color-mix(in srgb, var(--verdict-color) 12%, transparent) 0%, transparent 55%);
}
.hero-badge {
  width: clamp(84px, 16vw, 116px); height: clamp(84px, 16vw, 116px); border-radius: 50%;
  display: grid; place-items: center; flex: none; position: relative; z-index: 1;
  background: color-mix(in srgb, var(--verdict-color) 16%, var(--bg-elevated));
  border: 3px solid var(--verdict-color); color: var(--verdict-color);
  font-size: clamp(2.4rem, 8vw, 3.4rem); font-weight: 700;
}
.hero-body { position: relative; z-index: 1; }
.hero-body .verdict-label { font-family: var(--font-display); font-size: clamp(1.5rem, 1rem + 2.6vw, 2.3rem); font-weight: 700; letter-spacing: -.01em; color: var(--verdict-color); }
.hero.v-ready { --verdict-color: var(--pass); }
.hero.v-blocked { --verdict-color: var(--block); }
.hero.v-incomplete { --verdict-color: var(--action); }
.hero.v-complete { --verdict-color: var(--brand); }
.hero.v-neutral { --verdict-color: var(--neutral); }
.hero-summary { color: var(--text-secondary); max-width: 66ch; margin-top: 6px; }
.verdict-counts { display: flex; flex-wrap: wrap; gap: 10px 12px; margin-top: 16px; }
.count-chip {
  display: inline-flex; gap: 8px; align-items: center; padding: 8px 14px; border-radius: 999px;
  border: 1px solid var(--surface-border-strong); background: var(--bg-sunken); font-size: .88rem;
}
.count-chip b { font-size: 1.05rem; }
.count-chip.c-block { border-color: var(--block); background: var(--block-bg); color: var(--block); }
.count-chip.c-action { border-color: var(--action); background: var(--action-bg); color: var(--action); }
.count-chip.c-auth { border-color: var(--advisory); background: var(--advisory-bg); color: var(--advisory); }

.gate {
  border: 1px solid var(--action); border-left: 5px solid var(--action);
  background: var(--action-bg); color: var(--text);
  border-radius: var(--radius-lg); padding: clamp(16px, 3vw, 24px); margin: 24px 0;
}
.gate h2 { color: var(--text); display: flex; gap: 10px; align-items: center; }
.gate .gate-glyph { color: var(--action); font-size: 1.3rem; }

.toc { border: 1px solid var(--surface-border); border-radius: var(--radius); background: var(--bg-sunken); padding: 14px 18px; }
.toc h2 { font-size: .8rem; text-transform: uppercase; letter-spacing: .1em; color: var(--text-muted); margin-bottom: 10px; }
.toc ul { list-style: none; margin: 0; padding: 0; display: flex; flex-wrap: wrap; gap: 6px 8px; }
.toc a {
  display: inline-block; padding: 5px 11px; border-radius: 999px; font-size: .85rem;
  text-decoration: none; color: var(--text-secondary); background: var(--bg-elevated);
  border: 1px solid var(--surface-border);
}
.toc a:hover { border-color: var(--brand); color: var(--link); }

.grid { display: grid; gap: 16px; }
.grid > * { min-width: 0; }
.grid.cols-2 { grid-template-columns: repeat(auto-fit, minmax(280px, 1fr)); }
.grid.cols-3 { grid-template-columns: repeat(auto-fit, minmax(220px, 1fr)); }
.grid.cols-4 { grid-template-columns: repeat(auto-fit, minmax(150px, 1fr)); }

.stat { background: var(--bg-sunken); border: 1px solid var(--surface-border); border-radius: var(--radius); padding: 14px 16px; }
.stat .stat-value { font-family: var(--font-display); font-size: 1.7rem; font-weight: 700; line-height: 1; }
.stat .stat-label { font-size: .8rem; color: var(--text-muted); margin-top: 6px; text-transform: uppercase; letter-spacing: .05em; }
.stat.s-pass .stat-value { color: var(--pass); }
.stat.s-block .stat-value { color: var(--block); }
.stat.s-action .stat-value { color: var(--action); }

.coverage-meter { margin-top: 10px; }
.coverage-track {
  height: 12px; border-radius: 999px; background: var(--bg-sunken);
  border: 1px solid var(--surface-border); overflow: hidden; display: flex;
}
.coverage-track .seg { height: 100%; }
.coverage-track .seg.s-pass { background: var(--pass); }
.coverage-track .seg.s-block { background: var(--block); }
.coverage-track .seg.s-action { background: var(--action); }
.coverage-track .seg.s-advisory { background: var(--advisory); }
.coverage-track .seg.s-manual { background: var(--manual); }
.coverage-track .seg.s-na { background: var(--neutral-bg); }
.coverage-legend { display: flex; flex-wrap: wrap; gap: 6px 16px; margin-top: 12px; font-size: .82rem; }
.coverage-legend .lg { display: inline-flex; gap: 7px; align-items: center; }
.coverage-legend .sw { width: 12px; height: 12px; border-radius: 3px; border: 1px solid rgba(0,0,0,.15); flex: none; }

.pill {
  display: inline-flex; align-items: center; gap: 6px; padding: 3px 10px 3px 8px;
  border-radius: 999px; font-size: .8rem; font-weight: 600; white-space: nowrap;
  border: 1px solid transparent;
}
.pill-glyph { display: inline-grid; place-items: center; width: 16px; height: 16px; border-radius: 50%; font-size: .72rem; line-height: 1; }
.pill.s-pass { color: var(--pass); background: var(--pass-bg); border-color: color-mix(in srgb, var(--pass) 40%, transparent); }
.pill.s-block { color: var(--block); background: var(--block-bg); border-color: color-mix(in srgb, var(--block) 40%, transparent); }
.pill.s-action { color: var(--action); background: var(--action-bg); border-color: color-mix(in srgb, var(--action) 40%, transparent); }
.pill.s-advisory { color: var(--advisory); background: var(--advisory-bg); border-color: color-mix(in srgb, var(--advisory) 40%, transparent); }
.pill.s-manual { color: var(--manual); background: var(--manual-bg); border-color: var(--surface-border-strong); }
.pill.s-na, .pill.s-unknown { color: var(--neutral); background: var(--neutral-bg); border-color: var(--surface-border-strong); }
.pill.s-noauth { color: var(--text-secondary); background: var(--bg-sunken); border-color: var(--surface-border-strong); }
.pill.s-error { color: var(--block); background: var(--block-bg); border-color: color-mix(in srgb, var(--block) 40%, transparent); }
.pill .pill-glyph { background: color-mix(in srgb, currentColor 18%, transparent); }

.pillar-grid { display: grid; gap: 16px; grid-template-columns: repeat(auto-fit, minmax(240px, 1fr)); }
.pillar { border: 1px solid var(--surface-border); border-radius: var(--radius); padding: 18px; background: var(--bg-elevated); border-top: 3px solid var(--brand); }
.pillar h3 { display: flex; align-items: center; gap: 8px; }
.pillar .pillar-tag { font-size: .72rem; letter-spacing: .1em; text-transform: uppercase; color: var(--text-muted); font-weight: 600; }
.pillar-bars { display: grid; gap: 6px; margin-top: 12px; font-size: .84rem; }
.pillar-bars .pb { display: grid; grid-template-columns: 1fr auto; gap: 8px; }

table.data { width: 100%; border-collapse: collapse; font-size: .9rem; }
table.data caption { text-align: left; color: var(--text-muted); font-size: .82rem; padding-bottom: 8px; }
table.data th, table.data td { text-align: left; padding: 10px 12px; border-bottom: 1px solid var(--surface-border); vertical-align: top; }
table.data thead th { font-size: .74rem; text-transform: uppercase; letter-spacing: .06em; color: var(--text-muted); border-bottom: 2px solid var(--surface-border-strong); position: sticky; top: 0; background: var(--bg-elevated); }
table.data tbody tr:hover { background: var(--bg-sunken); }
.table-scroll { overflow-x: auto; border: 1px solid var(--surface-border); border-radius: var(--radius); }

.result {
  border: 1px solid var(--surface-border); border-radius: var(--radius);
  background: var(--bg-elevated); margin: 12px 0; overflow: hidden;
}
.result > summary {
  list-style: none; cursor: pointer; padding: 14px 16px; display: grid;
  grid-template-columns: auto 1fr auto; gap: 12px; align-items: center;
}
.result > summary::-webkit-details-marker { display: none; }
.result > summary:hover { background: var(--bg-sunken); }
.result > summary .r-title { font-weight: 600; }
.result > summary .r-id { font-family: var(--font-mono); font-size: .78rem; color: var(--text-muted); }
.result[open] > summary { border-bottom: 1px solid var(--surface-border); }
.result .r-marker { width: 8px; height: 40px; border-radius: 4px; background: var(--neutral); }
.result.s-pass .r-marker { background: var(--pass); }
.result.s-block .r-marker { background: var(--block); }
.result.s-action .r-marker { background: var(--action); }
.result.s-advisory .r-marker { background: var(--advisory); }
.result.s-manual .r-marker { background: var(--manual); }
.result-body { padding: 4px 16px 18px; }
.result-body .kv { margin: 0; }
.field { margin: 12px 0; }
.field > .field-label { font-size: .74rem; text-transform: uppercase; letter-spacing: .06em; color: var(--text-muted); margin-bottom: 3px; font-weight: 600; }
.field.expected .field-value { border-left: 3px solid var(--surface-border-strong); padding-left: 10px; }
.field.observed .field-value { border-left: 3px solid var(--brand); padding-left: 10px; }
.remediation { background: var(--advisory-bg); border: 1px solid color-mix(in srgb, var(--advisory) 30%, transparent); border-radius: var(--radius); padding: 12px 14px; margin-top: 12px; }
.remediation .field-label { color: var(--advisory); }

.kv { display: grid; grid-template-columns: minmax(120px, max-content) 1fr; gap: 4px 16px; margin: 0; }
.kv dt { font-weight: 600; color: var(--text-secondary); }
.kv dd { margin: 0; min-width: 0; overflow-wrap: anywhere; }
.detail-list { margin: 4px 0; padding-left: 20px; }
.detail-list li { margin: 2px 0; overflow-wrap: anywhere; }

.chips { display: flex; flex-wrap: wrap; gap: 6px; }
.chip { font-size: .78rem; padding: 3px 9px; border-radius: 999px; background: var(--bg-sunken); border: 1px solid var(--surface-border); color: var(--text-secondary); }
.chip.ok { color: var(--pass); background: var(--pass-bg); border-color: color-mix(in srgb, var(--pass) 35%, transparent); }
.chip.miss { color: var(--block); background: var(--block-bg); border-color: color-mix(in srgb, var(--block) 35%, transparent); }

.tenant-target { margin-top: 16px; padding-top: 14px; border-top: 1px solid var(--surface-border); }
.tenant-target .tt-label { font-size: .72rem; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; color: var(--text-muted); margin: 0 0 8px; }
.tenant-target .chip { display: inline-flex; align-items: center; gap: 5px; }
.tenant-target .chip [aria-hidden] { font-weight: 700; line-height: 1; }

.badge-row { display: flex; flex-wrap: wrap; gap: 8px; }
.badge { font-size: .76rem; font-weight: 600; padding: 4px 10px; border-radius: 6px; background: var(--bg-sunken); border: 1px solid var(--surface-border-strong); color: var(--text-secondary); }
.badge.beta { color: var(--action); border-color: var(--action); background: var(--action-bg); }
.badge.fixture { color: var(--advisory); border-color: var(--advisory); background: var(--advisory-bg); }
.badge.sanitized { color: var(--text); border-color: var(--surface-border-strong); }

.callout { border-radius: var(--radius); padding: 14px 16px; border: 1px solid var(--surface-border); background: var(--bg-sunken); }
.callout.empty { text-align: center; color: var(--text-muted); }

.site-footer { border-top: 1px solid var(--surface-border); margin-top: 48px; padding: 28px 0 44px; color: var(--text-muted); font-size: .85rem; background: var(--bg-elevated); }
.site-footer .wrap { display: grid; gap: 16px; }
.footer-disclaimer { border: 1px solid var(--surface-border); border-left: 4px solid var(--brand); border-radius: var(--radius); padding: 12px 16px; background: var(--bg-sunken); color: var(--text-secondary); }

.drift-list { display: grid; gap: 8px; }
.drift-item { display: grid; grid-template-columns: auto 1fr; gap: 10px; align-items: center; padding: 10px 12px; border: 1px solid var(--surface-border); border-radius: var(--radius); background: var(--bg-elevated); }
.drift-item .arrow { color: var(--text-muted); }

/* --- Interactive findings: command bar --- */
.sr-only { position: absolute; width: 1px; height: 1px; padding: 0; margin: -1px; overflow: hidden; clip: rect(0 0 0 0); white-space: nowrap; border: 0; }
[data-result-card], [data-result-group] { scroll-margin-top: 96px; }
.findings-command {
  position: sticky; top: 0; z-index: 40;
  background: var(--bg); border: 1px solid var(--surface-border);
  border-radius: var(--radius-lg); padding: 14px 16px; margin-bottom: 18px;
  display: grid; gap: 12px;
}
.command-row { display: flex; flex-wrap: wrap; gap: 10px 14px; align-items: center; }
.search-field { position: relative; flex: 1 1 260px; min-width: 0; }
.search-field .search-icon { position: absolute; left: 13px; top: 50%; transform: translateY(-50%); color: var(--text-muted); pointer-events: none; font-size: .95rem; }
.search-field input[type="search"] {
  width: 100%; font: inherit; font-size: .95rem; color: var(--text);
  background: var(--bg-elevated); border: 1px solid var(--surface-border-strong);
  border-radius: 999px; padding: 10px 48px 10px 40px; min-height: 44px;
}
.search-field input[type="search"]::-webkit-search-cancel-button { display: none; }
.search-field input[type="search"]:focus-visible { border-color: var(--brand); }
.search-field input[type="search"]::placeholder { color: var(--text-muted); }
.search-clear {
  position: absolute; right: 4px; top: 50%; transform: translateY(-50%);
  border: 0; background: transparent; color: var(--text-muted); cursor: pointer;
  width: 40px; height: 40px; border-radius: 50%; display: grid; place-items: center; font-size: 1rem; line-height: 1;
}
.search-clear:hover { background: var(--bg-sunken); color: var(--text); }
.search-hint { font-size: .78rem; color: var(--text-muted); white-space: nowrap; }
.search-hint kbd { font-family: var(--font-mono); background: var(--bg-sunken); border: 1px solid var(--surface-border-strong); border-radius: 4px; padding: 1px 6px; font-size: .9em; }

.filter-pills { display: flex; flex-wrap: wrap; gap: 8px; }
.filter-pill {
  font: inherit; font-size: .82rem; font-weight: 600; cursor: pointer;
  display: inline-flex; align-items: center; gap: 7px; min-height: 40px; padding: 6px 12px;
  border-radius: 999px; border: 1px solid var(--surface-border-strong);
  background: var(--bg-elevated); color: var(--text-secondary);
}
.filter-pill .fp-dot { width: 9px; height: 9px; border-radius: 50%; flex: none; border: 1px solid rgba(0,0,0,.18); }
.filter-pill .fp-count {
  font-size: .74rem; font-weight: 700; min-width: 18px; text-align: center; padding: 1px 6px; border-radius: 999px;
  background: var(--bg-sunken); color: var(--text-secondary); border: 1px solid var(--surface-border);
}
.filter-pill[aria-pressed="true"] {
  border-color: var(--brand); color: var(--text); background: var(--bg-sunken);
  box-shadow: inset 0 0 0 1px var(--brand);
}
.filter-pill[aria-pressed="true"]::before { content: "\2713"; font-weight: 800; color: var(--brand); margin-right: -1px; }
.filter-pill[aria-pressed="true"] .fp-count { background: var(--brand); color: #fff; border-color: var(--brand); }
.filter-pill:hover { border-color: var(--brand); }
.fp-dot.s-block { background: var(--block); }
.fp-dot.s-action { background: var(--action); }
.fp-dot.s-manual { background: var(--manual); }
.fp-dot.s-noauth { background: var(--neutral); }
.fp-dot.s-advisory { background: var(--advisory); }
.fp-dot.s-pass { background: var(--pass); }
.fp-dot.s-all { background: var(--brand); }

.command-meta { display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; justify-content: space-between; }
#filterResultCount { font-size: .85rem; color: var(--text-secondary); margin: 0; }
#filterResultCount b { color: var(--text); }
.command-actions { display: flex; gap: 8px; flex-wrap: wrap; }

.advanced { border-top: 1px dashed var(--surface-border); padding-top: 12px; }
.advanced > summary {
  list-style: none; cursor: pointer; font-size: .84rem; font-weight: 600; color: var(--text-secondary);
  display: inline-flex; align-items: center; gap: 8px; min-height: 40px; user-select: none;
}
.advanced > summary::-webkit-details-marker { display: none; }
.advanced > summary::before { content: "\25B8"; color: var(--text-muted); transition: transform .15s ease; }
.advanced[open] > summary::before { transform: rotate(90deg); }
.advanced-grid { display: grid; grid-template-columns: repeat(auto-fit, minmax(180px, 1fr)); gap: 12px; margin-top: 12px; }
.advanced-grid label { display: grid; gap: 5px; font-size: .76rem; font-weight: 600; letter-spacing: .04em; text-transform: uppercase; color: var(--text-muted); }
.advanced-grid select {
  font: inherit; font-size: .9rem; color: var(--text); background: var(--bg-elevated);
  border: 1px solid var(--surface-border-strong); border-radius: var(--radius); padding: 9px 10px; min-height: 42px;
}
.advanced-grid select:focus-visible { border-color: var(--brand); }

/* --- Interactive findings: groups & cards --- */
.finding-group {
  border: 1px solid var(--surface-border); border-radius: var(--radius-lg);
  background: var(--bg-elevated); margin: 14px 0; overflow: hidden;
}
.finding-group > summary {
  list-style: none; cursor: pointer; padding: 14px 16px; display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center;
}
.finding-group > summary::-webkit-details-marker { display: none; }
.finding-group > summary:hover { background: var(--bg-sunken); }
.finding-group > summary::before { content: "\25B8"; color: var(--text-muted); flex: none; transition: transform .15s ease; }
.finding-group[open] > summary::before { transform: rotate(90deg); }
.finding-group > summary .fg-title { font-family: var(--font-display); font-weight: 600; font-size: 1.05rem; }
.finding-group > summary .fg-title .muted { font-weight: 400; }
.fg-counts { display: flex; flex-wrap: wrap; gap: 6px; margin-left: auto; }
.fg-count {
  font-size: .74rem; font-weight: 600; padding: 2px 9px; border-radius: 999px;
  border: 1px solid var(--surface-border-strong); background: var(--bg-sunken); color: var(--text-secondary);
  display: inline-flex; gap: 6px; align-items: center; white-space: nowrap;
}
.fg-count .fp-dot { width: 8px; height: 8px; border-radius: 50%; border: 1px solid rgba(0,0,0,.18); }
.fg-count.s-block { border-color: color-mix(in srgb, var(--block) 45%, transparent); color: var(--block); }
.fg-count.s-action { border-color: color-mix(in srgb, var(--action) 45%, transparent); color: var(--action); }
.finding-group-body { padding: 4px 12px 14px; display: grid; gap: 10px; }

.finding { border: 1px solid var(--surface-border); border-radius: var(--radius); background: var(--bg-elevated); }
.finding-row { display: grid; grid-template-columns: auto 1fr auto auto; gap: 12px; align-items: center; padding: 12px 14px; }
.finding .r-marker { width: 8px; height: 38px; border-radius: 4px; background: var(--neutral); flex: none; }
.finding.s-pass .r-marker { background: var(--pass); }
.finding.s-block .r-marker { background: var(--block); }
.finding.s-action .r-marker { background: var(--action); }
.finding.s-advisory .r-marker { background: var(--advisory); }
.finding.s-manual .r-marker { background: var(--manual); }
.finding.s-noauth .r-marker, .finding.s-error .r-marker { background: var(--block); }
.finding-main { min-width: 0; }
.finding-title { font-weight: 600; }
.finding-title .r-id { font-family: var(--font-mono); font-size: .78rem; color: var(--text-muted); font-weight: 400; margin-left: 6px; }
.finding-observed { font-size: .86rem; color: var(--text-secondary); margin-top: 2px; overflow: hidden; text-overflow: ellipsis; display: -webkit-box; -webkit-line-clamp: 1; -webkit-box-orient: vertical; }
.view-details-btn {
  font: inherit; font-size: .82rem; font-weight: 600; cursor: pointer; white-space: nowrap;
  background: var(--bg-sunken); color: var(--link); border: 1px solid var(--surface-border-strong);
  border-radius: var(--radius); padding: 8px 13px; min-height: 40px;
}
.view-details-btn:hover { border-color: var(--brand); }
.finding-full { border-top: 1px solid var(--surface-border); padding: 4px 14px 14px; }
.js .finding-full { display: none; }
.findings-empty { text-align: center; color: var(--text-muted); padding: 26px 16px; border: 1px dashed var(--surface-border-strong); border-radius: var(--radius); background: var(--bg-sunken); }

/* --- Detail blade / bottom sheet --- */
.detail-backdrop {
  position: fixed; inset: 0; z-index: 90; background: rgba(0,0,0,.45);
  opacity: 0; visibility: hidden; transition: opacity .2s ease, visibility .2s ease;
}
.detail-backdrop.open { opacity: 1; visibility: visible; }
.detail-blade {
  position: fixed; top: 0; right: 0; z-index: 100; height: 100%;
  width: min(540px, 100%); max-width: 100%; background: var(--bg-elevated);
  border-left: 1px solid var(--surface-border); box-shadow: var(--shadow-md);
  display: flex; flex-direction: column; transform: translateX(100%);
  transition: transform .22s ease, visibility .22s ease; visibility: hidden;
}
.detail-blade.open { transform: translateX(0); visibility: visible; }
.detail-blade-head {
  display: flex; gap: 12px; align-items: flex-start; justify-content: space-between;
  padding: 16px 18px; border-bottom: 1px solid var(--surface-border); flex: none;
}
.detail-blade-head .dbh-title { font-family: var(--font-display); font-size: 1.15rem; font-weight: 600; margin: 0; outline: none; }
.detail-blade-head .dbh-meta { margin-top: 8px; }
.detail-close {
  font: inherit; cursor: pointer; flex: none; width: 40px; height: 40px; border-radius: 50%;
  border: 1px solid var(--surface-border-strong); background: var(--bg-sunken); color: var(--text);
  display: grid; place-items: center; font-size: 1.15rem;
}
.detail-close:hover { border-color: var(--brand); }
.detail-blade-body { padding: 16px 18px; overflow-y: auto; -webkit-overflow-scrolling: touch; }
.detail-blade-body .blade-detail > .kv:first-child { margin-top: 0; }
body.blade-open { overflow: hidden; }

/* --- Answer guidance dialog + appendix (Answers Builder 1.3 guidance) --- */
.review-guidance-btn {
  font: inherit; font-size: .82rem; font-weight: 600; cursor: pointer; margin-left: auto;
  display: inline-flex; align-items: center; gap: 6px; min-height: 40px; padding: 6px 14px;
  border-radius: var(--radius); border: 1px solid var(--surface-border-strong);
  background: var(--bg-sunken); color: var(--link);
}
.review-guidance-btn:hover { border-color: var(--brand); }
.review-guidance-btn:focus-visible { outline: var(--focus); outline-offset: 2px; }
.review-guidance-btn .rg-glyph { font-size: .95rem; line-height: 1; }

.guidance-backdrop {
  position: fixed; inset: 0; z-index: 110; background: rgba(0,0,0,.5);
  opacity: 0; visibility: hidden; transition: opacity .2s ease, visibility .2s ease;
}
.guidance-backdrop.open { opacity: 1; visibility: visible; }
.guidance-dialog {
  position: fixed; top: 0; right: 0; z-index: 120; height: 100%;
  width: min(560px, 100%); max-width: 100%; background: var(--bg-elevated);
  border-left: 4px solid var(--brand); box-shadow: var(--shadow-md);
  display: flex; flex-direction: column; transform: translateX(100%);
  transition: transform .22s ease, visibility .22s ease; visibility: hidden;
}
.guidance-dialog.open { transform: translateX(0); visibility: visible; }
.guidance-dialog-head {
  display: flex; gap: 12px; align-items: flex-start; justify-content: space-between;
  padding: 16px 18px; border-bottom: 1px solid var(--surface-border); flex: none;
}
.guidance-dialog-eyebrow { margin: 0 0 3px; font-size: .7rem; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: var(--brand); }
.guidance-dialog-title { font-family: var(--font-display); font-size: 1.15rem; font-weight: 600; margin: 0; outline: none; line-height: 1.2; }
.guidance-dialog-meta { margin-top: 8px; display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; font-size: .82rem; color: var(--text-muted); }
.guidance-dialog-meta .guidance-meta-role { color: var(--text-secondary); }
.guidance-close {
  font: inherit; cursor: pointer; flex: none; width: 40px; height: 40px; border-radius: 50%;
  border: 1px solid var(--surface-border-strong); background: var(--bg-sunken); color: var(--text);
  display: grid; place-items: center; font-size: 1.15rem;
}
.guidance-close:hover { border-color: var(--brand); }
.guidance-dialog-body { padding: 16px 18px; overflow-y: auto; -webkit-overflow-scrolling: touch; flex: 1 1 auto; }
.guidance-dialog-foot {
  flex: none; display: flex; flex-wrap: wrap; align-items: center; gap: 10px;
  padding: 12px 18px; border-top: 1px solid var(--surface-border); background: var(--bg-elevated);
}
.guidance-back-btn { min-height: 40px; }
.guidance-copy-btn { min-height: 40px; }
.guidance-copy-feedback { font-size: .82rem; color: var(--text-muted); min-width: 0; }
body.guidance-open { overflow: hidden; }

/* Guidance sections (shared markup: appendix, cloned dialog body, print) */
.g-observed {
  margin: 0 0 16px; padding: 10px 12px; border: 1px dashed var(--surface-border-strong);
  border-radius: var(--radius); background: var(--bg-sunken);
}
.g-observed-label { margin: 0 0 4px; font-size: .72rem; font-weight: 700; letter-spacing: .05em; text-transform: uppercase; color: var(--text-muted); }
.g-observed-value { margin: 0; font-family: var(--font-mono); font-size: .85rem; color: var(--text); word-break: break-word; }
.g-observed-value.muted { color: var(--text-muted); }
.g-observed-note { margin: 6px 0 0; font-size: .78rem; color: var(--text-muted); font-style: italic; }
.g-sec { margin: 0 0 16px; }
.g-sec-title { font-family: var(--font-display); font-size: .95rem; font-weight: 600; margin: 0 0 6px; color: var(--text); }
.g-sec > p { margin: 0; color: var(--text-secondary); }
.g-check { list-style: none; margin: 0; padding: 0; display: grid; gap: 7px; }
.g-check li { position: relative; padding-left: 24px; color: var(--text-secondary); }
.g-check li::before { content: ""; position: absolute; left: 0; top: .18em; width: 15px; height: 15px; border-radius: 4px; border: 1px solid var(--surface-border-strong); background: var(--bg-elevated); }
.g-check-yes li::before { border-color: color-mix(in srgb, var(--pass) 55%, transparent); }
.g-check-evidence li::before { border-radius: 3px; }
.g-steps { margin: 0; padding-left: 20px; display: grid; gap: 12px; }
.g-steps li { color: var(--text-secondary); }
.g-step-head { display: flex; flex-wrap: wrap; gap: 6px 10px; align-items: baseline; }
.g-step-title { font-weight: 600; color: var(--text); }
.g-step-loc { font-family: var(--font-mono); font-size: .74rem; padding: 2px 8px; border-radius: 999px; border: 1px solid var(--surface-border-strong); background: var(--bg-sunken); color: var(--text-muted); }
.g-step-instr { margin: 4px 0 0; }
.g-sources { list-style: none; margin: 0; padding: 0; display: grid; gap: 6px; }
.g-review { margin: 4px 0 0; font-size: .8rem; color: var(--text-muted); }

/* Guidance appendix (always present for print + no-JS) */
.guidance-appendix { margin: 22px 0 0; border-top: 1px solid var(--surface-border); padding-top: 18px; display: grid; gap: 12px; }
.guidance-appendix-title { font-family: var(--font-display); font-size: 1.05rem; font-weight: 600; margin: 0; }
.guidance-appendix-note { margin: 0; }
.guidance-doc { border: 1px solid var(--surface-border); border-radius: var(--radius); background: var(--bg-elevated); border-left: 3px solid var(--brand); }
.guidance-doc-summary { cursor: pointer; padding: 12px 14px; display: flex; flex-direction: column; gap: 2px; list-style: none; }
.guidance-doc-summary::-webkit-details-marker { display: none; }
.guidance-doc-summary:focus-visible { outline: var(--focus); outline-offset: -2px; }
.guidance-eyebrow { font-size: .68rem; font-weight: 700; letter-spacing: .08em; text-transform: uppercase; color: var(--brand); }
.guidance-doc-title { font-weight: 600; color: var(--text); }
.guidance-doc-inner { padding: 0 14px 14px; }
.guidance-meta { display: flex; flex-wrap: wrap; align-items: center; gap: 6px 10px; margin: 0 0 12px; font-size: .82rem; color: var(--text-muted); }
.guidance-meta-role { color: var(--text-secondary); }

@media (max-width: 640px) {
  .hero { grid-template-columns: 1fr; text-align: left; }
  .result > summary { grid-template-columns: auto 1fr; }
  .result > summary .r-status { grid-column: 2; }
  .kv { grid-template-columns: 1fr; gap: 2px 0; }
  .kv dd { margin-bottom: 8px; }
  .finding-row { grid-template-columns: auto 1fr; }
  .finding-status { grid-column: 2; justify-self: start; }
  .view-details-btn { grid-column: 2; justify-self: start; }
  .detail-blade {
    width: 100%; height: 90%; top: auto; bottom: 0; right: 0; border-left: 0;
    border-top: 1px solid var(--surface-border); border-radius: var(--radius-lg) var(--radius-lg) 0 0;
    transform: translateY(100%);
  }
  .detail-blade.open { transform: translateY(0); }
  .guidance-dialog {
    width: 100%; height: 100%; top: 0; bottom: 0; right: 0; border-left: 0;
    border-top: 4px solid var(--brand); border-radius: 0;
    transform: translateY(100%);
  }
  .guidance-dialog.open { transform: translateY(0); }
  .review-guidance-btn { margin-left: 0; }
}

@media (prefers-reduced-motion: reduce) {
  * { animation-duration: .001ms !important; animation-iteration-count: 1 !important; transition-duration: .001ms !important; scroll-behavior: auto !important; }
}

.no-js .js-only { display: none !important; }

/* --- Shared action buttons --- */
.cta-primary {
  font: inherit; font-size: .92rem; font-weight: 600; cursor: pointer; text-decoration: none;
  display: inline-flex; align-items: center; justify-content: center; gap: 8px; min-height: 44px; padding: 10px 20px;
  border-radius: var(--radius); border: 1px solid var(--brand); background: var(--brand); color: #ffffff;
}
.cta-primary:hover { background: var(--brand-strong); border-color: var(--brand-strong); }
:root[data-theme="dark"] .cta-primary, :root:not([data-theme="light"]) .cta-primary { color: #05121c; }
.act-btn {
  font: inherit; font-size: .85rem; font-weight: 600; cursor: pointer; text-decoration: none;
  display: inline-flex; align-items: center; justify-content: center; gap: 7px; min-height: 40px; padding: 8px 14px;
  border-radius: var(--radius); border: 1px solid var(--surface-border-strong); background: var(--bg-elevated); color: var(--text);
}
.act-btn:hover { border-color: var(--brand); }
.act-btn.is-brand { color: var(--link); }

/* --- Readiness command center --- */
.command-center {
  background: var(--bg-elevated); border: 1px solid var(--surface-border); border-radius: var(--radius-lg);
  box-shadow: var(--shadow-sm); padding: 20px 22px; margin: 0 0 22px;
  display: grid; grid-template-columns: minmax(0, auto) minmax(0, 1fr); gap: 20px 26px; align-items: start;
}
.command-center::before { content: ""; display: block; height: 4px; grid-column: 1 / -1; margin: -20px -22px 0; border-radius: var(--radius-lg) var(--radius-lg) 0 0; background: var(--neutral); }
.command-center.v-ready::before, .command-center.v-complete::before { background: var(--pass); }
.command-center.v-blocked::before { background: var(--block); }
.command-center.v-incomplete::before { background: var(--action); }
.cc-badge {
  align-self: start; display: inline-flex; align-items: center; gap: 10px; padding: 10px 16px;
  border-radius: 999px; font-family: var(--font-display); font-weight: 600; font-size: 1.02rem;
  border: 1px solid var(--surface-border-strong); background: var(--bg-sunken); color: var(--text); white-space: nowrap;
}
.cc-badge .cc-glyph { font-size: 1.05rem; line-height: 1; }
.command-center.v-ready .cc-badge, .command-center.v-complete .cc-badge { background: var(--pass-bg); border-color: color-mix(in srgb, var(--pass) 45%, transparent); color: var(--pass); }
.command-center.v-blocked .cc-badge { background: var(--block-bg); border-color: color-mix(in srgb, var(--block) 45%, transparent); color: var(--block); }
.command-center.v-incomplete .cc-badge { background: var(--action-bg); border-color: color-mix(in srgb, var(--action) 45%, transparent); color: var(--action); }
.cc-body { display: grid; gap: 14px; min-width: 0; }
.cc-heading { font-family: var(--font-display); font-size: clamp(1.35rem, 1.1rem + 1.1vw, 1.9rem); font-weight: 600; margin: 0; line-height: 1.15; letter-spacing: -.01em; }
.cc-summary { margin: 0; color: var(--text-secondary); font-size: .98rem; max-width: 62ch; }
.cc-prevents { display: grid; gap: 8px; }
.cc-prevents-label { font-size: .74rem; font-weight: 700; letter-spacing: .06em; text-transform: uppercase; color: var(--text-muted); }
.pass-chips { display: flex; flex-wrap: wrap; gap: 8px; }
.pass-chip {
  display: inline-flex; align-items: center; gap: 8px; font-size: .84rem; font-weight: 600;
  padding: 6px 12px; border-radius: var(--radius); border: 1px solid var(--surface-border-strong);
  background: var(--bg-sunken); color: var(--text);
}
.pass-chip .pc-count { font-family: var(--font-mono); font-weight: 700; }
.pass-chip.s-block { border-color: color-mix(in srgb, var(--block) 45%, transparent); color: var(--block); background: var(--block-bg); }
.pass-chip.s-action { border-color: color-mix(in srgb, var(--action) 50%, transparent); color: var(--action); background: var(--action-bg); }
.pass-chip.s-noauth, .pass-chip.s-error { border-color: color-mix(in srgb, var(--block) 40%, transparent); color: var(--block); background: var(--block-bg); }
.pass-chip.s-manual { border-color: var(--surface-border-strong); color: var(--text-secondary); }
.pass-chip.is-ok { border-color: color-mix(in srgb, var(--pass) 45%, transparent); color: var(--pass); background: var(--pass-bg); }
.cc-coverage { display: grid; gap: 6px; max-width: 460px; }
.cc-coverage-top { display: flex; justify-content: space-between; gap: 12px; font-size: .82rem; color: var(--text-secondary); }
.cc-coverage-top b { color: var(--text); }
.cc-meter { height: 8px; border-radius: 999px; background: var(--bg-sunken); border: 1px solid var(--surface-border); overflow: hidden; }
.cc-meter > span { display: block; height: 100%; background: var(--brand); border-radius: 999px; }
.cc-actions { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; margin-top: 2px; }
.cc-note { font-size: .8rem; color: var(--text-muted); margin: 0; }

/* --- Workspace jump nav --- */
.workspace-nav {
  position: sticky; top: 0; z-index: 40; margin: 0 0 22px;
  background: color-mix(in srgb, var(--bg-elevated) 92%, transparent); backdrop-filter: none;
  border: 1px solid var(--surface-border); border-radius: var(--radius); box-shadow: var(--shadow-sm);
}
.workspace-nav ul { list-style: none; margin: 0; padding: 4px 6px; display: flex; gap: 2px; overflow-x: auto; -webkit-overflow-scrolling: touch; }
.workspace-nav li { flex: none; }
.wsn-link {
  display: inline-flex; align-items: center; min-height: 40px; padding: 8px 14px; border-radius: var(--radius);
  font-size: .86rem; font-weight: 600; color: var(--text-secondary); text-decoration: none; white-space: nowrap;
}
.wsn-link:hover { background: var(--bg-sunken); color: var(--text); }
.wsn-link[aria-current="true"] { color: var(--brand); background: var(--bg-sunken); box-shadow: inset 0 -2px 0 0 var(--brand); }

/* --- Path to Ready stepper --- */
.path-phases { display: grid; gap: 4px; }
.path-phase { position: relative; padding: 0 0 6px 34px; }
.path-phase::before {
  content: ""; position: absolute; left: 12px; top: 30px; bottom: 0; width: 2px; background: var(--surface-border);
}
.path-phase:last-child::before { display: none; }
.path-phase-num {
  position: absolute; left: 0; top: 2px; width: 26px; height: 26px; border-radius: 50%;
  display: grid; place-items: center; font-size: .82rem; font-weight: 700; font-family: var(--font-mono);
  background: var(--bg-sunken); border: 1px solid var(--surface-border-strong); color: var(--text-secondary);
}
.path-phase.p-unblock .path-phase-num, .path-phase.p-authorize .path-phase-num { background: var(--block-bg); border-color: color-mix(in srgb, var(--block) 45%, transparent); color: var(--block); }
.path-phase.p-action .path-phase-num { background: var(--action-bg); border-color: color-mix(in srgb, var(--action) 50%, transparent); color: var(--action); }
.path-phase-title { font-family: var(--font-display); font-size: 1.08rem; font-weight: 600; margin: 0; display: flex; flex-wrap: wrap; align-items: baseline; gap: 8px; }
.path-phase-count { font-size: .74rem; font-weight: 700; font-family: var(--font-mono); color: var(--text-muted); }
.path-phase-desc { margin: 3px 0 10px; font-size: .86rem; color: var(--text-secondary); }
.path-item {
  display: grid; grid-template-columns: auto minmax(0,1fr) auto; gap: 10px 14px; align-items: start;
  border: 1px solid var(--surface-border); border-radius: var(--radius); background: var(--bg-elevated);
  padding: 12px 14px; margin: 0 0 8px;
}
.path-item .pi-marker { width: 8px; align-self: stretch; min-height: 34px; border-radius: 4px; background: var(--neutral); }
.path-item.s-block .pi-marker, .path-item.s-noauth .pi-marker, .path-item.s-error .pi-marker { background: var(--block); }
.path-item.s-action .pi-marker { background: var(--action); }
.path-item.s-manual .pi-marker { background: var(--manual); }
.path-item.s-advisory .pi-marker { background: var(--advisory); }
.pi-main { min-width: 0; }
.pi-title { font-weight: 600; }
.pi-title .pi-id { font-family: var(--font-mono); font-size: .76rem; color: var(--text-muted); font-weight: 400; margin-left: 6px; }
.pi-remediation { font-size: .86rem; color: var(--text-secondary); margin: 3px 0 0; }
.pi-meta { display: flex; flex-wrap: wrap; gap: 4px 14px; margin-top: 6px; font-size: .78rem; color: var(--text-muted); }
.pi-meta b { color: var(--text-secondary); font-weight: 600; }
.pi-side { display: grid; gap: 8px; justify-items: end; align-content: start; }
.pi-check { display: inline-flex; align-items: center; gap: 7px; font-size: .8rem; color: var(--text-secondary); cursor: pointer; min-height: 40px; }
.pi-check input { width: 18px; height: 18px; accent-color: var(--brand); flex: none; }
.pi-open {
  font: inherit; font-size: .8rem; font-weight: 600; cursor: pointer; white-space: nowrap;
  background: var(--bg-sunken); color: var(--link); border: 1px solid var(--surface-border-strong);
  border-radius: var(--radius); padding: 7px 12px; min-height: 40px;
}
.pi-open:hover { border-color: var(--brand); }
.pi-top { margin: 0 0 6px; }
.pi-check span:not(.sr-only) { font-weight: 600; }
.js .pi-jump { display: none; }
.no-js .pi-open.js-only { display: none !important; }
.path-ready-banner {
  display: flex; gap: 12px; align-items: center; padding: 16px 18px; border-radius: var(--radius-lg);
  border: 1px solid color-mix(in srgb, var(--pass) 40%, transparent); background: var(--pass-bg); color: var(--pass); font-weight: 600;
}
.local-progress-notice {
  display: flex; flex-wrap: wrap; gap: 8px 12px; align-items: center; justify-content: space-between;
  margin: 4px 0 16px; padding: 10px 14px; font-size: .82rem; color: var(--text-secondary);
  border: 1px dashed var(--surface-border-strong); border-radius: var(--radius); background: var(--bg-sunken);
}
.local-progress-notice strong { color: var(--text); }

/* --- Answers builder & rerun tooling --- */
.answers-builder, .rerun-tool { display: grid; gap: 14px; }
.answer-gate {
  border: 1px solid var(--surface-border); border-radius: var(--radius); background: var(--bg-elevated); padding: 14px 16px; display: grid; gap: 10px;
}
.answer-gate-head { display: flex; flex-wrap: wrap; gap: 6px 10px; align-items: baseline; }
.answer-gate-title { font-weight: 600; }
.answer-gate-req { font-size: .72rem; font-weight: 700; text-transform: uppercase; letter-spacing: .05em; color: var(--action); }
.answer-gate-evidence { font-size: .82rem; color: var(--text-muted); margin: 0; }
.answer-values { display: flex; flex-wrap: wrap; gap: 8px; }
.answer-values label {
  display: inline-flex; align-items: center; gap: 7px; min-height: 40px; padding: 6px 14px; cursor: pointer;
  border: 1px solid var(--surface-border-strong); border-radius: 999px; font-size: .84rem; font-weight: 600; color: var(--text-secondary); background: var(--bg-elevated);
}
.answer-values label:hover { border-color: var(--brand); }
.answer-values input { accent-color: var(--brand); width: 16px; height: 16px; }
.answer-values input:checked + span { color: var(--text); }
.answer-fields { display: grid; gap: 10px; grid-template-columns: repeat(auto-fit, minmax(200px, 1fr)); }
.answer-fields.full { grid-template-columns: 1fr; }
.answer-fields label { display: grid; gap: 5px; font-size: .74rem; font-weight: 600; letter-spacing: .03em; text-transform: uppercase; color: var(--text-muted); }
.answer-fields input, .answer-fields textarea {
  font: inherit; font-size: .9rem; color: var(--text); background: var(--bg-elevated);
  border: 1px solid var(--surface-border-strong); border-radius: var(--radius); padding: 9px 11px; min-height: 42px; width: 100%;
}
.answer-fields textarea { min-height: 64px; resize: vertical; }
.answer-fields input:focus-visible, .answer-fields textarea:focus-visible { border-color: var(--brand); }
.tool-actions { display: flex; flex-wrap: wrap; gap: 10px; align-items: center; }
.tool-feedback { font-size: .82rem; color: var(--text-secondary); margin: 0; min-height: 1.2em; }
.tool-feedback.is-error { color: var(--block); }
.tool-feedback.is-ok { color: var(--pass); }
.rerun-block { position: relative; display: grid; gap: 8px; }
.rerun-code {
  font-family: var(--font-mono); font-size: .86rem; line-height: 1.5; white-space: pre-wrap; word-break: break-word; overflow-wrap: anywhere;
  background: var(--bg-sunken); border: 1px solid var(--surface-border); border-radius: var(--radius); padding: 14px 16px; margin: 0; color: var(--text);
}
.rerun-meta { display: grid; gap: 2px; font-size: .82rem; color: var(--text-secondary); }
.rerun-meta .rm-k { color: var(--text-muted); }

/* --- Blade segmented sections --- */
.blade-seg { margin: 0 0 6px; }
.blade-seg + .blade-seg { border-top: 1px solid var(--surface-border); padding-top: 12px; margin-top: 12px; }
.blade-seg-title {
  font-family: var(--font-display); font-size: .78rem; font-weight: 700; letter-spacing: .06em; text-transform: uppercase;
  color: var(--text-muted); margin: 0 0 8px;
}

@media (max-width: 860px) {
  .command-center { grid-template-columns: 1fr; gap: 14px; }
  .cc-badge { justify-self: start; }
}
@media (max-width: 640px) {
  .path-item { grid-template-columns: auto minmax(0,1fr); }
  .pi-side { grid-column: 2; justify-items: start; grid-auto-flow: column; }
}

@media print {
  :root { --bg: #fff; --bg-elevated: #fff; --bg-sunken: #fff; --text: #000; --text-secondary: #222; --text-muted: #444; }
  body { font-size: 11pt; color: #000; background: #fff; }
  .skip-link, .theme-toggle, .toc, .js-only { display: none !important; }
  .findings-command, .detail-backdrop, .detail-blade, .view-details-btn, .search-field, .filter-pills, .advanced { display: none !important; }
  .finding-full { display: block !important; }
  .finding, .finding-group { break-inside: avoid; border-color: #999 !important; }
  .finding-group > summary::before, .finding-group > summary .fg-counts { display: none !important; }
  .findings-empty { display: none !important; }
  .site-header, .card, .hero, .result, .gate, .stat { box-shadow: none !important; border-color: #999 !important; }
  .section { break-inside: avoid-page; margin: 16px 0; }
  .result { break-inside: avoid; }
  details, .result { open: true; }
  details > *:not(summary) { display: block !important; }
  .result-body { display: block !important; }
  a.doc-link::after, a.source-link::after { content: " (" attr(href) ")"; font-size: .85em; color: #333; word-break: break-all; }
  .hero, .card { page-break-inside: avoid; }
  thead { display: table-header-group; }
  .workspace-nav, .cc-actions, .command-actions, .tool-actions, .pi-open, .pi-check, .local-progress-notice { display: none !important; }
  .answer-values, .answer-fields { display: none !important; }
  .command-center { display: block !important; box-shadow: none !important; border-color: #999 !important; }
  .command-center::before { display: none !important; }
  .path-phase::before { display: none !important; }
  .path-item, .answer-gate, .command-center, .path-phase { break-inside: avoid; }
  .rerun-code { border-color: #999 !important; }
  .guidance-backdrop, .guidance-dialog, .review-guidance-btn { display: none !important; }
  .guidance-appendix { display: block !important; }
  .guidance-doc { break-inside: avoid; border-color: #999 !important; }
  .guidance-doc-inner { display: block !important; }
}
'@
    return $css
}

#endregion Static assets
#region Inline script

function Get-A365Script {
    $js = @'
(function () {
  "use strict";
  var root = document.documentElement;
  root.classList.remove("no-js");
  root.classList.add("js");

  // Shared handle so Path-to-Ready rows can reuse the findings blade.
  var findingsApi = null;
  // Guidance dialog state, kept distinct from the finding blade so the two
  // modals never conflict (findings keyboard shortcuts defer while it is open).
  var guidanceState = { open: false };

  var STORAGE_KEY = "a365-theme";
  var toggle = document.getElementById("themeToggle");

  function systemPrefersDark() {
    return window.matchMedia && window.matchMedia("(prefers-color-scheme: dark)").matches;
  }

  function stored() {
    try { return window.localStorage.getItem(STORAGE_KEY); } catch (e) { return null; }
  }

  function effective() {
    var s = stored();
    if (s === "light" || s === "dark") { return s; }
    return systemPrefersDark() ? "dark" : "light";
  }

  function apply(theme) {
    if (theme === "light" || theme === "dark") {
      root.setAttribute("data-theme", theme);
    } else {
      root.removeAttribute("data-theme");
    }
    if (toggle) {
      var isDark = effective() === "dark";
      toggle.setAttribute("aria-pressed", isDark ? "true" : "false");
      var label = toggle.querySelector(".tt-label");
      if (label) { label.textContent = isDark ? "Light theme" : "Dark theme"; }
      var icon = toggle.querySelector(".tt-icon");
      if (icon) { icon.textContent = isDark ? "\u263C" : "\u263D"; }
    }
  }

  apply(stored());

  if (toggle) {
    toggle.hidden = false;
    toggle.addEventListener("click", function () {
      var next = effective() === "dark" ? "light" : "dark";
      try { window.localStorage.setItem(STORAGE_KEY, next); } catch (e) {}
      apply(next);
    });
  }

  if (window.matchMedia) {
    var mq = window.matchMedia("(prefers-color-scheme: dark)");
    var onChange = function () { if (!stored()) { apply(null); } };
    if (mq.addEventListener) { mq.addEventListener("change", onChange); }
    else if (mq.addListener) { mq.addListener(onChange); }
  }

  var printExpanded = false;
  function openAllDetails() {
    if (printExpanded) { return; }
    printExpanded = true;
    var all = document.querySelectorAll("details");
    for (var i = 0; i < all.length; i++) {
      all[i].setAttribute("data-print-was-open", all[i].open ? "1" : "0");
      all[i].open = true;
    }
  }
  function restoreDetails() {
    if (!printExpanded) { return; }
    printExpanded = false;
    var all = document.querySelectorAll("details");
    for (var i = 0; i < all.length; i++) {
      if (all[i].getAttribute("data-print-was-open") === "0") { all[i].open = false; }
      all[i].removeAttribute("data-print-was-open");
    }
  }
  if (window.matchMedia) {
    var printMq = window.matchMedia("print");
    if (printMq.addEventListener) {
      printMq.addEventListener("change", function (e) { if (e.matches) { openAllDetails(); } else { restoreDetails(); } });
    }
  }
  window.addEventListener("beforeprint", openAllDetails);
  window.addEventListener("afterprint", restoreDetails);

  var expandAll = document.getElementById("expandAll");
  var groupEls = Array.prototype.slice.call(document.querySelectorAll("[data-result-group]"));
  if (expandAll && groupEls.length) {
    expandAll.hidden = false;
    expandAll.addEventListener("click", function () {
      var pressed = expandAll.getAttribute("aria-pressed") === "true";
      var next = !pressed;
      for (var i = 0; i < groupEls.length; i++) { groupEls[i].open = next; }
      expandAll.setAttribute("aria-pressed", next ? "true" : "false");
      var lbl = expandAll.querySelector(".ea-label");
      if (lbl) { lbl.textContent = next ? "Collapse all" : "Expand all"; }
    });
  }

  // ---- Findings: search, filters, and detail blade ----
  var findingsRoot = document.getElementById("findings");
  if (findingsRoot) {
    var searchInput = document.getElementById("resultSearch");
    var clearSearch = document.getElementById("clearSearch");
    var command = findingsRoot.querySelector(".findings-command");
    var statusFilters = Array.prototype.slice.call(document.querySelectorAll("[data-status-filter]"));
    var pillarFilter = document.getElementById("pillarFilter");
    var areaFilter = document.getElementById("areaFilter");
    var profileFilter = document.getElementById("profileFilter");
    var resetFilters = document.getElementById("resetFilters");
    var resultCount = document.getElementById("filterResultCount");
    var emptyMsg = document.getElementById("findingsEmpty");
    var groups = Array.prototype.slice.call(findingsRoot.querySelectorAll("[data-result-group]"));
    var cards = Array.prototype.slice.call(findingsRoot.querySelectorAll("[data-result-card]"));
    var totalCards = cards.length;
    var activeStatus = "all";

    // Collapse "clean" groups when JS is active; no-JS keeps them open for full visibility.
    for (var gi = 0; gi < groups.length; gi++) {
      if (groups[gi].getAttribute("data-clean") === "1") { groups[gi].open = false; }
    }

    // Explicit expanded-state hooks (JS-enhanced only; native <details> keeps no-JS ARIA correct).
    function directSummary(det) {
      var ch = det.children, x;
      for (x = 0; x < ch.length; x++) {
        if ((ch[x].tagName || "").toLowerCase() === "summary") { return ch[x]; }
      }
      return null;
    }
    function bindExpanded(det) {
      if (!det) { return; }
      var sm = directSummary(det);
      if (!sm) { return; }
      sm.setAttribute("aria-expanded", det.open ? "true" : "false");
      det.addEventListener("toggle", function () {
        sm.setAttribute("aria-expanded", det.open ? "true" : "false");
      });
    }
    for (var ge = 0; ge < groups.length; ge++) { bindExpanded(groups[ge]); }
    bindExpanded(findingsRoot.querySelector("details.advanced"));

    if (command) { command.hidden = false; }

    function isTyping(el) {
      if (!el) { return false; }
      var tag = (el.tagName || "").toLowerCase();
      return tag === "input" || tag === "textarea" || tag === "select" || el.isContentEditable === true;
    }

    function statusMatches(cardStatus) {
      if (activeStatus === "all") { return true; }
      if (activeStatus === "autherror") { return cardStatus === "NotAuthorized" || cardStatus === "Error"; }
      return cardStatus === activeStatus;
    }

    function apply() {
      var q = (searchInput ? searchInput.value : "").toLowerCase().replace(/^\s+|\s+$/g, "");
      var pillarV = pillarFilter ? pillarFilter.value : "";
      var areaV = areaFilter ? areaFilter.value : "";
      var profileV = profileFilter ? profileFilter.value : "";
      var filtering = !!(q || activeStatus !== "all" || pillarV || areaV || profileV);
      var visible = 0;
      var i, c, ok;
      for (i = 0; i < cards.length; i++) {
        c = cards[i];
        ok = statusMatches(c.getAttribute("data-status") || "");
        if (ok && q) { ok = (c.getAttribute("data-result-search") || "").indexOf(q) !== -1; }
        if (ok && pillarV) { ok = (c.getAttribute("data-pillar") || "") === pillarV; }
        if (ok && areaV) { ok = (c.getAttribute("data-area") || "") === areaV; }
        if (ok && profileV) { ok = (" " + (c.getAttribute("data-profiles") || "") + " ").indexOf(" " + profileV + " ") !== -1; }
        c.hidden = !ok;
        if (ok) { visible++; }
      }
      for (i = 0; i < groups.length; i++) {
        var grp = groups[i];
        var any = grp.querySelector("[data-result-card]:not([hidden])");
        grp.hidden = !any;
        if (any && filtering) { grp.open = true; }
      }
      if (resultCount) {
        if (visible === totalCards) {
          resultCount.textContent = "Showing all " + totalCards + " finding" + (totalCards === 1 ? "" : "s");
        } else {
          resultCount.textContent = "Showing " + visible + " of " + totalCards + " findings";
        }
      }
      if (emptyMsg) { emptyMsg.hidden = visible !== 0; }
      if (clearSearch) { clearSearch.hidden = !(searchInput && searchInput.value); }
    }

    var debounceTimer = null;
    function schedule() { if (debounceTimer) { clearTimeout(debounceTimer); } debounceTimer = setTimeout(apply, 70); }

    if (searchInput) {
      searchInput.addEventListener("input", schedule);
      searchInput.addEventListener("keydown", function (e) {
        if (e.key === "Escape" || e.keyCode === 27) {
          if (searchInput.value) { searchInput.value = ""; apply(); e.stopPropagation(); }
          else { searchInput.blur(); }
        }
      });
    }
    if (clearSearch) {
      clearSearch.addEventListener("click", function () {
        if (searchInput) { searchInput.value = ""; searchInput.focus(); }
        apply();
      });
    }
    function onStatusClick(e) {
      var btn = e.currentTarget;
      activeStatus = btn.getAttribute("data-status-filter") || "all";
      for (var k = 0; k < statusFilters.length; k++) {
        statusFilters[k].setAttribute("aria-pressed", statusFilters[k] === btn ? "true" : "false");
      }
      apply();
    }
    for (var s = 0; s < statusFilters.length; s++) {
      statusFilters[s].addEventListener("click", onStatusClick);
    }
    if (pillarFilter) { pillarFilter.addEventListener("change", apply); }
    if (areaFilter) { areaFilter.addEventListener("change", apply); }
    if (profileFilter) { profileFilter.addEventListener("change", apply); }
    if (resetFilters) {
      resetFilters.addEventListener("click", function () {
        if (searchInput) { searchInput.value = ""; }
        if (pillarFilter) { pillarFilter.value = ""; }
        if (areaFilter) { areaFilter.value = ""; }
        if (profileFilter) { profileFilter.value = ""; }
        activeStatus = "all";
        for (var k = 0; k < statusFilters.length; k++) {
          statusFilters[k].setAttribute("aria-pressed", (statusFilters[k].getAttribute("data-status-filter") === "all") ? "true" : "false");
        }
        apply();
        if (searchInput) { searchInput.focus(); }
      });
    }

    // ---- Detail blade ----
    var blade = document.getElementById("detailBlade");
    var backdrop = document.getElementById("detailBackdrop");
    var bladeClose = document.getElementById("detailClose");
    var bladeTitle = document.getElementById("detailBladeTitle");
    var bladeStatus = document.getElementById("detailBladeStatus");
    var bladeBody = document.getElementById("detailBladeBody");
    var bladeOpen = false;
    var lastTrigger = null;
    var inertTargets = [];
    var supportsInert = ("inert" in HTMLElement.prototype);

    if (blade) { blade.hidden = false; }
    if (backdrop) { backdrop.hidden = false; }

    function closestCard(el) {
      while (el && el.nodeType === 1) {
        if (el.getAttribute && el.getAttribute("data-result-card") !== null && el.hasAttribute("data-result-card")) { return el; }
        el = el.parentNode;
      }
      return null;
    }

    function bladeFocusables() {
      var list = Array.prototype.slice.call(blade.querySelectorAll(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), summary, [tabindex]'
      ));
      return list.filter(function (el) {
        if (el.hasAttribute("disabled")) { return false; }
        if (el.getAttribute("tabindex") === "-1") { return false; }
        return el.offsetWidth > 0 || el.offsetHeight > 0 || el === document.activeElement;
      });
    }

    function applyInert(on) {
      var kids = document.body.children;
      if (on) {
        inertTargets = [];
        for (var i = 0; i < kids.length; i++) {
          var el = kids[i];
          if (el === blade || el === backdrop || el.tagName === "SCRIPT") { continue; }
          inertTargets.push(el);
          if (supportsInert) { el.inert = true; }
          el.setAttribute("aria-hidden", "true");
        }
      } else {
        for (var j = 0; j < inertTargets.length; j++) {
          if (supportsInert) { inertTargets[j].inert = false; }
          inertTargets[j].removeAttribute("aria-hidden");
        }
        inertTargets = [];
      }
    }

    function openBlade(card, trigger) {
      if (!blade || !card) { return; }
      lastTrigger = trigger || null;
      if (bladeTitle) { bladeTitle.textContent = card.getAttribute("data-title") || "Finding details"; }
      if (bladeStatus) {
        bladeStatus.textContent = "";
        var pill = card.querySelector(".finding-status .pill");
        if (pill) { bladeStatus.appendChild(pill.cloneNode(true)); }
      }
      if (bladeBody) {
        bladeBody.textContent = "";
        var full = card.querySelector("[data-result-full]");
        if (full) {
          var clone = full.cloneNode(true);
          clone.hidden = false;
          clone.removeAttribute("data-result-full");
          clone.className = "blade-detail";
          bladeBody.appendChild(clone);
        }
      }
      if (backdrop) { backdrop.classList.add("open"); }
      blade.classList.add("open");
      blade.setAttribute("aria-hidden", "false");
      document.body.classList.add("blade-open");
      applyInert(true);
      bladeOpen = true;
      if (bladeBody) { bladeBody.scrollTop = 0; }
      focusBladeClose();
    }

    function focusBladeClose() {
      // Defer initial focus until after the blade's visibility change is applied.
      // Chromium will not move focus into an element that is still transitioning
      // from visibility:hidden, leaving activeElement on the opener. rAF runs it
      // post-style/paint; setTimeout is a background-tab fallback. Guarded by
      // bladeOpen so a fast open/close cannot steal focus after closing.
      var done = false;
      function run() {
        if (done) { return; }
        done = true;
        if (bladeOpen && bladeClose && document.activeElement !== bladeClose) {
          bladeClose.focus();
        }
      }
      if (window.requestAnimationFrame) {
        requestAnimationFrame(function () { requestAnimationFrame(run); });
      }
      setTimeout(run, 60);
    }

    function closeBlade() {
      if (!bladeOpen || !blade) { return; }
      blade.classList.remove("open");
      if (backdrop) { backdrop.classList.remove("open"); }
      blade.setAttribute("aria-hidden", "true");
      document.body.classList.remove("blade-open");
      applyInert(false);
      bladeOpen = false;
      if (bladeBody) { bladeBody.textContent = ""; }
      var t = lastTrigger;
      lastTrigger = null;
      if (t && typeof t.focus === "function") { t.focus(); }
    }

    var viewButtons = Array.prototype.slice.call(document.querySelectorAll("[data-view-details]"));
    for (var v = 0; v < viewButtons.length; v++) {
      viewButtons[v].hidden = false;
      viewButtons[v].addEventListener("click", function (e) {
        var card = closestCard(e.currentTarget);
        openBlade(card, e.currentTarget);
      });
    }
    if (backdrop) { backdrop.addEventListener("click", closeBlade); }
    if (bladeClose) { bladeClose.addEventListener("click", closeBlade); }

    // Expose blade opening so Path-to-Ready "Open details" rows reuse it safely.
    findingsApi = {
      openById: function (id, trigger) {
        var card = document.getElementById(id);
        if (card) { openBlade(card, trigger); }
      }
    };

    document.addEventListener("keydown", function (e) {
      if (guidanceState.open) { return; }
      if (bladeOpen) {
        if (e.key === "Escape" || e.keyCode === 27) { e.preventDefault(); closeBlade(); return; }
        if (e.key === "Tab" || e.keyCode === 9) {
          var f = bladeFocusables();
          if (!f.length) { e.preventDefault(); if (bladeClose) { bladeClose.focus(); } return; }
          var first = f[0], last = f[f.length - 1];
          if (!blade.contains(document.activeElement)) { e.preventDefault(); first.focus(); return; }
          if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
          else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
        }
        return;
      }
      if ((e.key === "/" || e.keyCode === 191) && !isTyping(e.target)) {
        if (searchInput) { e.preventDefault(); searchInput.focus(); searchInput.select(); }
      }
    });

    // ---- Deep-link: open the containing group and reveal a targeted finding ----
    function revealHash() {
      var h = location.hash;
      if (!h || h.length < 2) { return; }
      var target = document.getElementById(h.substring(1));
      if (!target) { return; }
      var g = target;
      while (g && g.nodeType === 1) {
        if (g.getAttribute && g.hasAttribute("data-result-group")) { g.open = true; break; }
        g = g.parentNode;
      }
      if (target.hasAttribute && target.hasAttribute("data-result-card")) { target.hidden = false; }
      if (typeof target.scrollIntoView === "function") {
        try { target.scrollIntoView({ block: "start" }); } catch (err) { target.scrollIntoView(); }
      }
    }
    window.addEventListener("hashchange", revealHash);
    if (location.hash && (location.hash.indexOf("#check-") === 0 || location.hash.indexOf("#area-") === 0)) {
      revealHash();
    }

    apply();
  }

  // ---- Shared offline helpers (no network, no eval) ----
  function trimStr(s) { return (s == null ? "" : String(s)).replace(/^\s+|\s+$/g, ""); }
  function setFeedbackEl(el, msg, kind) {
    if (!el) { return; }
    el.textContent = msg;
    el.className = "tool-feedback" + (kind ? (" is-" + kind) : "");
  }
  function offlineDownload(filename, mime, text) {
    try {
      var blob = new Blob([text], { type: mime });
      var maker = window.URL || window.webkitURL;
      var url = maker.createObjectURL(blob);
      var a = document.createElement("a");
      a.href = url;
      a.download = filename;
      document.body.appendChild(a);
      a.click();
      document.body.removeChild(a);
      setTimeout(function () { try { maker.revokeObjectURL(url); } catch (e) {} }, 4000);
      return true;
    } catch (e) { return false; }
  }
  function fallbackCopy(text) {
    try {
      var ta = document.createElement("textarea");
      ta.value = text;
      ta.setAttribute("readonly", "");
      ta.style.position = "absolute";
      ta.style.left = "-9999px";
      document.body.appendChild(ta);
      ta.select();
      var ok = document.execCommand && document.execCommand("copy");
      document.body.removeChild(ta);
      return !!ok;
    } catch (e) { return false; }
  }
  function copyText(text, cb) {
    if (navigator.clipboard && navigator.clipboard.writeText) {
      navigator.clipboard.writeText(text).then(function () { cb(true); }, function () { cb(fallbackCopy(text)); });
      return;
    }
    cb(fallbackCopy(text));
  }
  function closestAttr(el, attr) {
    while (el && el.nodeType === 1) {
      if (el.getAttribute && el.hasAttribute(attr)) { return el; }
      el = el.parentNode;
    }
    return null;
  }

  // ---- Path to Ready: local progress + open details ----
  var pathRoot = document.getElementById("pathToReady");
  if (pathRoot) {
    var reportKey = pathRoot.getAttribute("data-report-key") || "default";
    var progressPrefix = "a365-progress:" + reportKey + ":";
    var completes = Array.prototype.slice.call(pathRoot.querySelectorAll("[data-local-complete]"));

    function progressGet(id) {
      try { return window.localStorage.getItem(progressPrefix + id) === "1"; } catch (e) { return false; }
    }
    function progressSet(id, on) {
      try {
        if (on) { window.localStorage.setItem(progressPrefix + id, "1"); }
        else { window.localStorage.removeItem(progressPrefix + id); }
      } catch (e) {}
    }
    function setRowComplete(box) {
      var row = closestAttr(box, "data-path-item");
      if (row && row.classList) {
        if (box.checked) { row.classList.add("is-complete"); } else { row.classList.remove("is-complete"); }
      }
    }
    for (var pci = 0; pci < completes.length; pci++) {
      var box = completes[pci];
      if (box.parentNode && box.parentNode.hidden) { box.parentNode.hidden = false; }
      var cid = box.getAttribute("data-item-id") || "";
      if (progressGet(cid)) { box.checked = true; }
      setRowComplete(box);
      box.addEventListener("change", function (e) {
        var b = e.currentTarget;
        progressSet(b.getAttribute("data-item-id") || "", b.checked);
        setRowComplete(b);
      });
    }
    var resetProgress = document.getElementById("resetLocalProgress");
    if (resetProgress) {
      resetProgress.hidden = false;
      resetProgress.addEventListener("click", function () {
        try {
          var keys = [];
          for (var k = 0; k < window.localStorage.length; k++) {
            var key = window.localStorage.key(k);
            if (key && key.indexOf(progressPrefix) === 0) { keys.push(key); }
          }
          for (var m = 0; m < keys.length; m++) { window.localStorage.removeItem(keys[m]); }
        } catch (e) {}
        for (var n = 0; n < completes.length; n++) { completes[n].checked = false; setRowComplete(completes[n]); }
      });
    }
    var pathOpeners = Array.prototype.slice.call(pathRoot.querySelectorAll("[data-open-finding]"));
    for (var po = 0; po < pathOpeners.length; po++) {
      pathOpeners[po].hidden = false;
      pathOpeners[po].addEventListener("click", function (e) {
        var id = e.currentTarget.getAttribute("data-open-finding");
        if (findingsApi && id) { findingsApi.openById(id, e.currentTarget); }
      });
    }
  }

  // ---- Answers builder: in-memory + offline JSON download ----
  var answersRoot = document.getElementById("answersBuilder");
  if (answersRoot) {
    answersRoot.hidden = false;
    var downloadAnswers = document.getElementById("downloadAnswers");
    var answersFeedback = document.getElementById("answersFeedback");
    function gateFieldVal(scope, sel) {
      var el = scope.querySelector(sel);
      return el ? trimStr(el.value) : "";
    }
    function gateLabel(g) {
      var t = g.getAttribute("data-answer-gate-title");
      if (t) { return t; }
      return g.getAttribute("data-answer-gate") || "Gate";
    }
    function collectAnswers() {
      var gates = Array.prototype.slice.call(answersRoot.querySelectorAll("[data-answer-gate]"));
      var out = [];
      var errors = [];
      for (var i = 0; i < gates.length; i++) {
        var g = gates[i];
        var id = g.getAttribute("data-answer-gate") || "";
        var val = "";
        var radios = g.querySelectorAll("[data-answer-value]");
        for (var r = 0; r < radios.length; r++) { if (radios[r].checked) { val = radios[r].value; } }
        if (!val) { continue; }
        var owner = gateFieldVal(g, "[data-answer-owner]");
        var reference = gateFieldVal(g, "[data-answer-reference]");
        var notes = gateFieldVal(g, "[data-answer-notes]");
        var justification = gateFieldVal(g, "[data-answer-justification]");
        if (val === "Yes" && (!owner || !reference)) {
          errors.push(gateLabel(g) + ": a Yes answer needs an owner and an evidence reference.");
        }
        if (val === "NotApplicable" && !justification) {
          errors.push(gateLabel(g) + ": a Not applicable answer needs a justification.");
        }
        out.push({
          id: id,
          answer: val,
          owner: owner,
          evidenceReference: reference,
          notes: notes,
          justification: justification,
          answeredAtUtc: new Date().toISOString()
        });
      }
      return { items: out, errors: errors };
    }
    if (downloadAnswers) {
      downloadAnswers.addEventListener("click", function () {
        var res = collectAnswers();
        if (res.errors.length) {
          setFeedbackEl(answersFeedback, res.errors[0] + (res.errors.length > 1 ? " (+" + (res.errors.length - 1) + " more)" : ""), "error");
          return;
        }
        if (!res.items.length) {
          setFeedbackEl(answersFeedback, "Answer at least one gate before downloading.", "error");
          return;
        }
        var payload = { schemaVersion: "1.1", answers: res.items };
        var ok = offlineDownload("agent365-answers.json", "application/json;charset=utf-8", JSON.stringify(payload, null, 2));
        setFeedbackEl(answersFeedback, ok ? ("Downloaded " + res.items.length + " answer" + (res.items.length === 1 ? "" : "s") + ". Re-run the checker with this file to apply them.") : "Download is not available in this browser.", ok ? "ok" : "error");
      });
    }
  }

  // ---- Answer guidance dialog: a semantically distinct accessible modal cloned
  //      from the always-present guidance appendix (never the finding blade). ----
  var guidanceDialog = document.getElementById("guidanceDialog");
  var guidanceBackdrop = document.getElementById("guidanceBackdrop");
  if (guidanceDialog && guidanceBackdrop) {
    guidanceDialog.hidden = false;
    guidanceBackdrop.hidden = false;
    var gClose = document.getElementById("guidanceClose");
    var gBack = document.getElementById("guidanceBack");
    var gCopy = document.getElementById("guidanceCopy");
    var gCopyFeedback = document.getElementById("guidanceCopyFeedback");
    var gTitleEl = document.getElementById("guidanceTitle");
    var gMetaEl = document.getElementById("guidanceMeta");
    var gBodyEl = document.getElementById("guidanceBody");
    var gTrigger = null;   // the Review guidance button that opened the dialog
    var gGate = null;      // the owning .answer-gate (for focus return to first radio)
    var gInertTargets = [];
    var gSupportsInert = ("inert" in HTMLElement.prototype);

    function gFocusables() {
      var list = Array.prototype.slice.call(guidanceDialog.querySelectorAll(
        'a[href], button:not([disabled]), input:not([disabled]), select:not([disabled]), textarea:not([disabled]), summary, [tabindex]'
      ));
      return list.filter(function (el) {
        if (el.hasAttribute("disabled")) { return false; }
        if (el.getAttribute("tabindex") === "-1") { return false; }
        if (el.hidden) { return false; }
        return el.offsetWidth > 0 || el.offsetHeight > 0 || el === document.activeElement;
      });
    }

    function gApplyInert(on) {
      var kids = document.body.children;
      if (on) {
        gInertTargets = [];
        for (var i = 0; i < kids.length; i++) {
          var el = kids[i];
          if (el === guidanceDialog || el === guidanceBackdrop || el.tagName === "SCRIPT") { continue; }
          gInertTargets.push(el);
          if (gSupportsInert) { el.inert = true; }
          el.setAttribute("aria-hidden", "true");
        }
      } else {
        for (var j = 0; j < gInertTargets.length; j++) {
          if (gSupportsInert) { gInertTargets[j].inert = false; }
          gInertTargets[j].removeAttribute("aria-hidden");
        }
        gInertTargets = [];
      }
    }

    function gFocusClose() {
      // Same deferred-focus rationale as the finding blade: visibility change must
      // settle before focus can move into the dialog.
      var done = false;
      function run() {
        if (done) { return; }
        done = true;
        if (guidanceState.open && gClose && document.activeElement !== gClose) { gClose.focus(); }
      }
      if (window.requestAnimationFrame) { requestAnimationFrame(function () { requestAnimationFrame(run); }); }
      setTimeout(run, 60);
    }

    function openGuidance(docId, trigger) {
      var src = document.getElementById(docId);
      if (!src) { return; }
      gTrigger = trigger || null;
      gGate = closestAttr(trigger, "data-answer-gate");
      // Header: question, status pill, gate id, owning role. No speculative estimate.
      if (gTitleEl) { gTitleEl.textContent = src.getAttribute("data-guidance-title") || "Answer guidance"; }
      if (gMetaEl) {
        gMetaEl.textContent = "";
        var pillWrap = src.querySelector("[data-guidance-pill]");
        if (pillWrap) {
          var pill = pillWrap.querySelector(".pill");
          if (pill) { gMetaEl.appendChild(pill.cloneNode(true)); }
        }
        var gid = src.getAttribute("data-guidance-gateid") || "";
        if (gid) {
          var idEl = document.createElement("span");
          idEl.className = "guidance-meta-id mono";
          idEl.textContent = gid;
          gMetaEl.appendChild(idEl);
        }
        var role = src.getAttribute("data-guidance-role") || "";
        if (role) {
          var roleEl = document.createElement("span");
          roleEl.className = "guidance-meta-role";
          roleEl.textContent = "Owner: " + role;
          gMetaEl.appendChild(roleEl);
        }
      }
      var hasEvidence = false;
      if (gBodyEl) {
        gBodyEl.textContent = "";
        var body = src.querySelector("[data-guidance-body]");
        if (body) {
          var clone = body.cloneNode(true);
          clone.removeAttribute("data-guidance-body");
          clone.className = "guidance-clone";
          gBodyEl.appendChild(clone);
          hasEvidence = !!clone.querySelector("[data-guidance-evidence-item]");
        }
        gBodyEl.scrollTop = 0;
      }
      if (gCopy) { gCopy.hidden = !hasEvidence; }
      if (gCopyFeedback) { gCopyFeedback.textContent = ""; }
      guidanceBackdrop.classList.add("open");
      guidanceDialog.classList.add("open");
      guidanceDialog.setAttribute("aria-hidden", "false");
      document.body.classList.add("guidance-open");
      gApplyInert(true);
      guidanceState.open = true;
      gFocusClose();
    }

    function closeGuidance() {
      if (!guidanceState.open) { return; }
      guidanceDialog.classList.remove("open");
      guidanceBackdrop.classList.remove("open");
      guidanceDialog.setAttribute("aria-hidden", "true");
      document.body.classList.remove("guidance-open");
      gApplyInert(false);
      guidanceState.open = false;
      if (gBodyEl) { gBodyEl.textContent = ""; }
      if (gMetaEl) { gMetaEl.textContent = ""; }
      // Restore focus to the exact gate, then move to its first answer radio WITHOUT
      // selecting it (focus only, never .click(), so no verdict input is mutated).
      var gate = gGate;
      var trigger = gTrigger;
      gGate = null;
      gTrigger = null;
      var radio = gate ? gate.querySelector("[data-answer-value]") : null;
      if (radio && typeof radio.focus === "function") { radio.focus(); }
      else if (trigger && typeof trigger.focus === "function") { trigger.focus(); }
    }

    var gOpeners = Array.prototype.slice.call(document.querySelectorAll("[data-guidance-open]"));
    for (var go = 0; go < gOpeners.length; go++) {
      gOpeners[go].addEventListener("click", function (e) {
        var btn = e.currentTarget;
        openGuidance(btn.getAttribute("data-guidance-open"), btn);
      });
    }
    if (gClose) { gClose.addEventListener("click", closeGuidance); }
    if (gBack) { gBack.addEventListener("click", closeGuidance); }
    guidanceBackdrop.addEventListener("click", closeGuidance);

    if (gCopy) {
      gCopy.addEventListener("click", function () {
        var items = gBodyEl ? Array.prototype.slice.call(gBodyEl.querySelectorAll("[data-guidance-evidence-item]")) : [];
        if (!items.length) { if (gCopyFeedback) { gCopyFeedback.textContent = "No evidence checklist to copy."; } return; }
        var out = [];
        for (var i = 0; i < items.length; i++) {
          var t = trimStr(items[i].textContent);
          if (t) { out.push("- [ ] " + t); }
        }
        copyText(out.join("\n"), function (ok) {
          if (gCopyFeedback) { gCopyFeedback.textContent = ok ? "Evidence checklist copied." : "Copy is unavailable — select the text manually."; }
        });
      });
    }

    // Guidance-scoped keyboard handling: Escape closes, Tab is trapped within.
    document.addEventListener("keydown", function (e) {
      if (!guidanceState.open) { return; }
      if (e.key === "Escape" || e.keyCode === 27) { e.preventDefault(); closeGuidance(); return; }
      if (e.key === "Tab" || e.keyCode === 9) {
        var f = gFocusables();
        if (!f.length) { e.preventDefault(); if (gClose) { gClose.focus(); } return; }
        var first = f[0], last = f[f.length - 1];
        if (!guidanceDialog.contains(document.activeElement)) { e.preventDefault(); first.focus(); return; }
        if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
        else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
      }
    });

    // Progressive collapse: the appendix is expanded for no-JS and print, but once
    // the interactive dialog is wired we collapse the inline copies to reduce noise.
    var gDocs = Array.prototype.slice.call(document.querySelectorAll("[data-guidance-doc]"));
    for (var gd = 0; gd < gDocs.length; gd++) {
      if (gDocs[gd].tagName === "DETAILS") { gDocs[gd].open = false; }
    }
  }

  // ---- Rerun command: copy + remediation checklist download ----
  var rerunCmdEl = document.getElementById("rerunCommand");
  var rerunFeedback = document.getElementById("rerunFeedback");
  var copyRerun = document.getElementById("copyRerunCommand");
  if (copyRerun && rerunCmdEl) {
    copyRerun.hidden = false;
    copyRerun.addEventListener("click", function () {
      copyText(rerunCmdEl.textContent || "", function (ok) {
        setFeedbackEl(rerunFeedback, ok ? "Command copied to the clipboard." : "Copy is unavailable — select the command text manually.", ok ? "ok" : "error");
      });
    });
  }
  var downloadRemediation = document.getElementById("downloadRemediation");
  if (downloadRemediation) {
    function buildRemediationMarkdown() {
      var lines = ["# Agent 365 pre-flight remediation checklist", ""];
      // Map manual-gate id -> its guidance appendix entry so each unresolved action
      // can carry its acceptance criteria and evidence-to-retain steps.
      var guidanceById = {};
      var gdocs = Array.prototype.slice.call(document.querySelectorAll("[data-guidance-doc]"));
      for (var gi = 0; gi < gdocs.length; gi++) {
        var gkey = gdocs[gi].getAttribute("data-guidance-gateid") || "";
        if (gkey && !guidanceById[gkey]) { guidanceById[gkey] = gdocs[gi]; }
      }
      var pr = document.getElementById("pathToReady");
      if (pr) {
        var items = Array.prototype.slice.call(pr.querySelectorAll("[data-path-item]"));
        if (!items.length) { lines.push("No outstanding actions were listed."); }
        for (var i = 0; i < items.length; i++) {
          var it = items[i];
          var titleEl = it.querySelector("[data-pi-title]");
          var remEl = it.querySelector("[data-pi-remediation]");
          var statusLabel = it.getAttribute("data-pi-status") || "";
          var ownerLabel = it.getAttribute("data-pi-owner") || "";
          var box = it.querySelector("[data-local-complete]");
          var mark = (box && box.checked) ? "x" : " ";
          var title = titleEl ? trimStr(titleEl.textContent) : "Action";
          var line = "- [" + mark + "] ";
          if (statusLabel) { line += "(" + statusLabel + ") "; }
          line += title;
          lines.push(line);
          if (remEl) { var rem = trimStr(remEl.textContent); if (rem) { lines.push("  - Remediation: " + rem); } }
          if (ownerLabel) { lines.push("  - Owner: " + ownerLabel); }
          // Unresolved manual gates carry their acceptance criteria + evidence steps.
          var itemId = box ? (box.getAttribute("data-item-id") || "") : "";
          var resolved = !!(box && box.checked);
          var gdoc = itemId ? guidanceById[itemId] : null;
          if (gdoc && !resolved) {
            var yes = Array.prototype.slice.call(gdoc.querySelectorAll("[data-guidance-yes-item]"));
            if (yes.length) {
              lines.push("  - Acceptance criteria:");
              for (var y = 0; y < yes.length; y++) { var yt = trimStr(yes[y].textContent); if (yt) { lines.push("    - " + yt); } }
            }
            var ev = Array.prototype.slice.call(gdoc.querySelectorAll("[data-guidance-evidence-item]"));
            if (ev.length) {
              lines.push("  - Evidence to retain:");
              for (var ei = 0; ei < ev.length; ei++) { var et = trimStr(ev[ei].textContent); if (et) { lines.push("    - " + et); } }
            }
          }
        }
      }
      lines.push("");
      lines.push("_Local check state is a personal note only. It does not change the verdict; re-run the checker to confirm._");
      return lines.join("\n");
    }
    downloadRemediation.hidden = false;
    downloadRemediation.addEventListener("click", function () {
      var ok = offlineDownload("agent365-remediation.md", "text/markdown;charset=utf-8", buildRemediationMarkdown());
      setFeedbackEl(rerunFeedback, ok ? "Remediation checklist downloaded." : "Download is not available in this browser.", ok ? "ok" : "error");
    });
  }

  // ---- Workspace nav: reflect the section in view (guarded, optional) ----
  var wsNav = document.getElementById("workspaceNav");
  if (wsNav && window.IntersectionObserver) {
    var wsLinks = Array.prototype.slice.call(wsNav.querySelectorAll('a[href^="#"]'));
    var wsMap = {};
    var wsSections = [];
    for (var wi = 0; wi < wsLinks.length; wi++) {
      var wid = wsLinks[wi].getAttribute("href").substring(1);
      var wsec = document.getElementById(wid);
      if (wsec) { wsMap[wid] = wsLinks[wi]; wsSections.push(wsec); }
    }
    var wsCurrent = null;
    var wsObs = new IntersectionObserver(function (entries) {
      for (var e = 0; e < entries.length; e++) {
        if (entries[e].isIntersecting) {
          var id = entries[e].target.id;
          if (wsCurrent && wsMap[wsCurrent]) { wsMap[wsCurrent].removeAttribute("aria-current"); }
          wsCurrent = id;
          if (wsMap[id]) { wsMap[id].setAttribute("aria-current", "true"); }
        }
      }
    }, { rootMargin: "-45% 0px -50% 0px", threshold: 0 });
    for (var ws = 0; ws < wsSections.length; ws++) { wsObs.observe(wsSections[ws]); }
  }
})();
'@
    return $js
}

#endregion Inline script
#region Public function

function Get-A365FirstMember {
    <# Read a member from the first source object that provides a non-null value. #>
    [CmdletBinding()]
    param(
        [object[]]$Sources,
        [string]$Name,
        [object]$Default = $null
    )

    foreach ($source in $Sources) {
        if ($null -eq $source) { continue }
        $value = Get-A365Member -Object $source -Name $Name -Default $null
        if ($null -ne $value) { return $value }
    }
    return $Default
}

function New-Agent365PreflightHtml {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object]$Report,
        [Parameter(Mandatory)][string]$Path,
        [switch]$Sanitized
    )

    $enc = { param($v) ConvertTo-A365Html $v }

    # --- Metadata (may be nested under .Metadata or flattened on the report) ---
    $metadata = Get-A365Member $Report 'Metadata'
    $metaSources = @($metadata, $Report)

    $schemaVersion  = Get-A365FirstMember $metaSources 'SchemaVersion'
    $toolVersion    = Get-A365FirstMember $metaSources 'ToolVersion'
    $generatedAtUtc = Get-A365FirstMember $metaSources 'GeneratedAtUtc'
    $ruleSetVersion = Get-A365FirstMember $metaSources 'RuleSetVersion'
    $ruleReviewDate = Get-A365FirstMember $metaSources 'RuleReviewDate'
    $stage          = Get-A365FirstMember $metaSources 'Stage'
    $profiles       = Get-A365FirstMember $metaSources 'Profiles' @()
    $collectors     = Get-A365FirstMember $metaSources 'Collectors' @()
    $betaEnabled    = Get-A365Bool (Get-A365FirstMember $metaSources 'BetaEnabled')
    $fixtureMode    = Get-A365Bool (Get-A365FirstMember $metaSources 'FixtureMode')
    $reportSanitized = Get-A365Bool (Get-A365FirstMember $metaSources 'Sanitized')

    $isSanitized = $Sanitized.IsPresent -or $reportSanitized

    # --- Section objects ---
    $verdict   = Get-A365Member $Report 'Verdict'
    $tenant    = Get-A365Member $Report 'Tenant'
    $coverage  = Get-A365Member $Report 'Coverage'
    $auth      = Get-A365Member $Report 'Authentication'
    $results   = @(Get-A365Member $Report 'Results' @())
    $actions   = @(Get-A365Member $Report 'Actions' @())
    $attest    = @(Get-A365Member $Report 'ManualAttestations' @())
    $drift     = Get-A365Member $Report 'Drift'
    $sources   = @(Get-A365Member $Report 'Sources' @())
    $issues    = @(Get-A365Member $Report 'CollectionIssues' @())
    $runtime   = Get-A365Member $Report 'Runtime'

    # --- Verdict fields ---
    $verdictLabel   = [string](Get-A365Member $verdict 'Label' '')
    $verdictSummary = [string](Get-A365Member $verdict 'Summary' '')
    $blockerCount   = Get-A365Member $verdict 'BlockerCount' 0
    $actionCount    = Get-A365Member $verdict 'ActionRequiredCount' 0
    $authGapCount   = Get-A365Member $verdict 'AuthorizationGapCount' 0
    $verdictMeta    = Get-A365VerdictMeta $verdictLabel

    # --- Availability gate (non-commercial clouds) ---
    $cloud = [string](Get-A365Member $tenant 'Cloud' '')
    $commercialAvailability = Get-A365Member $tenant 'CommercialAvailability'
    $isCommercialCloud = $true
    if (-not [string]::IsNullOrWhiteSpace($cloud)) {
        $isCommercialCloud = ($cloud -match '(?i)commercial|global|worldwide|public|^ww$')
    }
    if ($null -ne $commercialAvailability) {
        if ($commercialAvailability -is [bool]) {
            $isCommercialCloud = $commercialAvailability
        } else {
            $caText = ([string]$commercialAvailability)
            if ($caText -match '(?i)unavailable|not\s*available|gcc|dod|gov|china|21vianet|sovereign|blocked') { $isCommercialCloud = $false }
            elseif ($caText -match '(?i)available|general\s*availability|\bga\b|commercial') { $isCommercialCloud = $true }
        }
    }

    # --- Derived progressive-action models (graceful when backend fields are absent) ---
    $slugById = @{}
    foreach ($rItem in $results) {
        $ridKey = [string](Get-A365Member $rItem 'Id' '')
        if ($ridKey -and -not $slugById.ContainsKey($ridKey)) {
            $slugById[$ridKey] = 'check-' + (Get-A365Slug $ridKey)
        }
    }
    $reportKeySeed = @($toolVersion, $generatedAtUtc, [string](Get-A365Member $tenant 'DisplayName' ''), $ruleSetVersion) -join '|'
    $reportKey = Get-A365ReportKey $reportKeySeed
    $passModel  = Get-A365PassModel $Report $verdict $results
    $pathPhases = @(Get-A365PathModel $Report $results $slugById | Where-Object { $null -ne $_ })
    $rerunModel = Get-A365RerunModel $Report $isSanitized
    $gateModel  = @(Get-A365GateModel $Report $attest $results)
    $pathItemTotal = 0
    foreach ($ph in $pathPhases) { $pathItemTotal += @($ph.Items).Count }

    $sb = [System.Text.StringBuilder]::new()
    $nl = [Environment]::NewLine
    function local:Line { param($t) [void]$sb.Append($t); [void]$sb.Append($nl) }

    $docTitle = 'Agent 365 pre-flight report'
    $tenantName = [string](Get-A365Member $tenant 'DisplayName' '')
    if (-not [string]::IsNullOrWhiteSpace($tenantName)) { $docTitle = 'Agent 365 pre-flight report - ' + $tenantName }

    Line '<!DOCTYPE html>'
    Line '<html lang="en" class="no-js">'
    Line '<head>'
    Line '<meta charset="utf-8">'
    Line '<meta name="viewport" content="width=device-width, initial-scale=1">'
    Line '<meta name="color-scheme" content="light dark">'
    Line '<meta name="robots" content="noindex, nofollow">'
    Line '<meta name="generator" content="Invoke-Agent365Preflight">'
    Line '<link rel="icon" href="data:,">'
    Line ('<title>' + (ConvertTo-A365Html $docTitle) + '</title>')
    Line '<style>'
    Line (Get-A365Css)
    Line '</style>'
    Line '</head>'
    Line '<body>'
    Line '<a class="skip-link" href="#main">Skip to report content</a>'

    # --- Header ---
    Line '<header class="site-header" role="banner">'
    Line '<div class="wrap">'
    Line '<div class="brand-lockup">'
    Line '<div class="brand-mark" aria-hidden="true">A365</div>'
    Line '<div class="brand-text">'
    Line '<div class="kicker">Microsoft Agent 365</div>'
    Line '<div class="title">Technical pre-flight report</div>'
    Line '</div>'
    Line '</div>'
    Line '<div class="header-meta">'
    if (-not [string]::IsNullOrWhiteSpace($tenantName)) {
        Line ('<span class="hm"><span class="muted">Tenant</span> <b>' + (ConvertTo-A365Html $tenantName) + '</b></span>')
    }
    if ($generatedAtUtc) {
        Line ('<span class="hm"><span class="muted">Generated</span> <b>' + (ConvertTo-A365Html (Format-A365Date $generatedAtUtc)) + '</b></span>')
    }
    if ($toolVersion) {
        Line ('<span class="hm"><span class="muted">Tool</span> <b>' + (ConvertTo-A365Html ('v' + $toolVersion)) + '</b></span>')
    }
    Line '<button type="button" id="themeToggle" class="theme-toggle js-only" hidden aria-pressed="false">'
    Line '<span class="tt-icon" aria-hidden="true">&#x263D;</span><span class="tt-label">Dark theme</span>'
    Line '</button>'
    Line '</div>'
    Line '</div>'
    Line '</header>'

    Line '<div class="wrap">'

    # --- Prominent scope disclaimer ---
    Line '<div class="disclaimer-banner" role="note">'
    Line '<span class="db-icon" aria-hidden="true">&#x2139;</span>'
    Line '<div><strong>This is a technical pre-flight, not a security or compliance certification.</strong> It reports whether the technical prerequisites for a Microsoft Agent 365 pilot appear to be in place at the time of collection. It does not assess, audit, or certify the security or regulatory compliance of your tenant.</div>'
    Line '</div>'

    # --- Badge row ---
    $hasBadges = $isSanitized -or $betaEnabled -or $fixtureMode -or $stage -or $schemaVersion
    if ($hasBadges) {
        Line '<div class="badge-row" style="margin:16px 0;">'
        if ($stage) { Line ('<span class="badge">Stage: ' + (ConvertTo-A365Html $stage) + '</span>') }
        if ($isSanitized) { Line '<span class="badge sanitized">Sanitized report</span>' }
        if ($betaEnabled) { Line '<span class="badge beta">Beta checks enabled</span>' }
        if ($fixtureMode) { Line '<span class="badge fixture">Fixture mode</span>' }
        if ($schemaVersion) { Line ('<span class="badge">Schema ' + (ConvertTo-A365Html $schemaVersion) + '</span>') }
        Line '</div>'
    }

    Line '<main id="main" role="main" tabindex="-1">'
        # --- Readiness Command Center (first-viewport decision surface) ---
    $ccPassSummary = [string]$passModel.Summary
    $ccBlock  = [int]$passModel.BlockerCount
    $ccAction = [int]$passModel.ActionRequiredCount
    $ccAuth   = [int]$passModel.NotAuthorizedCount
    $ccErr    = [int]$passModel.ErrorCount
    $ccManual = [int]$passModel.RequiredManualUnresolvedCount
    $ccSatisfied = [bool]$passModel.IsSatisfied
    $ccCovTotal = Get-A365Int (Get-A365Member $coverage 'Total' 0)
    $ccCovPass  = Get-A365Int (Get-A365Member $coverage 'Passed' 0)
    $ccCovColl  = Get-A365Int (Get-A365Member $coverage 'Collected' 0)
    $ccCovPct   = Get-A365Member $coverage 'Percentage' $null

    Line ('<section id="commandCenter" class="section" aria-labelledby="verdict-h"><div class="command-center ' + $verdictMeta.Class + '">')
    Line ('<span class="cc-badge"><span class="cc-glyph" aria-hidden="true">' + (ConvertTo-A365Html $verdictMeta.Glyph) + '</span>' + $(if ([string]::IsNullOrWhiteSpace($verdictLabel)) { 'Verdict' } else { (ConvertTo-A365Html $verdictLabel) }) + '</span>')
    Line '<div class="cc-body">'
    Line '<p class="kicker muted" style="margin:0;">Pre-flight verdict</p>'
    if ([string]::IsNullOrWhiteSpace($verdictLabel)) {
        Line '<h1 id="verdict-h" class="cc-heading">Verdict unavailable</h1>'
    } else {
        Line ('<h1 id="verdict-h" class="cc-heading">' + (ConvertTo-A365Html $verdictLabel) + '</h1>')
    }
    if (-not [string]::IsNullOrWhiteSpace($verdictSummary)) {
        Line ('<p class="cc-summary">' + (ConvertTo-A365Html $verdictSummary) + '</p>')
    }

    # What prevents a technical pass
    Line '<div class="cc-prevents">'
    Line '<p class="cc-prevents-label">What prevents a technical pass</p>'
    if ($ccSatisfied) {
        Line '<div class="pass-chips"><span class="pass-chip is-ok"><span aria-hidden="true">&#10003;</span> No blockers, gaps, errors, required actions, or unresolved manual validations</span></div>'
    } else {
        Line '<div class="pass-chips">'
        if ($ccBlock -gt 0)  { Line ('<span class="pass-chip s-block"><span class="pc-count">' + $ccBlock + '</span> blocker' + $(if($ccBlock -eq 1){''}else{'s'}) + '</span>') }
        if ($ccAuth -gt 0)   { Line ('<span class="pass-chip s-noauth"><span class="pc-count">' + $ccAuth + '</span> authorization gap' + $(if($ccAuth -eq 1){''}else{'s'}) + '</span>') }
        if ($ccErr -gt 0)    { Line ('<span class="pass-chip s-error"><span class="pc-count">' + $ccErr + '</span> error' + $(if($ccErr -eq 1){''}else{'s'}) + '</span>') }
        if ($ccAction -gt 0) { Line ('<span class="pass-chip s-action"><span class="pc-count">' + $ccAction + '</span> action' + $(if($ccAction -eq 1){''}else{'s'}) + ' required</span>') }
        if ($ccManual -gt 0) { Line ('<span class="pass-chip s-manual"><span class="pc-count">' + $ccManual + '</span> manual validation' + $(if($ccManual -eq 1){''}else{'s'}) + '</span>') }
        Line '</div>'
        if (-not [string]::IsNullOrWhiteSpace($ccPassSummary)) {
            Line ('<p class="small muted" style="margin:2px 0 0;">' + (ConvertTo-A365Html $ccPassSummary) + '</p>')
        }
    }
    Line '</div>'

    # Coverage snapshot (clearly separate from verdict)
    Line '<div class="cc-coverage">'
    if ($ccCovTotal -gt 0) {
        $ccCovWidth = [math]::Round((($ccCovColl / $ccCovTotal) * 100), 1)
        if ($ccCovWidth -lt 0) { $ccCovWidth = 0 } elseif ($ccCovWidth -gt 100) { $ccCovWidth = 100 }
        $ccCovPctText = if ($null -ne $ccCovPct) { (ConvertTo-A365Html $ccCovPct) + '% collected' } else { (ConvertTo-A365Html $ccCovColl) + ' of ' + (ConvertTo-A365Html $ccCovTotal) + ' collected' }
        Line ('<div class="cc-coverage-top"><span>Coverage &middot; <b>' + (ConvertTo-A365Html $ccCovPass) + '</b> passed</span><span>' + $ccCovPctText + '</span></div>')
        Line ('<div class="cc-meter" role="img" aria-label="' + (ConvertTo-A365Html ($ccCovColl.ToString() + ' of ' + $ccCovTotal.ToString() + ' checks collected')) + '"><span style="width:' + $ccCovWidth + '%"></span></div>')
    } else {
        Line '<p class="muted small" style="margin:0;">No coverage reported.</p>'
    }
    Line '<p class="cc-note">Coverage is not the verdict and not a compliance score.</p>'
    Line '</div>'

    # Primary CTA
    Line '<div class="cc-actions">'
    if ($pathItemTotal -gt 0) {
        Line ('<a class="cta-primary" id="openPathToReady" href="#pathToReady">Open Path to Ready <span aria-hidden="true">(' + $pathItemTotal + ')</span></a>')
    } else {
        Line '<a class="cta-primary" id="openPathToReady" href="#pathToReady">View Path to Ready</a>'
    }
    Line '</div>'
    Line '</div>'
    Line '</div></section>'

    # --- Availability gate (non-commercial clouds) ---
    if (-not $isCommercialCloud) {
        $cloudLabel = if ([string]::IsNullOrWhiteSpace($cloud)) { 'this cloud environment' } else { $cloud }
        Line '<section class="section" aria-labelledby="gate-h"><div class="gate" role="note">'
        Line ('<h2 id="gate-h"><span class="gate-glyph" aria-hidden="true">&#x26A0;</span> Agent 365 availability gate</h2>')
        Line ('<p>Microsoft Agent 365 is offered in commercial (worldwide) environments. Based on the detected cloud (<strong>' + (ConvertTo-A365Html $cloudLabel) + '</strong>), Agent 365 may not currently be available for this tenant.</p>')
        Line '<p>Checks that depend on Agent 365 availability are reported as <em>not applicable</em> for this environment rather than as failures, so this report does not show cascading false blockers. Confirm regional availability with your Microsoft account team before planning a pilot.</p>'
        Line '</div></section>'
    }

    # --- Workspace navigation (sticky jump tabs) ---
    Line '<nav id="workspaceNav" class="workspace-nav js-only" aria-label="Report sections" style="display:block;">'
    Line '<ul>'
    Line '<li><a class="wsn-link" href="#scope">Overview</a></li>'
    Line '<li><a class="wsn-link" href="#pathToReady">Path to Ready</a></li>'
    Line '<li><a class="wsn-link" href="#checks">Findings</a></li>'
    Line '<li><a class="wsn-link" href="#evidence">Evidence &amp; rerun</a></li>'
    Line '<li><a class="wsn-link" href="#sources">Sources</a></li>'
    Line '</ul>'
    Line '</nav>'

    # --- Selected scope ---
    Line '<section id="scope" class="section" aria-labelledby="scope-h">'
    Line '<div class="section-head"><h2 id="scope-h">Selected scope</h2><span class="section-sub">What this pre-flight evaluated</span></div>'
    Line '<div class="grid cols-2">'
    Line '<div class="card">'
    Line '<h3>Tenant foundation</h3>'
    Line '<dl class="kv">'
    Line ('<dt>Display name</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $tenant 'DisplayName' '(not reported)')) + '</dd>')
    Line ('<dt>Tenant ID</dt><dd class="mono">' + (ConvertTo-A365Html (Get-A365Member $tenant 'TenantId' '(not reported)')) + '</dd>')
    Line ('<dt>Primary domain</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $tenant 'PrimaryDomain' '(not reported)')) + '</dd>')
    Line ('<dt>Cloud</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $tenant 'Cloud' '(not reported)')) + '</dd>')
    Line ('<dt>Commercial availability</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $tenant 'CommercialAvailability' '(not reported)')) + '</dd>')
    Line '</dl>'
    # --- Tenant target / assertion (plain-English) ---
    $ta = Get-A365Member $tenant 'TargetAssertion'
    $taRequested = Get-A365Bool (Get-A365Member $ta 'Requested')
    $taMethod = [string](Get-A365Member $ta 'Method' 'NotRequested')
    Line '<div class="tenant-target">'
    Line '<p class="tt-label">Tenant target</p>'
    Line '<dl class="kv">'
    if (-not $taRequested -or $taMethod -eq 'NotRequested') {
        Line '<dt>Assertion</dt><dd>Not explicitly pinned <span class="muted small">(this run did not assert a specific tenant)</span></dd>'
    } else {
        $taExpectedRaw = Get-A365Member $ta 'Expected'
        $taExpected = if ($null -ne $taExpectedRaw -and -not [string]::IsNullOrWhiteSpace([string]$taExpectedRaw)) { [string]$taExpectedRaw } else { '(not specified)' }
        Line ('<dt>Expected target</dt><dd>' + (ConvertTo-A365Html $taExpected) + '</dd>')

        if ($taMethod -eq 'TenantId') { $taMethodLabel = 'Tenant ID match' }
        elseif ($taMethod -eq 'VerifiedDomain') { $taMethodLabel = 'Verified domain match' }
        elseif ($taMethod -eq 'Unverified') { $taMethodLabel = 'Requested, but could not be verified' }
        else { $taMethodLabel = $taMethod }
        Line ('<dt>Assertion method</dt><dd>' + (ConvertTo-A365Html $taMethodLabel) + '</dd>')

        $taActualRaw = Get-A365Member $ta 'ActualTenantId'
        if ($null -ne $taActualRaw -and -not [string]::IsNullOrWhiteSpace([string]$taActualRaw)) {
            Line ('<dt>Actual tenant ID</dt><dd class="mono">' + (ConvertTo-A365Html ([string]$taActualRaw)) + '</dd>')
        } elseif ($isSanitized) {
            Line '<dt>Actual tenant ID</dt><dd class="muted">[redacted in sanitized report]</dd>'
        } else {
            Line '<dt>Actual tenant ID</dt><dd class="muted">(not reported)</dd>'
        }

        if ($taMethod -eq 'Unverified') {
            Line '<dt>Result</dt><dd><span class="chip"><span aria-hidden="true">&#8210;</span> Not verified</span></dd>'
        } elseif (Get-A365Bool (Get-A365Member $ta 'Matched')) {
            Line '<dt>Result</dt><dd><span class="chip ok"><span aria-hidden="true">&#10003;</span> Matched expected tenant</span></dd>'
        } else {
            Line '<dt>Result</dt><dd><span class="chip miss"><span aria-hidden="true">&#10007;</span> Did not match expected tenant</span></dd>'
        }

        $taDomainRaw = Get-A365Member $ta 'MatchedVerifiedDomain'
        if ($null -ne $taDomainRaw -and -not [string]::IsNullOrWhiteSpace([string]$taDomainRaw)) {
            Line ('<dt>Matched verified domain</dt><dd>' + (ConvertTo-A365Html ([string]$taDomainRaw)) + '</dd>')
        }
    }
    Line '</dl>'
    Line '</div>'
    Line '</div>'
    Line '<div class="card">'
    Line '<h3>Run parameters</h3>'
    Line '<dl class="kv">'
    $profileList = Join-A365List $profiles
    if ([string]::IsNullOrWhiteSpace($profileList)) { $profileList = '(none selected)' }
    Line ('<dt>Profiles</dt><dd>' + (ConvertTo-A365Html $profileList) + '</dd>')
    $collectorList = Join-A365List $collectors
    if ([string]::IsNullOrWhiteSpace($collectorList)) { $collectorList = '(not reported)' }
    Line ('<dt>Collectors</dt><dd>' + (ConvertTo-A365Html $collectorList) + '</dd>')
    Line ('<dt>Stage</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $metadata 'Stage' (Get-A365Member $Report 'Stage' '(not reported)'))) + '</dd>')
    Line ('<dt>Rule set</dt><dd>' + (ConvertTo-A365Html ($(if($ruleSetVersion){$ruleSetVersion}else{'(not reported)'}))) + '</dd>')
    Line ('<dt>Authentication mode</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $auth 'Mode' '(not reported)')) + '</dd>')
    Line ('<dt>Signed-in account</dt><dd class="mono">' + (ConvertTo-A365Html (Get-A365Member $auth 'Account' '(not reported)')) + '</dd>')
    Line '</dl>'
    Line '</div>'
    Line '</div>'
    Line '</section>'
        # --- Path to Ready (progressive remediation stepper) ---
    Line ('<section id="pathToReady" class="section" aria-labelledby="pathToReady-h" data-report-key="' + (ConvertTo-A365Html $reportKey) + '">')
    Line '<div class="section-head"><h2 id="pathToReady-h">Path to Ready</h2><span class="section-sub">The ordered work that stands between this tenant and a technical pass</span></div>'

    if ($pathItemTotal -eq 0) {
        Line '<div class="path-ready-banner" role="note"><span class="prb-mark" aria-hidden="true">&#10003;</span><div><strong>No outstanding actions.</strong> Every collected check that could block a pilot is already passing. Manual validations and advisories, if any, are listed in the findings below.</div></div>'
    } else {
        Line '<div id="localProgressNotice" class="local-progress-notice" role="note"><span class="lpn-icon" aria-hidden="true">&#8505;</span><div>Tick items as you complete them to track progress locally in this browser. <strong>Local check marks never change the verdict</strong> &mdash; re-run the checker to confirm a real pass.</div></div>'

        Line '<ol class="path-phases">'
        $phaseNum = 0
        foreach ($phase in $pathPhases) {
            $phaseNum++
            $phaseItems = @($phase.Items)
            if ($phaseItems.Count -eq 0) { continue }
            $phaseClass = 'path-phase p-' + (Get-A365Slug ([string]$phase.Id))
            Line ('<li class="' + $phaseClass + '">')
            Line ('<span class="path-phase-num" aria-hidden="true">' + $phaseNum + '</span>')
            Line ('<h3 class="path-phase-title">' + (ConvertTo-A365Html ([string]$phase.Title)) + ' <span class="path-phase-count">' + $phaseItems.Count + '</span></h3>')
            if (-not [string]::IsNullOrWhiteSpace([string]$phase.Description)) {
                Line ('<p class="path-phase-desc">' + (ConvertTo-A365Html ([string]$phase.Description)) + '</p>')
            }

            Line '<ul class="path-items" style="list-style:none;margin:0;padding:0;">'
            foreach ($it in $phaseItems) {
                $piId = [string]$it.Id
                if ([string]::IsNullOrWhiteSpace($piId)) { $piId = 'item-' + (Get-A365Slug ([string]$it.Title)) }
                $piStatus = [string]$it.Status
                $piStatusMeta = Get-A365StatusMeta $piStatus
                $piTitle = [string]$it.Title
                $piRem = [string]$it.Remediation
                $piOwner = [string]$it.Owner
                $piPerm = [string]$it.RequiredPermission
                $piEvidence = [string]$it.EvidenceNeeded
                Line ('<li class="path-item ' + $piStatusMeta.Class + '" data-path-item data-pi-status="' + (ConvertTo-A365Html $piStatusMeta.Label) + '" data-pi-owner="' + (ConvertTo-A365Html $piOwner) + '">')
                Line '<span class="pi-marker" aria-hidden="true"></span>'
                Line '<div class="pi-main">'
                Line ('<div class="pi-top"><span class="pi-status">' + (Get-A365StatusPill $piStatus) + '</span></div>')
                Line ('<div class="pi-title" data-pi-title>' + (ConvertTo-A365Html $piTitle) + $(if ($piId -and $piId -notmatch '^item-') { '<span class="pi-id">' + (ConvertTo-A365Html $piId) + '</span>' } else { '' }) + '</div>')
                if ($piRem) { Line ('<p class="pi-remediation" data-pi-remediation>' + (ConvertTo-A365Html $piRem) + '</p>') }
                $piMeta = @()
                if ($piOwner) { $piMeta += ('<span><b>Owner</b> ' + (ConvertTo-A365Html $piOwner) + '</span>') }
                if ($piPerm) { $piMeta += ('<span><b>Permission</b> <span class="mono">' + (ConvertTo-A365Html $piPerm) + '</span></span>') }
                if ($piEvidence) { $piMeta += ('<span><b>Evidence</b> ' + (ConvertTo-A365Html $piEvidence) + '</span>') }
                if ($piMeta.Count -gt 0) { Line ('<div class="pi-meta">' + ($piMeta -join '') + '</div>') }
                $piDoc = Get-A365Link $it.DocsUrl 'Documentation'
                if ($piDoc) { Line ('<div class="pi-meta"><span>' + $piDoc + '</span></div>') }
                Line '</div>'
                Line '<div class="pi-side">'
                Line '<label class="pi-check js-only" hidden>'
                Line ('<input type="checkbox" data-local-complete data-item-id="' + (ConvertTo-A365Html $piId) + '"><span>Done</span><span class="sr-only"> &mdash; mark "' + (ConvertTo-A365Html $piTitle) + '" complete locally</span>')
                Line '</label>'
                if ($it.HasCard) {
                    Line ('<a class="pi-open pi-jump" href="#' + (ConvertTo-A365Html ([string]$it.CardId)) + '">View finding</a>')
                    Line ('<button type="button" class="pi-open js-only" data-open-finding="' + (ConvertTo-A365Html ([string]$it.CardId)) + '" hidden>Open details</button>')
                }
                Line '</div>'
                Line '</li>'
            }
            Line '</ul>'
            Line '</li>'
        }
        Line '</ol>'

        Line '<div class="path-foot">'
        Line '<button type="button" id="resetLocalProgress" class="act-btn js-only" hidden>Reset local progress</button>'
        Line '</div>'
    }
    Line '</section>'

    # --- Collection coverage & authorization gaps ---
    Line '<section id="coverage" class="section" aria-labelledby="coverage-h">'
    Line '<div class="section-head"><h2 id="coverage-h">Collection coverage</h2><span class="section-sub">How much of the check set was evaluated &mdash; this is not the verdict and not a compliance score</span></div>'
    Line '<div class="callout" style="margin-bottom:16px;"><span class="muted">Coverage measures how many checks could be collected and evaluated. It is deliberately separate from the pre-flight verdict above, and it is not a composite compliance or security score.</span></div>'

    $covTotal   = Get-A365Member $coverage 'Total' 0
    $covPass    = Get-A365Member $coverage 'Passed' 0
    $covBlock   = Get-A365Member $coverage 'Blockers' 0
    $covAction  = Get-A365Member $coverage 'ActionRequired' 0
    $covAdvis   = Get-A365Member $coverage 'Advisory' 0
    $covManual  = Get-A365Member $coverage 'ManualValidation' 0
    $covNA      = Get-A365Member $coverage 'NotApplicable' 0
    $covNoAuth  = Get-A365Member $coverage 'NotAuthorized' 0
    $covError   = Get-A365Member $coverage 'Error' 0
    $covCollect = Get-A365Member $coverage 'Collected' 0
    $covPct     = Get-A365Member $coverage 'Percentage' $null

    Line '<div class="grid cols-4" style="margin-bottom:18px;">'
    Line ('<div class="stat"><div class="stat-value">' + (ConvertTo-A365Html $covTotal) + '</div><div class="stat-label">Total checks</div></div>')
    Line ('<div class="stat"><div class="stat-value">' + (ConvertTo-A365Html $covCollect) + '</div><div class="stat-label">Collected</div></div>')
    Line ('<div class="stat s-pass"><div class="stat-value">' + (ConvertTo-A365Html $covPass) + '</div><div class="stat-label">Passed</div></div>')
    Line ('<div class="stat s-block"><div class="stat-value">' + (ConvertTo-A365Html $covBlock) + '</div><div class="stat-label">Blockers</div></div>')
    Line '</div>'

    # Coverage meter (proportional segments)
    $totalNum = 0
    [void][int]::TryParse([string]$covTotal, [ref]$totalNum)
    if ($totalNum -gt 0) {
        function local:Seg { param($cls,$val,$label)
            $n = 0; [void][int]::TryParse([string]$val, [ref]$n)
            if ($n -le 0) { return }
            $pct = [math]::Round(($n / $totalNum) * 100, 2)
            Line ('<div class="seg ' + $cls + '" style="width:' + $pct + '%" title="' + (ConvertTo-A365Html ($label + ': ' + $n)) + '"></div>')
        }
        $pctText = if ($null -ne $covPct) { ' (' + (ConvertTo-A365Html $covPct) + '% collected)' } else { '' }
        Line ('<div class="coverage-meter"><div class="coverage-track" role="img" aria-label="Coverage breakdown across ' + (ConvertTo-A365Html $covTotal) + ' checks' + $pctText + '">')
        Seg 's-pass' $covPass 'Passed'
        Seg 's-block' $covBlock 'Blockers'
        Seg 's-action' $covAction 'Action required'
        Seg 's-advisory' $covAdvis 'Advisory'
        Seg 's-manual' $covManual 'Manual validation'
        Seg 's-na' $covNA 'Not applicable'
        Line '</div>'
        Line '<div class="coverage-legend">'
        Line ('<span class="lg"><span class="sw" style="background:var(--pass)"></span>Passed (' + (ConvertTo-A365Html $covPass) + ')</span>')
        Line ('<span class="lg"><span class="sw" style="background:var(--block)"></span>Blockers (' + (ConvertTo-A365Html $covBlock) + ')</span>')
        Line ('<span class="lg"><span class="sw" style="background:var(--action)"></span>Action required (' + (ConvertTo-A365Html $covAction) + ')</span>')
        Line ('<span class="lg"><span class="sw" style="background:var(--advisory)"></span>Advisory (' + (ConvertTo-A365Html $covAdvis) + ')</span>')
        Line ('<span class="lg"><span class="sw" style="background:var(--manual)"></span>Manual (' + (ConvertTo-A365Html $covManual) + ')</span>')
        Line ('<span class="lg"><span class="sw" style="background:var(--neutral-bg)"></span>N/A (' + (ConvertTo-A365Html $covNA) + ')</span>')
        Line ('<span class="lg"><span class="sw" style="background:var(--bg-sunken)"></span>Not authorized (' + (ConvertTo-A365Html $covNoAuth) + ')</span>')
        Line ('<span class="lg"><span class="sw" style="background:var(--block-bg)"></span>Error (' + (ConvertTo-A365Html $covError) + ')</span>')
        Line '</div>'
        Line '</div>'
    }

    # Authorization / scopes
    Line '<div class="grid cols-2" style="margin-top:20px;">'
    Line '<div class="card">'
    Line '<h3>Authorization gaps</h3>'
    $granted = @(Get-A365Member $auth 'GrantedScopes' @())
    $missing = @(Get-A365Member $auth 'MissingScopes' @())
    $requested = @(Get-A365Member $auth 'RequestedScopes' @())
    if ($missing.Count -gt 0) {
        Line '<p class="small muted">Scopes that were requested but not granted:</p>'
        Line '<div class="chips">'
        foreach ($m in $missing) { Line ('<span class="chip miss">' + (ConvertTo-A365Html ([string]$m)) + '</span>') }
        Line '</div>'
    } else {
        Line '<div class="callout empty small"><strong>No authorization gaps.</strong> All requested scopes were granted.</div>'
    }
    if ($requested.Count -gt 0) {
        Line ('<p class="small muted" style="margin-top:12px;">' + (ConvertTo-A365Html $requested.Count) + ' scope(s) requested, ' + (ConvertTo-A365Html $granted.Count) + ' granted.</p>')
    }
    Line '</div>'
    Line '<div class="card">'
    Line '<h3>Granted scopes</h3>'
    if ($granted.Count -gt 0) {
        Line '<div class="chips">'
        foreach ($g in $granted) { Line ('<span class="chip ok">' + (ConvertTo-A365Html ([string]$g)) + '</span>') }
        Line '</div>'
    } else {
        Line '<p class="muted small">No granted scopes reported.</p>'
    }
    $authNotes = @(Get-A365Member $auth 'Notes' @())
    if ($authNotes.Count -gt 0) {
        Line '<ul class="small" style="margin-top:12px;">'
        foreach ($note in $authNotes) { Line ('<li>' + (ConvertTo-A365Html ([string]$note)) + '</li>') }
        Line '</ul>'
    }
    Line '</div>'
    Line '</div>'
    Line '</section>'
        # --- Observe / Govern / Secure pillar summaries ---
    Line '<section id="pillars" class="section" aria-labelledby="pillars-h">'
    Line '<div class="section-head"><h2 id="pillars-h">Observe, Govern &amp; Secure</h2><span class="section-sub">Readiness by Agent 365 pillar</span></div>'
    Line '<div class="pillar-grid">'
    foreach ($pillarName in @('Observe', 'Govern', 'Secure')) {
        $pr = @($results | Where-Object { [string](Get-A365Member $_ 'Pillar' '') -eq $pillarName })
        $pPass   = @($pr | Where-Object { [string](Get-A365Member $_ 'Status' '') -eq 'Passed' }).Count
        $pBlock  = @($pr | Where-Object { [string](Get-A365Member $_ 'Status' '') -eq 'Blocker' }).Count
        $pAction = @($pr | Where-Object { [string](Get-A365Member $_ 'Status' '') -eq 'ActionRequired' }).Count
        $pOther  = $pr.Count - $pPass - $pBlock - $pAction
        Line '<div class="pillar">'
        Line ('<div class="pillar-tag">Pillar</div>')
        Line ('<h3>' + (ConvertTo-A365Html $pillarName) + '</h3>')
        Line ('<p class="small muted">' + (ConvertTo-A365Html $pr.Count) + ' check(s) in scope</p>')
        Line '<div class="pillar-bars">'
        Line ('<div class="pb"><span>Passed</span>' + (Get-A365StatusPill 'Passed') + '</div>')
        if ($pBlock -gt 0)  { Line ('<div class="pb"><span>Blockers</span>' + (Get-A365StatusPill 'Blocker') + '</div>') }
        if ($pAction -gt 0) { Line ('<div class="pb"><span>Action required</span>' + (Get-A365StatusPill 'ActionRequired') + '</div>') }
        Line '</div>'
        Line '<div class="chips" style="margin-top:12px;">'
        Line ('<span class="chip ok">' + (ConvertTo-A365Html $pPass) + ' passed</span>')
        if ($pBlock -gt 0)  { Line ('<span class="chip miss">' + (ConvertTo-A365Html $pBlock) + ' blocker(s)</span>') }
        if ($pAction -gt 0) { Line ('<span class="chip">' + (ConvertTo-A365Html $pAction) + ' action(s)</span>') }
        if ($pOther -gt 0)  { Line ('<span class="chip">' + (ConvertTo-A365Html $pOther) + ' other</span>') }
        Line '</div>'
        Line '</div>'
    }
    Line '</div>'
    Line '</section>'

    # --- Detailed findings: interactive search, filter, and detail blade ---
    Line '<section id="checks" class="section" aria-labelledby="checks-h">'
    Line '<div class="section-head"><h2 id="checks-h">Detailed findings</h2><span class="section-sub">Search, filter, and open any finding for full evidence</span>'
    Line '<button type="button" id="expandAll" class="theme-toggle js-only" hidden aria-pressed="false" style="margin-left:auto;"><span class="ea-label">Expand all</span></button>'
    Line '</div>'

    if ($results.Count -eq 0) {
        Line '<div class="callout empty">No check results were reported.</div>'
    } else {
        # Precompute status counts and distinct filter values in a single pass.
        $cntBlocker = 0; $cntAction = 0; $cntManual = 0; $cntAuthErr = 0; $cntAdvisory = 0; $cntPassed = 0
        $pillarSet = [System.Collections.Specialized.OrderedDictionary]::new()
        $areaSet = [System.Collections.Specialized.OrderedDictionary]::new()
        $profileMap = [System.Collections.Specialized.OrderedDictionary]::new()
        foreach ($r in $results) {
            switch ([string](Get-A365Member $r 'Status' '')) {
                'Blocker'          { $cntBlocker++ }
                'ActionRequired'   { $cntAction++ }
                'ManualValidation' { $cntManual++ }
                'NotAuthorized'    { $cntAuthErr++ }
                'Error'            { $cntAuthErr++ }
                'Advisory'         { $cntAdvisory++ }
                'Passed'           { $cntPassed++ }
            }
            $pvP = [string](Get-A365Member $r 'Pillar' '')
            if ($pvP -and -not $pillarSet.Contains($pvP)) { $pillarSet.Add($pvP, $true) }
            $avA = [string](Get-A365Member $r 'Area' 'Other')
            if ([string]::IsNullOrWhiteSpace($avA)) { $avA = 'Other' }
            if (-not $areaSet.Contains($avA)) { $areaSet.Add($avA, $true) }
            foreach ($pf in @(Get-A365Member $r 'Profiles' @())) {
                $pfName = [string]$pf
                if ($pfName) {
                    $pfSlug = Get-A365Slug $pfName
                    if (-not $profileMap.Contains($pfSlug)) { $profileMap.Add($pfSlug, $pfName) }
                }
            }
        }
        $totalFindings = $results.Count
        $countSuffix = if ($totalFindings -eq 1) { '' } else { 's' }

        Line '<div id="findings">'
        Line '<div class="findings-command js-only" role="search" aria-label="Search and filter findings" hidden>'
        Line '<div class="command-row">'
        Line '<div class="search-field"><span class="search-icon" aria-hidden="true">&#128269;</span>'
        Line '<label class="sr-only" for="resultSearch">Search findings</label>'
        Line '<input type="search" id="resultSearch" placeholder="Search title, ID, area, status, remediation&hellip;" autocomplete="off" spellcheck="false" />'
        Line '<button type="button" id="clearSearch" class="search-clear" hidden aria-label="Clear search">&#215;</button></div>'
        Line '<span class="search-hint" aria-hidden="true">Press <kbd>/</kbd> to search</span>'
        Line '</div>'

        Line '<div class="filter-pills" id="filterStatus" role="group" aria-label="Filter findings by status">'
        Line ('<button type="button" class="filter-pill" data-status-filter="all" aria-pressed="true"><span class="fp-dot s-all" aria-hidden="true"></span>All <span class="fp-count">' + $totalFindings + '</span></button>')
        Line ('<button type="button" class="filter-pill" data-status-filter="Blocker" aria-pressed="false"><span class="fp-dot s-block" aria-hidden="true"></span>Blockers <span class="fp-count">' + $cntBlocker + '</span></button>')
        Line ('<button type="button" class="filter-pill" data-status-filter="ActionRequired" aria-pressed="false"><span class="fp-dot s-action" aria-hidden="true"></span>Action required <span class="fp-count">' + $cntAction + '</span></button>')
        Line ('<button type="button" class="filter-pill" data-status-filter="ManualValidation" aria-pressed="false"><span class="fp-dot s-manual" aria-hidden="true"></span>Manual validation <span class="fp-count">' + $cntManual + '</span></button>')
        Line ('<button type="button" class="filter-pill" data-status-filter="autherror" aria-pressed="false"><span class="fp-dot s-noauth" aria-hidden="true"></span>Not authorized / errors <span class="fp-count">' + $cntAuthErr + '</span></button>')
        Line ('<button type="button" class="filter-pill" data-status-filter="Advisory" aria-pressed="false"><span class="fp-dot s-advisory" aria-hidden="true"></span>Advisory <span class="fp-count">' + $cntAdvisory + '</span></button>')
        Line ('<button type="button" class="filter-pill" data-status-filter="Passed" aria-pressed="false"><span class="fp-dot s-pass" aria-hidden="true"></span>Passed <span class="fp-count">' + $cntPassed + '</span></button>')
        Line '</div>'

        Line '<details class="advanced"><summary id="advancedFiltersToggle" aria-controls="advancedFiltersPanel">Advanced filters</summary>'
        Line '<div class="advanced-grid" id="advancedFiltersPanel">'
        Line '<label for="pillarFilter">Pillar<select id="pillarFilter"><option value="">All pillars</option>'
        foreach ($pk in $pillarSet.Keys) { Line ('<option value="' + (ConvertTo-A365Html ([string]$pk)) + '">' + (ConvertTo-A365Html ([string]$pk)) + '</option>') }
        Line '</select></label>'
        Line '<label for="areaFilter">Area / collector<select id="areaFilter"><option value="">All areas</option>'
        foreach ($ak in $areaSet.Keys) { Line ('<option value="' + (ConvertTo-A365Html ([string]$ak)) + '">' + (ConvertTo-A365Html ([string]$ak)) + '</option>') }
        Line '</select></label>'
        Line '<label for="profileFilter">Selected profile<select id="profileFilter"><option value="">All profiles</option>'
        foreach ($pmk in $profileMap.Keys) { Line ('<option value="' + (ConvertTo-A365Html ([string]$pmk)) + '">' + (ConvertTo-A365Html ([string]$profileMap[$pmk])) + '</option>') }
        Line '</select></label>'
        Line '</div></details>'

        Line '<div class="command-meta">'
        Line ('<p id="filterResultCount" role="status" aria-live="polite">Showing all ' + $totalFindings + ' finding' + $countSuffix + '</p>')
        Line '<div class="command-actions"><button type="button" id="resetFilters" class="view-details-btn">Reset filters</button></div>'
        Line '</div>'
        Line '</div>'

        $areaGroups = $results | Group-Object -Property { $gn = [string](Get-A365Member $_ 'Area' 'Other'); if ([string]::IsNullOrWhiteSpace($gn)) { 'Other' } else { $gn } }
        $areaGroups = @($areaGroups | Sort-Object -Property Name)
        foreach ($group in $areaGroups) {
            $areaName = if ([string]::IsNullOrWhiteSpace($group.Name)) { 'Other' } else { $group.Name }
            $areaSlug = 'area-' + (Get-A365Slug $areaName)
            $gBlock = 0; $gAction = 0; $gAuthErr = 0
            foreach ($gr in $group.Group) {
                switch ([string](Get-A365Member $gr 'Status' '')) {
                    'Blocker'        { $gBlock++ }
                    'ActionRequired' { $gAction++ }
                    'NotAuthorized'  { $gAuthErr++ }
                    'Error'          { $gAuthErr++ }
                }
            }
            $gClean = if (($gBlock + $gAuthErr) -eq 0) { ' data-clean="1"' } else { '' }
            $areaSlugEnc = ConvertTo-A365Html $areaSlug
            $areaBodyId = $areaSlugEnc + '-body'
            Line ('<details class="finding-group" data-result-group' + $gClean + ' id="' + $areaSlugEnc + '" open>')
            Line ('<summary aria-controls="' + $areaBodyId + '">')
            Line ('<span class="fg-title">' + (ConvertTo-A365Html $areaName) + ' <span class="muted small">(' + $group.Count + ')</span></span>')
            Line '<span class="fg-counts">'
            Line ('<span class="fg-count">' + $group.Count + ' total</span>')
            if ($gBlock -gt 0) { Line ('<span class="fg-count s-block"><span class="fp-dot s-block" aria-hidden="true"></span>' + $gBlock + ' blocker' + $(if($gBlock -eq 1){''}else{'s'}) + '</span>') }
            if ($gAction -gt 0) { Line ('<span class="fg-count s-action"><span class="fp-dot s-action" aria-hidden="true"></span>' + $gAction + ' action</span>') }
            if ($gAuthErr -gt 0) { Line ('<span class="fg-count s-block"><span class="fp-dot s-noauth" aria-hidden="true"></span>' + $gAuthErr + ' auth/error</span>') }
            Line '</span>'
            Line '</summary>'
            Line ('<div class="finding-group-body" id="' + $areaBodyId + '">')

            foreach ($r in $group.Group) {
                $rStatus = [string](Get-A365Member $r 'Status' '')
                $rMeta = Get-A365StatusMeta $rStatus
                $rId = [string](Get-A365Member $r 'Id' '')
                $rTitle = [string](Get-A365Member $r 'Title' $rId)
                if ([string]::IsNullOrWhiteSpace($rTitle)) { $rTitle = 'Untitled finding' }
                $rSlug = if ($rId) { 'check-' + (Get-A365Slug $rId) } else { 'check-' + (Get-A365Slug $rTitle) }
                $rPillar = [string](Get-A365Member $r 'Pillar' '')
                $rApplic = [string](Get-A365Member $r 'Applicability' '')
                $rProfilesList = @(Get-A365Member $r 'Profiles' @())
                $rProfiles = Join-A365List $rProfilesList
                $rProfileSlugs = (@($rProfilesList | ForEach-Object { Get-A365Slug ([string]$_) }) -join ' ')
                $rExpected = [string](Get-A365Member $r 'Expected' '')
                $rIsSensitive = Get-A365Bool (Get-A365Member $r 'IsSensitive')
                $rObserved = [string](Get-A365Member $r 'Observed' '')
                $rRemediation = [string](Get-A365Member $r 'Remediation' '')
                $reqPerm = [string](Get-A365Member $r 'RequiredPermission' '')
                $reqRole = [string](Get-A365Member $r 'RequiredRole' '')

                if ($isSanitized -and $rIsSensitive) {
                    $observedIsRedacted = $true
                    $observedDisplay = '[redacted in sanitized report]'
                } else {
                    $observedIsRedacted = $false
                    $observedDisplay = $rObserved
                }
                if ($observedDisplay) { $observedOneLine = $observedDisplay }
                elseif ($rExpected) { $observedOneLine = 'Expected: ' + $rExpected }
                else { $observedOneLine = $rMeta.Label }

                # Index canonical guidance text so concept searches (sponsor, DLP,
                # OBO, rollback, incident response, ...) match manually attestable results.
                $rGuidance = Get-A365GateGuidance $r $r
                $guidanceSearch = ''
                if ($null -ne $rGuidance) {
                    $gParts = @(
                        [string]$rGuidance.SearchText, [string]$rGuidance.Intent, [string]$rGuidance.WhyItMatters,
                        [string]$rGuidance.WhoShouldAnswer, [string]$rGuidance.NoRemediation, [string]$rGuidance.NotApplicableGuidance
                    )
                    $gParts += @($rGuidance.YesCriteria | ForEach-Object { [string]$_ })
                    $gParts += @($rGuidance.EvidenceToRetain | ForEach-Object { [string]$_ })
                    foreach ($st in $rGuidance.VerificationSteps) { $gParts += @([string]$st.Title, [string]$st.Instruction, [string]$st.Location) }
                    foreach ($ps in $rGuidance.PublicSources) { $gParts += @([string]$ps.Title) }
                    $guidanceSearch = (@($gParts | Where-Object { $_ }) -join ' ')
                }

                $searchParts = @($rTitle, $rId, $areaName, $rPillar, $rExpected, $observedDisplay, $rRemediation, $reqRole, $reqPerm, $rMeta.Label, $guidanceSearch)
                $searchText = ((@($searchParts | Where-Object { $_ }) -join ' ')).ToLowerInvariant()

                Line ('<article class="finding ' + $rMeta.Class + '" data-result-card id="' + (ConvertTo-A365Html $rSlug) + '"' +
                    ' data-status="' + (ConvertTo-A365Html $rStatus) + '"' +
                    ' data-pillar="' + (ConvertTo-A365Html $rPillar) + '"' +
                    ' data-area="' + (ConvertTo-A365Html $areaName) + '"' +
                    ' data-profiles="' + (ConvertTo-A365Html $rProfileSlugs) + '"' +
                    ' data-title="' + (ConvertTo-A365Html $rTitle) + '"' +
                    ' data-result-search="' + (ConvertTo-A365Html $searchText) + '">')

                Line '<div class="finding-row">'
                Line '<span class="r-marker" aria-hidden="true"></span>'
                Line ('<span class="finding-main"><span class="finding-title">' + (ConvertTo-A365Html $rTitle) + $(if($rId){ '<span class="r-id">' + (ConvertTo-A365Html $rId) + '</span>' } else { '' }) + '</span><span class="finding-observed">' + (ConvertTo-A365Html $observedOneLine) + '</span></span>')
                Line ('<span class="finding-status">' + (Get-A365StatusPill $rStatus) + '</span>')
                Line ('<button type="button" class="view-details-btn js-only" data-view-details hidden aria-label="View details for ' + (ConvertTo-A365Html $rTitle) + '">View details</button>')
                Line '</div>'

                Line '<div class="finding-full" data-result-full>'

                # -- Segment: Finding --
                Line '<div class="blade-seg">'
                Line '<h4 class="blade-seg-title">Finding</h4>'
                Line '<dl class="kv">'
                if ($rPillar) { Line ('<dt>Pillar</dt><dd>' + (ConvertTo-A365Html $rPillar) + '</dd>') }
                Line ('<dt>Area</dt><dd>' + (ConvertTo-A365Html $areaName) + '</dd>')
                if ($rApplic) { Line ('<dt>Applicability</dt><dd>' + (ConvertTo-A365Html $rApplic) + '</dd>') }
                if ($rProfiles) { Line ('<dt>Profiles</dt><dd>' + (ConvertTo-A365Html $rProfiles) + '</dd>') }
                Line '</dl>'
                if ($rExpected) {
                    Line ('<div class="field expected"><div class="field-label">Expected</div><div class="field-value">' + (ConvertTo-A365Html $rExpected) + '</div></div>')
                }
                if ($observedIsRedacted) {
                    Line '<div class="field observed"><div class="field-label">Observed</div><div class="field-value muted">[redacted in sanitized report]</div></div>'
                } elseif ($rObserved) {
                    Line ('<div class="field observed"><div class="field-label">Observed</div><div class="field-value">' + (ConvertTo-A365Html $rObserved) + '</div></div>')
                }
                Line '</div>'

                # -- Segment: Remediation (exact next action, owning role, permission, docs) --
                $docLink = Get-A365Link (Get-A365Member $r 'DocsUrl') 'Documentation'
                if ($rRemediation -or $reqRole -or $reqPerm -or $docLink) {
                    Line '<div class="blade-seg">'
                    Line '<h4 class="blade-seg-title">Remediation</h4>'
                    if ($rRemediation) {
                        Line ('<div class="remediation"><div class="field-label">Next action</div><div>' + (ConvertTo-A365Html $rRemediation) + '</div></div>')
                    } else {
                        Line '<p class="small muted" style="margin:0 0 8px;">No remediation is required for this check.</p>'
                    }
                    if ($reqRole -or $reqPerm) {
                        Line '<dl class="kv" style="margin-top:8px;">'
                        if ($reqRole) { Line ('<dt>Owning role</dt><dd>' + (ConvertTo-A365Html $reqRole) + '</dd>') }
                        if ($reqPerm) { Line ('<dt>Required permission</dt><dd class="mono">' + (ConvertTo-A365Html $reqPerm) + '</dd>') }
                        Line '</dl>'
                    }
                    if ($docLink) { Line ('<div class="small" style="margin-top:8px;">' + $docLink + '</div>') }
                    Line '</div>'
                }

                # -- Segment: Evidence (method/time/freshness + preserved API evidence) --
                $evPairs = @()
                $evMethod = [string](Get-A365Member $r 'EvidenceMethod' '')
                if ($evMethod) { $evPairs += @('Evidence method', (ConvertTo-A365Html $evMethod)) }
                $evTime = Get-A365Member $r 'EvidenceTimeUtc'
                if ($evTime) { $evPairs += @('Evidence time', (ConvertTo-A365Html (Format-A365Date $evTime))) }
                $rRuleReview = Get-A365Member $r 'RuleReviewDate'
                if ($rRuleReview) { $evPairs += @('Rule reviewed', (ConvertTo-A365Html (Format-A365Date $rRuleReview))) }
                $rDetails = Get-A365Member $r 'Details'
                $hasDetails = ($null -ne $rDetails)
                if ($evPairs.Count -gt 0 -or $hasDetails) {
                    Line '<div class="blade-seg">'
                    Line '<h4 class="blade-seg-title">Evidence</h4>'
                    if ($evPairs.Count -gt 0) {
                        Line '<dl class="kv">'
                        for ($i = 0; $i -lt $evPairs.Count; $i += 2) {
                            Line ('<dt>' + $evPairs[$i] + '</dt><dd>' + $evPairs[$i + 1] + '</dd>')
                        }
                        Line '</dl>'
                    }
                    if ($hasDetails) {
                        if ($isSanitized -and $rIsSensitive) {
                            Line '<div class="field"><div class="field-label">Details</div><div class="field-value muted">[redacted in sanitized report]</div></div>'
                        } else {
                            Line '<details class="result" style="margin:12px 0 0;"><summary><span class="r-marker" aria-hidden="true"></span><span class="r-title">Evidence details</span></summary><div class="result-body">'
                            Line (Format-A365Details -Value $rDetails)
                            Line '</div></details>'
                        }
                    }
                    Line '</div>'
                }

                Line '</div>'
                Line '</article>'
            }

            Line '</div>'
            Line '</details>'
        }

        Line '<div class="findings-empty js-only" id="findingsEmpty" role="status" hidden>No findings match your current search and filters. Use <strong>Reset filters</strong> to clear them.</div>'
        Line '</div>'
    }
    Line '</section>'
        # --- Manual attestations & answers builder ---
    if ($attest.Count -gt 0 -or $gateModel.Count -gt 0) {
        Line '<section id="attestations" class="section" aria-labelledby="attestations-h">'
        Line '<div class="section-head"><h2 id="attestations-h">Manual attestations</h2><span class="section-sub">Checks that require human confirmation &mdash; recorded answers never change the verdict</span></div>'
        if ($attest.Count -gt 0) {
            Line '<div class="table-scroll"><table class="data"><caption>Attestation questions and recorded answers</caption>'
            Line '<thead><tr><th scope="col">Question</th><th scope="col">Required</th><th scope="col">Answer</th><th scope="col">Owner</th><th scope="col">Evidence</th><th scope="col">Status</th></tr></thead><tbody>'
            foreach ($at in $attest) {
                $atRequired = Get-A365Bool (Get-A365Member $at 'Required')
                $atAnswered = Get-A365Bool (Get-A365Member $at 'Answered')
                $atStatus = [string](Get-A365Member $at 'Status' '')
                $atAnswer = [string](Get-A365Member $at 'Answer' '')
                if ([string]::IsNullOrWhiteSpace($atAnswer)) { $atAnswer = if ($atAnswered) { '(answered)' } else { '(not answered)' } }
                Line '<tr>'
                Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $at 'Question' (Get-A365Member $at 'Id' ''))) + '<div class="r-id mono">' + (ConvertTo-A365Html (Get-A365Member $at 'Id' '')) + '</div></td>')
                Line ('<td>' + $(if ($atRequired) { 'Required' } else { 'Optional' }) + '</td>')
                Line ('<td>' + (ConvertTo-A365Html $atAnswer) + '</td>')
                Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $at 'Owner' '')) + '</td>')
                Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $at 'EvidenceReference' '')) + '</td>')
                Line ('<td>' + $(if ($atStatus) { Get-A365StatusPill $atStatus } else { '<span class="muted small">&mdash;</span>' }) + '</td>')
                Line '</tr>'
            }
            Line '</tbody></table></div>'
        }

        # Answers builder (JS enhancement; values stay in memory, offline JSON export only)
        if ($gateModel.Count -gt 0) {
            Line '<div id="answersBuilder" class="answers-builder js-only" hidden>'
            Line '<h3>Answers builder</h3>'
            Line '<p class="small muted" style="margin:0 0 4px;">Record manual answers to attestable gates, then download an answers file. Values stay in this browser and are never uploaded. <strong>Recording an answer here does not change the verdict</strong> &mdash; re-run the checker with the downloaded file to apply them.</p>'
            foreach ($gate in $gateModel) {
                $gId = [string]$gate.Id
                if ([string]::IsNullOrWhiteSpace($gId)) { continue }
                $gTitle = [string]$gate.Title
                $gReq = [bool]$gate.Required
                $gAllowNa = [bool]$gate.AllowNotApplicable
                $gEvidence = [string]$gate.EvidenceNeeded
                $gSlug = Get-A365Slug $gId
                Line ('<div class="answer-gate" data-answer-gate="' + (ConvertTo-A365Html $gId) + '" data-answer-gate-title="' + (ConvertTo-A365Html $gTitle) + '">')
                Line '<div class="answer-gate-head">'
                Line ('<span class="answer-gate-title">' + (ConvertTo-A365Html $gTitle) + '</span>')
                if ($gReq) { Line '<span class="answer-gate-req">Required</span>' }
                Line ('<span class="r-id mono">' + (ConvertTo-A365Html $gId) + '</span>')
                Line ('<button type="button" class="review-guidance-btn" data-guidance-open="guidance-' + (ConvertTo-A365Html $gSlug) + '" data-guidance-gate="' + (ConvertTo-A365Html $gId) + '"><span class="rg-glyph" aria-hidden="true">&#9432;</span>Review guidance</button>')
                Line '</div>'
                if ($gEvidence) { Line ('<p class="answer-gate-evidence">Evidence needed: ' + (ConvertTo-A365Html $gEvidence) + '</p>') }
                Line ('<div class="answer-values" role="radiogroup" aria-label="' + (ConvertTo-A365Html ('Answer for ' + $gTitle)) + '">')
                Line ('<label><input type="radio" name="ans-' + (ConvertTo-A365Html $gSlug) + '" value="Yes" data-answer-value="Yes"><span>Yes</span></label>')
                Line ('<label><input type="radio" name="ans-' + (ConvertTo-A365Html $gSlug) + '" value="No" data-answer-value="No"><span>No</span></label>')
                if ($gAllowNa) { Line ('<label><input type="radio" name="ans-' + (ConvertTo-A365Html $gSlug) + '" value="NotApplicable" data-answer-value="NotApplicable"><span>Not applicable</span></label>') }
                Line '</div>'
                Line '<div class="answer-fields">'
                Line ('<label>Owner<input type="text" data-answer-owner autocomplete="off"></label>')
                Line ('<label>Evidence reference<input type="text" data-answer-reference autocomplete="off"></label>')
                Line '</div>'
                Line '<div class="answer-fields full">'
                Line ('<label>Notes<textarea data-answer-notes rows="2"></textarea></label>')
                if ($gAllowNa) { Line ('<label>Justification (required for Not applicable)<textarea data-answer-justification rows="2"></textarea></label>') }
                Line '</div>'
                Line '</div>'
            }
            Line '<div class="tool-actions">'
            Line '<button type="button" id="downloadAnswers" class="act-btn is-brand">Download answers JSON</button>'
            Line '</div>'
            Line '<p id="answersFeedback" class="tool-feedback" role="status" aria-live="polite"></p>'
            Line '</div>'

            # Always-visible guidance appendix: single source of truth for the guidance
            # dialog (cloned by JS), for print, and for the no-JS experience. Lives OUTSIDE
            # the js-only answers builder so it renders when scripts are unavailable.
            Line '<div class="guidance-appendix" data-guidance-appendix aria-label="Manual evidence guidance">'
            Line '<h3 class="guidance-appendix-title">Manual evidence guidance</h3>'
            Line '<p class="small muted guidance-appendix-note">Full answer guidance for every attestable gate. On screen you can open each gate&rsquo;s guidance from its <strong>Review guidance</strong> button; this appendix stays complete for print and when scripts are disabled.</p>'
            foreach ($gate in $gateModel) {
                $gId = [string]$gate.Id
                if ([string]::IsNullOrWhiteSpace($gId)) { continue }
                $gTitle = [string]$gate.Title
                $gAllowNa = [bool]$gate.AllowNotApplicable
                $gEvidence = [string]$gate.EvidenceNeeded
                $gStatus = [string]$gate.Status
                $gRole = [string]$gate.RequiredRole
                $gSlug = Get-A365Slug $gId
                $gObs = [string]$gate.Observed
                $obsRedacted = ($isSanitized -and [bool]$gate.IsSensitive)
                if ($obsRedacted) { $gObs = '' }
                Line ('<details class="guidance-doc" data-guidance-doc id="guidance-' + (ConvertTo-A365Html $gSlug) + '" open data-guidance-gateid="' + (ConvertTo-A365Html $gId) + '" data-guidance-title="' + (ConvertTo-A365Html $gTitle) + '" data-guidance-role="' + (ConvertTo-A365Html $gRole) + '">')
                Line ('<summary class="guidance-doc-summary"><span class="guidance-eyebrow">Answer guidance</span><span class="guidance-doc-title">' + (ConvertTo-A365Html $gTitle) + '</span></summary>')
                Line '<div class="guidance-doc-inner">'
                Line '<div class="guidance-meta" data-guidance-meta>'
                if ($gStatus) { Line ('<span data-guidance-pill>' + (Get-A365StatusPill $gStatus) + '</span>') }
                Line ('<span class="guidance-meta-id mono">' + (ConvertTo-A365Html $gId) + '</span>')
                if ($gRole) { Line ('<span class="guidance-meta-role">Owner: ' + (ConvertTo-A365Html $gRole) + '</span>') }
                Line '</div>'
                Line '<div class="guidance-doc-body" data-guidance-body>'
                foreach ($gLine in (Format-A365GuidanceSections -Guidance $gate.Guidance -AllowNa $gAllowNa -Observed $gObs -ObservedRedacted:$obsRedacted -EvidenceNeeded $gEvidence -DocsUrl $gate.DocsUrl)) {
                    Line $gLine
                }
                Line '</div>'
                Line '</div>'
                Line '</details>'
            }
            Line '</div>'
        }
        Line '</section>'
    }

    # --- Drift ---
    if ($null -ne $drift) {
        Line '<section id="drift" class="section" aria-labelledby="drift-h">'
        Line '<div class="section-head"><h2 id="drift-h">Drift from baseline</h2><span class="section-sub">Changes since the previous pre-flight</span></div>'
        $hasBaseline = Get-A365Bool (Get-A365Member $drift 'HasBaseline')
        if (-not $hasBaseline) {
            Line '<div class="callout empty">No baseline is available, so drift could not be calculated.</div>'
        } else {
            $baselineTime = Get-A365Member $drift 'BaselineGeneratedAtUtc'
            if ($baselineTime) {
                Line ('<p class="small muted">Baseline generated ' + (ConvertTo-A365Html (Format-A365Date $baselineTime)) + '.</p>')
            }
            $regressions = @(Get-A365Member $drift 'Regressions' @())
            $resolved = @(Get-A365Member $drift 'ResolvedBlockers' @())
            $resolvedRequired = @(Get-A365Member $drift 'ResolvedRequiredActions' @())
            $changed = @(Get-A365Member $drift 'Changed' @())

            # "Other changes" is derived from the superset "Changed"; exclude any item already
            # surfaced in a highlighted block so resolved/regressed entries are not shown twice.
            $driftHighlightedIds = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($hItem in (@($regressions) + @($resolved) + @($resolvedRequired))) {
                $hId = [string](Get-A365Member $hItem 'Id' '')
                if ($hId) { [void]$driftHighlightedIds.Add($hId) }
            }
            $otherChanges = @($changed | Where-Object {
                $cId = [string](Get-A365Member $_ 'Id' '')
                -not ($cId -and $driftHighlightedIds.Contains($cId))
            })

            function local:DriftBlock { param($title,$items,$cls)
                if ($items.Count -eq 0) { return }
                Line ('<h3>' + (ConvertTo-A365Html $title) + ' <span class="muted small">(' + (ConvertTo-A365Html $items.Count) + ')</span></h3>')
                Line '<div class="drift-list">'
                foreach ($d in $items) {
                    $prev = [string](Get-A365Member $d 'PreviousStatus' '')
                    $curr = [string](Get-A365Member $d 'CurrentStatus' '')
                    $dTitle = [string](Get-A365Member $d 'Title' (Get-A365Member $d 'Id' ''))
                    Line '<div class="drift-item">'
                    Line ('<div>' + $(if ($prev) { Get-A365StatusPill $prev } else { '' }) + ' <span class="arrow" aria-hidden="true">&rarr;</span> ' + $(if ($curr) { Get-A365StatusPill $curr } else { '' }) + '</div>')
                    Line ('<div><strong>' + (ConvertTo-A365Html $dTitle) + '</strong> <span class="r-id mono">' + (ConvertTo-A365Html (Get-A365Member $d 'Id' '')) + '</span></div>')
                    Line '</div>'
                }
                Line '</div>'
            }
            DriftBlock 'Regressions' @($regressions) 's-block'
            DriftBlock 'Resolved blockers' @($resolved) 's-pass'
            DriftBlock 'Resolved required actions' @($resolvedRequired) 's-pass'
            DriftBlock 'Other changes' @($otherChanges) 's-advisory'
            if ($regressions.Count -eq 0 -and $resolved.Count -eq 0 -and $resolvedRequired.Count -eq 0 -and $changed.Count -eq 0) {
                Line '<div class="callout empty">No changes were detected since the baseline.</div>'
            }
        }
        Line '</section>'
    }
        # --- Evidence timestamps ---
    Line '<section id="evidence" class="section" aria-labelledby="evidence-h">'
    Line '<div class="section-head"><h2 id="evidence-h">Evidence &amp; rerun</h2><span class="section-sub">When observations were collected, and how to reproduce this pre-flight</span></div>'

    # Rerun command + remediation export (JS enhancements are offline-only)
    if ($rerunModel.HasCommand -or $pathItemTotal -gt 0) {
        Line '<div id="evidenceRerun" class="rerun-tool">'
        if ($rerunModel.HasCommand) {
            Line '<h3>Re-run this pre-flight</h3>'
            if ($isSanitized) {
                Line '<p class="small muted" style="margin:0 0 4px;">This is a sanitized command with placeholders. Replace the placeholders with your tenant target and paths before running.</p>'
            } else {
                Line '<p class="small muted" style="margin:0 0 4px;">Run this to reproduce the pre-flight after remediating. Re-running is the only way to confirm a real pass &mdash; local check marks do not.</p>'
            }
            Line '<div class="rerun-block">'
            Line ('<pre id="rerunCommand" class="rerun-code" tabindex="0">' + (ConvertTo-A365Html ([string]$rerunModel.Command)) + '</pre>')
            if ($rerunModel.ShowMeta) {
                $rrMeta = @()
                if ([string]$rerunModel.TenantTarget) { $rrMeta += ('<div><span class="rm-k">Tenant target</span> <span class="mono">' + (ConvertTo-A365Html ([string]$rerunModel.TenantTarget)) + '</span></div>') }
                if ([string]$rerunModel.OutputPath) { $rrMeta += ('<div><span class="rm-k">Output path</span> <span class="mono">' + (ConvertTo-A365Html ([string]$rerunModel.OutputPath)) + '</span></div>') }
                if ([string]$rerunModel.AnswersPath) { $rrMeta += ('<div><span class="rm-k">Answers file</span> <span class="mono">' + (ConvertTo-A365Html ([string]$rerunModel.AnswersPath)) + '</span></div>') }
                if ([string]$rerunModel.Stage) { $rrMeta += ('<div><span class="rm-k">Stage</span> ' + (ConvertTo-A365Html ([string]$rerunModel.Stage)) + '</div>') }
                if ($rrMeta.Count -gt 0) { Line ('<div class="rerun-meta">' + ($rrMeta -join '') + '</div>') }
            }
            Line '</div>'
        }
        Line '<div class="tool-actions">'
        if ($rerunModel.HasCommand) {
            Line '<button type="button" id="copyRerunCommand" class="act-btn is-brand js-only" hidden>Copy rerun command</button>'
        }
        Line '<button type="button" id="downloadRemediation" class="act-btn js-only" hidden>Download remediation checklist</button>'
        Line '</div>'
        Line '<p id="rerunFeedback" class="tool-feedback" role="status" aria-live="polite"></p>'
        Line '</div>'
    }

    Line '<h3 style="margin-top:20px;">Evidence timestamps</h3>'
    $evResults = @($results | Where-Object { Get-A365Member $_ 'EvidenceTimeUtc' })
    Line '<div class="grid cols-3" style="margin-bottom:16px;">'
    Line ('<div class="stat"><div class="stat-value">' + (ConvertTo-A365Html (Format-A365Date $generatedAtUtc)) + '</div><div class="stat-label">Report generated</div></div>')
    Line ('<div class="stat"><div class="stat-value">' + (ConvertTo-A365Html $evResults.Count) + '</div><div class="stat-label">Checks with evidence</div></div>')
    $durationSeconds = Get-A365Member $runtime 'DurationSeconds'
    if ($null -ne $durationSeconds) {
        Line ('<div class="stat"><div class="stat-value">' + (ConvertTo-A365Html $durationSeconds) + 's</div><div class="stat-label">Collection duration</div></div>')
    }
    Line '</div>'
    if ($evResults.Count -gt 0) {
        Line '<details class="result"><summary><span class="r-marker" aria-hidden="true"></span><span class="r-title">Per-check evidence times</span> <span class="r-id mono">' + (ConvertTo-A365Html $evResults.Count) + '</span></summary><div class="result-body">'
        Line '<div class="table-scroll"><table class="data"><thead><tr><th scope="col">Check</th><th scope="col">Evidence time</th><th scope="col">Method</th></tr></thead><tbody>'
        foreach ($e in $evResults) {
            Line '<tr>'
            Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $e 'Title' (Get-A365Member $e 'Id' ''))) + '<div class="r-id mono">' + (ConvertTo-A365Html (Get-A365Member $e 'Id' '')) + '</div></td>')
            Line ('<td class="nowrap">' + (ConvertTo-A365Html (Format-A365Date (Get-A365Member $e 'EvidenceTimeUtc'))) + '</td>')
            Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $e 'EvidenceMethod' '')) + '</td>')
            Line '</tr>'
        }
        Line '</tbody></table></div>'
        Line '</div></details>'
    } else {
        Line '<div class="callout empty small">No per-check evidence timestamps were reported.</div>'
    }
    Line '</section>'

    # --- Permissions used ---
    Line '<section id="permissions" class="section" aria-labelledby="permissions-h">'
    Line '<div class="section-head"><h2 id="permissions-h">Permissions used</h2><span class="section-sub">Access exercised during collection</span></div>'
    $permsUsed = @(Get-A365Member $auth 'PermissionsUsed' @())
    Line '<div class="card">'
    if ($permsUsed.Count -gt 0) {
        Line '<div class="chips">'
        foreach ($p in $permsUsed) { Line ('<span class="chip">' + (ConvertTo-A365Html ([string]$p)) + '</span>') }
        Line '</div>'
    } else {
        Line '<p class="muted small">No specific permissions were reported as used.</p>'
    }
    $accountUsed = [string](Get-A365Member $auth 'Account' '')
    $modeUsed = [string](Get-A365Member $auth 'Mode' '')
    if ($accountUsed -or $modeUsed) {
        Line '<dl class="kv" style="margin-top:14px;">'
        if ($modeUsed) { Line ('<dt>Authentication mode</dt><dd>' + (ConvertTo-A365Html $modeUsed) + '</dd>') }
        if ($accountUsed) { Line ('<dt>Account</dt><dd class="mono">' + (ConvertTo-A365Html $accountUsed) + '</dd>') }
        Line '</dl>'
    }
    Line '</div>'
    Line '</section>'

    # --- Rule & API freshness ---
    Line '<section id="freshness" class="section" aria-labelledby="freshness-h">'
    Line '<div class="section-head"><h2 id="freshness-h">Rule &amp; API freshness</h2><span class="section-sub">Versions behind this pre-flight</span></div>'
    Line '<div class="grid cols-2"><div class="card"><dl class="kv">'
    Line ('<dt>Tool version</dt><dd>' + (ConvertTo-A365Html ($(if($toolVersion){$toolVersion}else{'(not reported)'}))) + '</dd>')
    Line ('<dt>Schema version</dt><dd>' + (ConvertTo-A365Html ($(if($schemaVersion){$schemaVersion}else{'(not reported)'}))) + '</dd>')
    Line ('<dt>Rule set version</dt><dd>' + (ConvertTo-A365Html ($(if($ruleSetVersion){$ruleSetVersion}else{'(not reported)'}))) + '</dd>')
    Line ('<dt>Rule review date</dt><dd>' + (ConvertTo-A365Html ($(if($ruleReviewDate){ Format-A365Date $ruleReviewDate }else{'(not reported)'}))) + '</dd>')
    Line '</dl></div><div class="card"><dl class="kv">'
    Line ('<dt>Generated (UTC)</dt><dd>' + (ConvertTo-A365Html (Format-A365Date $generatedAtUtc)) + '</dd>')
    Line ('<dt>PowerShell</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $runtime 'PowerShellVersion' '(not reported)')) + '</dd>')
    Line ('<dt>Platform</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $runtime 'Platform' '(not reported)')) + '</dd>')
    Line ('<dt>Fixture mode</dt><dd>' + $(if ($fixtureMode) { 'Enabled' } else { 'Disabled' }) + '</dd>')
    Line '</dl></div></div>'
    Line '</section>'

    # --- Collection issues ---
    if ($issues.Count -gt 0) {
        Line '<section id="issues" class="section" aria-labelledby="issues-h">'
        Line '<div class="section-head"><h2 id="issues-h">Collection issues</h2><span class="section-sub">Adapters that could not complete cleanly</span></div>'
        Line '<div class="table-scroll"><table class="data"><caption>Non-fatal problems encountered while collecting evidence</caption>'
        Line '<thead><tr><th scope="col">Adapter</th><th scope="col">Category</th><th scope="col">Status</th><th scope="col">Message</th><th scope="col">Required permission</th><th scope="col">Docs</th></tr></thead><tbody>'
        foreach ($iss in $issues) {
            Line '<tr>'
            Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $iss 'Adapter' '')) + '</td>')
            Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $iss 'Category' '')) + '</td>')
            Line ('<td class="mono">' + (ConvertTo-A365Html (Get-A365Member $iss 'StatusCode' '')) + '</td>')
            Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $iss 'Message' '')) + '</td>')
            Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $iss 'RequiredPermission' '')) + '</td>')
            $issDoc = Get-A365Link (Get-A365Member $iss 'DocsUrl') 'Docs'
            Line ('<td>' + $(if ($issDoc) { $issDoc } else { '<span class="muted">&mdash;</span>' }) + '</td>')
            Line '</tr>'
        }
        Line '</tbody></table></div>'
        Line '</section>'
    }

    # --- Public sources ---
    Line '<section id="sources" class="section" aria-labelledby="sources-h">'
    Line '<div class="section-head"><h2 id="sources-h">Public sources</h2><span class="section-sub">Reference documentation behind these checks</span></div>'
    if ($sources.Count -gt 0) {
        Line '<ul class="drift-list" style="list-style:none;padding-left:0;">'
        foreach ($src in $sources) {
            $srcTitle = [string](Get-A365Member $src 'Title' '')
            $srcUrl = Get-A365Member $src 'Url'
            $srcReview = Get-A365Member $src 'ReviewDate'
            $srcLabel = if ([string]::IsNullOrWhiteSpace($srcTitle)) { [string]$srcUrl } else { $srcTitle }
            $link = Get-A365Link $srcUrl $srcLabel 'source-link'
            if (-not $link) { $link = ConvertTo-A365Html $srcLabel }
            Line ('<li class="card" style="padding:12px 16px;"><div>' + $link + '</div>' + $(if ($srcReview) { '<div class="small muted">Reviewed ' + (ConvertTo-A365Html (Format-A365Date $srcReview)) + '</div>' } else { '' }) + '</li>')
        }
        Line '</ul>'
    } else {
        Line '<div class="callout empty small">No public sources were listed.</div>'
    }
    Line '</section>'

    Line '</main>'
    Line '</div>'
        # --- Footer ---
    Line '<footer class="site-footer" role="contentinfo">'
    Line '<div class="wrap">'
    Line '<div class="footer-disclaimer"><strong>Technical pre-flight only.</strong> This report indicates whether the technical prerequisites for a Microsoft Agent 365 pilot appear to be met at the time of collection. It is not a security assessment, audit, or compliance certification, and it does not guarantee any outcome.</div>'
    $outputFiles = @(Get-A365Member $runtime 'OutputFiles' @())
    Line '<div class="grid cols-2">'
    Line '<div><dl class="kv">'
    Line ('<dt>PowerShell</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $runtime 'PowerShellVersion' '(not reported)')) + '</dd>')
    Line ('<dt>Platform</dt><dd>' + (ConvertTo-A365Html (Get-A365Member $runtime 'Platform' '(not reported)')) + '</dd>')
    if ($null -ne $durationSeconds) { Line ('<dt>Duration</dt><dd>' + (ConvertTo-A365Html $durationSeconds) + ' second(s)</dd>') }
    Line '</dl></div>'
    if ($outputFiles.Count -gt 0) {
        Line '<div><dl class="kv"><dt>Output files</dt><dd><ul class="detail-list">'
        foreach ($of in $outputFiles) { Line ('<li class="mono">' + (ConvertTo-A365Html ([string]$of)) + '</li>') }
        Line '</ul></dd></dl></div>'
    }
    Line '</div>'
    Line ('<p class="small muted">Generated by Invoke-Agent365Preflight' + $(if ($toolVersion) { ' v' + (ConvertTo-A365Html $toolVersion) } else { '' }) + $(if ($generatedAtUtc) { ' on ' + (ConvertTo-A365Html (Format-A365Date $generatedAtUtc)) } else { '' }) + '.</p>')
    Line '</div>'
    Line '</footer>'

    # --- Detail blade / bottom sheet (progressive enhancement; revealed by JS) ---
    Line '<div id="detailBackdrop" class="detail-backdrop js-only" hidden></div>'
    Line '<aside id="detailBlade" class="detail-blade js-only" role="dialog" aria-modal="true" aria-labelledby="detailBladeTitle" aria-hidden="true" hidden>'
    Line '<div class="detail-blade-head">'
    Line '<div><h2 id="detailBladeTitle" class="dbh-title" tabindex="-1">Finding details</h2><div id="detailBladeStatus" class="dbh-meta"></div></div>'
    Line '<button type="button" id="detailClose" class="detail-close" aria-label="Close details">&#215;</button>'
    Line '</div>'
    Line '<div id="detailBladeBody" class="detail-blade-body"></div>'
    Line '</aside>'

    # --- Guidance dialog / full-height bottom sheet (semantically distinct from the finding blade) ---
    Line '<div id="guidanceBackdrop" class="guidance-backdrop js-only" hidden></div>'
    Line '<aside id="guidanceDialog" class="guidance-dialog js-only" role="dialog" aria-modal="true" aria-labelledby="guidanceTitle" aria-describedby="guidanceBody" aria-hidden="true" hidden>'
    Line '<div class="guidance-dialog-head">'
    Line '<div class="guidance-dialog-heading">'
    Line '<p class="guidance-dialog-eyebrow">Answer guidance</p>'
    Line '<h2 id="guidanceTitle" class="guidance-dialog-title" tabindex="-1">Guidance</h2>'
    Line '<div id="guidanceMeta" class="guidance-dialog-meta"></div>'
    Line '</div>'
    Line '<button type="button" id="guidanceClose" class="guidance-close" aria-label="Close guidance">&#215;</button>'
    Line '</div>'
    Line '<div id="guidanceBody" class="guidance-dialog-body"></div>'
    Line '<div class="guidance-dialog-foot">'
    Line '<button type="button" id="guidanceBack" class="act-btn is-brand guidance-back-btn">Back to answer</button>'
    Line '<button type="button" id="guidanceCopy" class="act-btn guidance-copy-btn" hidden>Copy evidence checklist</button>'
    Line '<span id="guidanceCopyFeedback" class="guidance-copy-feedback" role="status" aria-live="polite"></span>'
    Line '</div>'
    Line '</aside>'

    Line '<script>'
    Line (Get-A365Script)
    Line '</script>'
    Line '</body>'
    Line '</html>'

    $html = $sb.ToString()

    # --- Resolve destination and write UTF-8 without BOM ---
    $resolvedPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path)
    $parentDir = [System.IO.Path]::GetDirectoryName($resolvedPath)
    if (-not [string]::IsNullOrWhiteSpace($parentDir) -and -not (Test-Path -LiteralPath $parentDir)) {
        New-Item -ItemType Directory -Path $parentDir -Force | Out-Null
    }

    $utf8NoBom = New-Object System.Text.UTF8Encoding($false)
    [System.IO.File]::WriteAllText($resolvedPath, $html, $utf8NoBom)

    return $resolvedPath
}

#endregion Public function
