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
  border-radius: 999px; padding: 7px 14px; display: inline-flex; gap: 8px; align-items: center;
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
  border-radius: 999px; padding: 10px 42px 10px 40px; min-height: 44px;
}
.search-field input[type="search"]::-webkit-search-cancel-button { display: none; }
.search-field input[type="search"]:focus-visible { border-color: var(--brand); }
.search-field input[type="search"]::placeholder { color: var(--text-muted); }
.search-clear {
  position: absolute; right: 7px; top: 50%; transform: translateY(-50%);
  border: 0; background: transparent; color: var(--text-muted); cursor: pointer;
  width: 30px; height: 30px; border-radius: 50%; display: grid; place-items: center; font-size: 1rem;
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
}

@media (prefers-reduced-motion: reduce) {
  * { animation-duration: .001ms !important; animation-iteration-count: 1 !important; transition-duration: .001ms !important; scroll-behavior: auto !important; }
}

.no-js .js-only { display: none !important; }

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

    document.addEventListener("keydown", function (e) {
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
        # --- Verdict hero ---
    Line ('<section class="section" aria-labelledby="verdict-h"><div class="hero ' + $verdictMeta.Class + '">')
    Line ('<div class="hero-badge" aria-hidden="true">' + (ConvertTo-A365Html $verdictMeta.Glyph) + '</div>')
    Line '<div class="hero-body">'
    Line '<p class="kicker muted" style="margin:0 0 4px;">Pre-flight verdict</p>'
    if ([string]::IsNullOrWhiteSpace($verdictLabel)) {
        Line '<h1 id="verdict-h" class="verdict-label">Verdict unavailable</h1>'
    } else {
        Line ('<h1 id="verdict-h" class="verdict-label">' + (ConvertTo-A365Html $verdictLabel) + '</h1>')
    }
    if (-not [string]::IsNullOrWhiteSpace($verdictSummary)) {
        Line ('<p class="hero-summary">' + (ConvertTo-A365Html $verdictSummary) + '</p>')
    }
    Line '<div class="verdict-counts">'
    Line ('<span class="count-chip c-block"><b>' + (ConvertTo-A365Html $blockerCount) + '</b> blocker(s)</span>')
    Line ('<span class="count-chip c-action"><b>' + (ConvertTo-A365Html $actionCount) + '</b> action(s) required</span>')
    Line ('<span class="count-chip c-auth"><b>' + (ConvertTo-A365Html $authGapCount) + '</b> authorization gap(s)</span>')
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

    # --- On this page (nav) ---
    Line '<nav class="section toc js-only" aria-label="On this page" style="display:block;">'
    Line '<h2>On this page</h2>'
    Line '<ul>'
    Line '<li><a href="#scope">Selected scope</a></li>'
    Line '<li><a href="#priorities">Blockers &amp; actions</a></li>'
    Line '<li><a href="#coverage">Collection coverage</a></li>'
    Line '<li><a href="#pillars">Observe / Govern / Secure</a></li>'
    Line '<li><a href="#checks">Detailed checks</a></li>'
    if ($attest.Count -gt 0) { Line '<li><a href="#attestations">Manual attestations</a></li>' }
    if ($null -ne $drift) { Line '<li><a href="#drift">Drift</a></li>' }
    Line '<li><a href="#permissions">Permissions used</a></li>'
    Line '<li><a href="#freshness">Rule &amp; API freshness</a></li>'
    if ($issues.Count -gt 0) { Line '<li><a href="#issues">Collection issues</a></li>' }
    Line '<li><a href="#sources">Public sources</a></li>'
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
        # --- Blockers & ordered actions ---
    Line '<section id="priorities" class="section" aria-labelledby="priorities-h">'
    Line '<div class="section-head"><h2 id="priorities-h">Blockers &amp; ordered actions</h2><span class="section-sub">Resolve these before starting a pilot</span></div>'

    $blockerResults = @($results | Where-Object { [string](Get-A365Member $_ 'Status' '') -eq 'Blocker' })
    if ($blockerResults.Count -gt 0) {
        Line '<h3>Blockers</h3>'
        Line '<div class="table-scroll"><table class="data"><caption>Checks that must pass before a pilot can proceed</caption>'
        Line '<thead><tr><th scope="col">Check</th><th scope="col">Area</th><th scope="col">Status</th><th scope="col">Remediation</th></tr></thead><tbody>'
        foreach ($b in $blockerResults) {
            $bid = [string](Get-A365Member $b 'Id' '')
            $anchor = if ($bid) { '#check-' + (Get-A365Slug $bid) } else { '#checks' }
            Line '<tr>'
            Line ('<td><a href="' + (ConvertTo-A365Html $anchor) + '">' + (ConvertTo-A365Html (Get-A365Member $b 'Title' $bid)) + '</a><div class="r-id mono">' + (ConvertTo-A365Html $bid) + '</div></td>')
            Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $b 'Area' '')) + '</td>')
            Line ('<td>' + (Get-A365StatusPill 'Blocker') + '</td>')
            Line ('<td>' + (ConvertTo-A365Html (Get-A365Member $b 'Remediation' '')) + '</td>')
            Line '</tr>'
        }
        Line '</tbody></table></div>'
    } else {
        Line '<div class="callout empty"><strong>No blockers detected.</strong> No checks are currently blocking a pilot.</div>'
    }

    if ($actions.Count -gt 0) {
        $orderedActions = @($actions | Sort-Object -Property @{ Expression = {
            $p = Get-A365Member $_ 'Priority' 2147483647
            $n = 0
            if ([int]::TryParse([string]$p, [ref]$n)) { $n } else { 2147483647 }
        } }, @{ Expression = { [string](Get-A365Member $_ 'Priority' '') } })

        Line '<h3 style="margin-top:22px;">Ordered actions</h3>'
        Line '<ol class="drift-list" style="padding-left:0;list-style:none;">'
        foreach ($a in $orderedActions) {
            $aStatus = [string](Get-A365Member $a 'Status' '')
            $aResultId = [string](Get-A365Member $a 'ResultId' '')
            $aAnchor = if ($aResultId) { '#check-' + (Get-A365Slug $aResultId) } else { $null }
            Line '<li class="card" style="display:grid;gap:8px;">'
            Line '<div style="display:flex;flex-wrap:wrap;gap:10px;align-items:center;justify-content:space-between;">'
            $prio = Get-A365Member $a 'Priority' ''
            $prioBadge = if ("$prio" -ne '') { '<span class="chip">Priority ' + (ConvertTo-A365Html $prio) + '</span>' } else { '' }
            Line ('<div style="display:flex;gap:10px;align-items:center;flex-wrap:wrap;"><strong>' + (ConvertTo-A365Html (Get-A365Member $a 'Title' '(untitled action)')) + '</strong>' + $prioBadge + '</div>')
            if ($aStatus) { Line ('<div>' + (Get-A365StatusPill $aStatus) + '</div>') }
            Line '</div>'
            $aRem = [string](Get-A365Member $a 'Remediation' '')
            if ($aRem) { Line ('<div class="small">' + (ConvertTo-A365Html $aRem) + '</div>') }
            $links = @()
            if ($aAnchor) { $links += ('<a href="' + (ConvertTo-A365Html $aAnchor) + '">View check ' + (ConvertTo-A365Html $aResultId) + '</a>') }
            $aDoc = Get-A365Link (Get-A365Member $a 'DocsUrl') 'Documentation'
            if ($aDoc) { $links += $aDoc }
            if ($links.Count -gt 0) { Line ('<div class="small">' + ($links -join ' &middot; ') + '</div>') }
            Line '</li>'
        }
        Line '</ol>'
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

                $searchParts = @($rTitle, $rId, $areaName, $rPillar, $rExpected, $observedDisplay, $rRemediation, $reqRole, $reqPerm, $rMeta.Label)
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

                $evPairs = @()
                $evMethod = [string](Get-A365Member $r 'EvidenceMethod' '')
                if ($evMethod) { $evPairs += @('Evidence method', (ConvertTo-A365Html $evMethod)) }
                $evTime = Get-A365Member $r 'EvidenceTimeUtc'
                if ($evTime) { $evPairs += @('Evidence time', (ConvertTo-A365Html (Format-A365Date $evTime))) }
                if ($reqPerm) { $evPairs += @('Required permission', (ConvertTo-A365Html $reqPerm)) }
                if ($reqRole) { $evPairs += @('Required role', (ConvertTo-A365Html $reqRole)) }
                $rRuleReview = Get-A365Member $r 'RuleReviewDate'
                if ($rRuleReview) { $evPairs += @('Rule reviewed', (ConvertTo-A365Html (Format-A365Date $rRuleReview))) }
                if ($evPairs.Count -gt 0) {
                    Line '<dl class="kv" style="margin-top:12px;">'
                    for ($i = 0; $i -lt $evPairs.Count; $i += 2) {
                        Line ('<dt>' + $evPairs[$i] + '</dt><dd>' + $evPairs[$i + 1] + '</dd>')
                    }
                    Line '</dl>'
                }

                $rDetails = Get-A365Member $r 'Details'
                if ($null -ne $rDetails) {
                    if ($isSanitized -and $rIsSensitive) {
                        Line '<div class="field"><div class="field-label">Details</div><div class="field-value muted">[redacted in sanitized report]</div></div>'
                    } else {
                        Line '<details class="result" style="margin:12px 0 0;"><summary><span class="r-marker" aria-hidden="true"></span><span class="r-title">Evidence details</span></summary><div class="result-body">'
                        Line (Format-A365Details -Value $rDetails)
                        Line '</div></details>'
                    }
                }

                if ($rRemediation) {
                    Line ('<div class="remediation"><div class="field-label">Remediation</div><div>' + (ConvertTo-A365Html $rRemediation) + '</div>')
                    $docLink = Get-A365Link (Get-A365Member $r 'DocsUrl') 'Documentation'
                    if ($docLink) { Line ('<div class="small" style="margin-top:8px;">' + $docLink + '</div>') }
                    Line '</div>'
                } else {
                    $docLink = Get-A365Link (Get-A365Member $r 'DocsUrl') 'Documentation'
                    if ($docLink) { Line ('<div class="small" style="margin-top:10px;">' + $docLink + '</div>') }
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
        # --- Manual attestations ---
    if ($attest.Count -gt 0) {
        Line '<section id="attestations" class="section" aria-labelledby="attestations-h">'
        Line '<div class="section-head"><h2 id="attestations-h">Manual attestations</h2><span class="section-sub">Checks that require human confirmation</span></div>'
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
            $changed = @(Get-A365Member $drift 'Changed' @())

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
            DriftBlock 'Other changes' @($changed) 's-advisory'
            if ($regressions.Count -eq 0 -and $resolved.Count -eq 0 -and $changed.Count -eq 0) {
                Line '<div class="callout empty">No changes were detected since the baseline.</div>'
            }
        }
        Line '</section>'
    }
        # --- Evidence timestamps ---
    Line '<section id="evidence" class="section" aria-labelledby="evidence-h">'
    Line '<div class="section-head"><h2 id="evidence-h">Evidence timestamps</h2><span class="section-sub">When each observation was collected</span></div>'
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
