param(
    [string]$Config = "config.json",
    [string]$Source = "",
    [int]$Limit = 0,
    [int]$Days = 0,
    [string]$Out = "",
    [string]$TextOut = ""
)

$ErrorActionPreference = "Stop"

Add-Type -AssemblyName System.Net.Http

$ScriptRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
$ProjectRoot = Split-Path -Parent $ScriptRoot

function Resolve-ProjectPath {
    param([string]$PathValue)

    if ($PathValue -like "{Desktop}*") {
        $desktop = [Environment]::GetFolderPath("Desktop")
        $relative = $PathValue.Substring("{Desktop}".Length).TrimStart("\", "/")
        return Join-Path $desktop $relative
    }

    if ([System.IO.Path]::IsPathRooted($PathValue)) {
        return $PathValue
    }

    return Join-Path $ProjectRoot $PathValue
}

function Get-TimeZoneInfo {
    param([string]$TimeZoneId)

    $aliases = @{
        "Asia/Shanghai" = "China Standard Time"
        "UTC" = "UTC"
    }

    $candidate = if ($aliases.ContainsKey($TimeZoneId)) { $aliases[$TimeZoneId] } else { $TimeZoneId }

    try {
        return [System.TimeZoneInfo]::FindSystemTimeZoneById($candidate)
    }
    catch {
        return [System.TimeZoneInfo]::Utc
    }
}

function Format-Date {
    param(
        [datetime]$Date,
        [System.TimeZoneInfo]$TimeZone,
        [string]$Pattern
    )

    $converted = [System.TimeZoneInfo]::ConvertTimeFromUtc($Date.ToUniversalTime(), $TimeZone)
    return $converted.ToString($Pattern)
}

function Convert-HtmlToText {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return ""
    }

    $decoded = [System.Net.WebUtility]::HtmlDecode($Value)
    $plain = [regex]::Replace($decoded, "<[^>]*>", " ")
    return [regex]::Replace($plain, "\s+", " ").Trim()
}

function Get-ChildText {
    param(
        [System.Xml.XmlNode]$Node,
        [string[]]$Names
    )

    foreach ($name in $Names) {
        foreach ($child in $Node.ChildNodes) {
            if ($child.LocalName -eq $name) {
                return (Convert-HtmlToText $child.InnerText)
            }
        }
    }

    return ""
}

function Get-ItemLink {
    param([System.Xml.XmlNode]$Node)

    foreach ($child in $Node.ChildNodes) {
        if ($child.LocalName -eq "link") {
            if ($child.Attributes -and $child.Attributes["href"]) {
                return $child.Attributes["href"].Value.Trim()
            }

            return (Convert-HtmlToText $child.InnerText)
        }
    }

    return ""
}

function Get-MediaUrl {
    param([System.Xml.XmlNode]$Node)

    foreach ($child in $Node.ChildNodes) {
        if ($child.LocalName -in @("thumbnail", "content", "enclosure")) {
            if ($child.Attributes -and $child.Attributes["url"]) {
                return $child.Attributes["url"].Value.Trim()
            }
        }
    }

    return ""
}

function Convert-ToDateTimeOffset {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [System.DateTimeOffset]::Parse($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    catch {
        return $null
    }
}

function Read-FeedItems {
    param($NewsSource)

    $response = Invoke-WebRequest -Uri $NewsSource.url -Headers @{ "User-Agent" = "daily-news-rss/0.1" } -UseBasicParsing
    $document = New-Object System.Xml.XmlDocument
    $document.PreserveWhitespace = $false
    $document.LoadXml($response.Content)

    $nodes = @($document.GetElementsByTagName("item"))
    if ($nodes.Count -eq 0) {
        $nodes = @($document.GetElementsByTagName("entry"))
    }

    $items = @()
    foreach ($node in $nodes) {
        $title = Get-ChildText $node @("title")
        if ([string]::IsNullOrWhiteSpace($title)) {
            continue
        }

        $description = Get-ChildText $node @("description", "summary", "content", "encoded")
        $link = Get-ItemLink $node
        $rawDate = Get-ChildText $node @("pubDate", "published", "updated", "date")
        $date = Convert-ToDateTimeOffset $rawDate
        $guid = Get-ChildText $node @("guid", "id")

        $items += [pscustomobject]@{
            id = if ($guid) { $guid } elseif ($link) { $link } else { $title }
            title = $title
            description = $description
            link = $link
            pubDate = if ($date) { $date.UtcDateTime.ToString("o") } else { $null }
            sourceId = $NewsSource.id
            sourceName = $NewsSource.name
            imageUrl = Get-MediaUrl $node
        }
    }

    return $items
}

function Build-QueryString {
    param($Params)

    $pairs = @()
    foreach ($key in $Params.Keys) {
        if ($null -eq $Params[$key] -or [string]::IsNullOrWhiteSpace([string]$Params[$key])) {
            continue
        }

        $encodedKey = [System.Uri]::EscapeDataString([string]$key)
        $encodedValue = [System.Uri]::EscapeDataString([string]$Params[$key])
        $pairs += "$encodedKey=$encodedValue"
    }

    return $pairs -join "&"
}

function Convert-GdeltDate {
    param([string]$Value)

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $null
    }

    try {
        return [datetime]::ParseExact(
            $Value,
            "yyyyMMdd'T'HHmmss'Z'",
            [System.Globalization.CultureInfo]::InvariantCulture,
            [System.Globalization.DateTimeStyles]::AssumeUniversal
        )
    }
    catch {
        return $null
    }
}

function New-GdeltDescription {
    param(
        $Article,
        $NewsSource
    )

    if ($NewsSource.summaryTemplate) {
        return ([string]$NewsSource.summaryTemplate).
            Replace("{domain}", [string]$Article.domain).
            Replace("{sourceCountry}", [string]$Article.sourcecountry).
            Replace("{language}", [string]$Article.language)
    }

    $parts = @()
    if ($Article.domain) {
        $parts += "Source domain: $($Article.domain)"
    }
    if ($Article.sourcecountry) {
        $parts += "Source country: $($Article.sourcecountry)"
    }
    if ($Article.language) {
        $parts += "Language: $($Article.language)"
    }

    if ($parts.Count -eq 0) {
        return "GDELT detected this article in the recent global news stream. Open the source link before publishing."
    }

    return ($parts -join "; ") + ". Open the source link before publishing."
}

function Read-GdeltDocItems {
    param($NewsSource)

    $maxRecords = if ($NewsSource.maxRecords) { [int]$NewsSource.maxRecords } else { 50 }
    $timespan = if ($NewsSource.timespan) { [string]$NewsSource.timespan } else { "1d" }
    $sort = if ($NewsSource.sort) { [string]$NewsSource.sort } else { "datedesc" }
    $query = if ($NewsSource.query) { [string]$NewsSource.query } else { "conflict" }
    $baseUrl = if ($NewsSource.url) { [string]$NewsSource.url } else { "https://api.gdeltproject.org/api/v2/doc/doc" }

    $queryString = Build-QueryString @{
        query = $query
        mode = "artlist"
        format = "json"
        maxrecords = $maxRecords
        timespan = $timespan
        sort = $sort
    }
    $url = "$baseUrl`?$queryString"

    $response = Invoke-WebRequestWithRetry $url
    $payload = $response.Content | ConvertFrom-Json
    return Convert-GdeltArticlesToItems -Articles @($payload.articles) -NewsSource $NewsSource
}

function Read-GdeltFileItems {
    param($NewsSource)

    $filePath = Resolve-ProjectPath $NewsSource.filePath
    $payload = Get-Content -LiteralPath $filePath -Raw -Encoding utf8 | ConvertFrom-Json
    return Convert-GdeltArticlesToItems -Articles @($payload.articles) -NewsSource $NewsSource
}

function Read-WorldMonitorWireItems {
    param($NewsSource)

    if ($NewsSource.allowApiAccess -ne $true) {
        throw "World Monitor /api access is disabled in config. Set allowApiAccess to true only if you accept the site's robots.txt restriction risk."
    }

    $content = Invoke-TextRequestWithRetry $NewsSource.url
    $payload = $content | ConvertFrom-Json
    return Convert-WireLocationsToItems -Locations @($payload.locations) -NewsSource $NewsSource
}

function Read-WorldMonitorWireFileItems {
    param($NewsSource)

    $filePath = Resolve-ProjectPath $NewsSource.filePath
    $payload = Get-Content -LiteralPath $filePath -Raw -Encoding utf8 | ConvertFrom-Json
    return Convert-WireLocationsToItems -Locations @($payload.locations) -NewsSource $NewsSource
}

function Convert-GdeltArticlesToItems {
    param(
        $Articles,
        $NewsSource
    )

    $articles = @($Articles)
    $languageFilter = @($NewsSource.languageFilter)
    if ($languageFilter.Count -gt 0) {
        $articles = @($articles | Where-Object { $languageFilter -contains $_.language })
    }

    $items = @()
    foreach ($article in $articles) {
        if ([string]::IsNullOrWhiteSpace($article.title) -or [string]::IsNullOrWhiteSpace($article.url)) {
            continue
        }

        $date = Convert-GdeltDate $article.seendate
        $items += [pscustomobject]@{
            id = $article.url
            title = Convert-HtmlToText $article.title
            description = New-GdeltDescription $article $NewsSource
            link = $article.url
            pubDate = if ($date) { $date.ToUniversalTime().ToString("o") } else { $null }
            sourceId = $NewsSource.id
            sourceName = $NewsSource.name
            imageUrl = $article.socialimage
            domain = $article.domain
            sourceCountry = $article.sourcecountry
            language = $article.language
        }
    }

    return $items
}

function Invoke-WebRequestWithRetry {
    param(
        [string]$Uri,
        [int]$MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            return Invoke-WebRequest -Uri $Uri -Headers @{ "User-Agent" = "daily-news-rss/0.1" } -UseBasicParsing
        }
        catch {
            $response = $_.Exception.Response
            $statusCode = if ($response) { [int]$response.StatusCode } else { 0 }
            if ($statusCode -ne 429 -or $attempt -eq $MaxAttempts) {
                if ($statusCode -eq 429) {
                    throw "Remote API returned 429 Too Many Requests. Narrow the query, lower maxRecords, or rerun later."
                }

                throw
            }

            Start-Sleep -Seconds (5 * $attempt)
        }
    }
}

function Invoke-TextRequestWithRetry {
    param(
        [string]$Uri,
        [int]$MaxAttempts = 3
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        $client = New-Object System.Net.Http.HttpClient
        try {
            $client.DefaultRequestHeaders.UserAgent.ParseAdd("daily-news-rss/0.1")
            $response = $client.GetAsync($Uri).GetAwaiter().GetResult()
            if (-not $response.IsSuccessStatusCode) {
                $statusCode = [int]$response.StatusCode
                if ($statusCode -eq 429 -and $attempt -lt $MaxAttempts) {
                    Start-Sleep -Seconds (5 * $attempt)
                    continue
                }
                if ($statusCode -eq 429) {
                    throw "Remote API returned 429 Too Many Requests. Rerun later or lower the request frequency."
                }
                throw "Remote API returned HTTP $statusCode for $Uri"
            }

            $bytes = $response.Content.ReadAsByteArrayAsync().GetAwaiter().GetResult()
            return [System.Text.Encoding]::UTF8.GetString($bytes)
        }
        finally {
            $client.Dispose()
        }
    }
}

function Convert-WireLocationsToItems {
    param(
        $Locations,
        $NewsSource
    )

    $minIntensity = if ($NewsSource.minIntensity) { [int]$NewsSource.minIntensity } else { 0 }
    $locations = @($Locations | Where-Object { [int]$_.intensity -ge $minIntensity })
    $items = @()

    foreach ($location in $locations) {
        $rewrite = Resolve-WireRewrite $location $NewsSource
        $categoryId = if ($rewrite.category) { $rewrite.category } else { Resolve-WireCategory $location $NewsSource }
        $date = Convert-ToDateTimeOffset $location.last_mentioned_at

        $items += [pscustomobject]@{
            id = $location.id
            sourceKind = "world-monitor-wire"
            title = $rewrite.title
            description = $rewrite.summary
            rawSummary = $location.summary
            analysis = $location.analysis
            link = ""
            pubDate = if ($date) { $date.UtcDateTime.ToString("o") } else { $null }
            sourceId = $NewsSource.id
            sourceName = $NewsSource.name
            imageUrl = ""
            locationName = $location.location_name
            country = $location.country
            categoryId = $categoryId
            categoryName = Get-WireCategoryName $categoryId $NewsSource
            intensity = [int]$location.intensity
            mentionCount = [int]$location.mention_count
            firstSeenAt = $location.first_seen_at
            lastMentionedAt = $location.last_mentioned_at
            processedAt = $location.processed_at
            lastChangeType = $location.last_changes.type
            keyPoints = @($location.key_points)
        }
    }

    return $items
}

function Resolve-WireRewrite {
    param(
        $Location,
        $NewsSource
    )

    $text = "$($Location.location_name) $($Location.country) $($Location.summary)"
    foreach ($rule in @($NewsSource.article.rewriteRules)) {
        if ($text -match $rule.pattern) {
            return [pscustomobject]@{
                category = $rule.category
                title = Expand-WireTemplate $rule.title $Location
                summary = Expand-WireTemplate $rule.summary $Location
            }
        }
    }

    return [pscustomobject]@{
        category = Resolve-WireCategory $Location $NewsSource
        title = Expand-WireTemplate $NewsSource.article.fallbackTitleTemplate $Location
        summary = Expand-WireTemplate $NewsSource.article.fallbackSummaryTemplate $Location
    }
}

function Resolve-WireCategory {
    param(
        $Location,
        $NewsSource
    )

    $text = "$($Location.location_name) $($Location.country) $($Location.summary)"
    foreach ($category in @($NewsSource.article.categories)) {
        if ($text -match $category.patterns) {
            return [string]$category.id
        }
    }

    return "other"
}

function Get-WireCategoryName {
    param(
        [string]$CategoryId,
        $NewsSource
    )

    foreach ($category in @($NewsSource.article.categories)) {
        if ($category.id -eq $CategoryId) {
            return [string]$category.name
        }
    }

    return "Other"
}

function Expand-WireTemplate {
    param(
        [string]$Template,
        $Location
    )

    if ([string]::IsNullOrWhiteSpace($Template)) {
        return ""
    }

    return $Template.
        Replace("{location}", [string]$Location.location_name).
        Replace("{country}", [string]$Location.country).
        Replace("{summary}", [string]$Location.summary).
        Replace("{intensity}", [string]$Location.intensity).
        Replace("{mentionCount}", [string]$Location.mention_count)
}

function Read-SourceItems {
    param($NewsSource)

    switch ([string]$NewsSource.type) {
        "world-monitor-wire" { return Read-WorldMonitorWireItems $NewsSource }
        "world-monitor-wire-file" { return Read-WorldMonitorWireFileItems $NewsSource }
        "gdelt-doc" { return Read-GdeltDocItems $NewsSource }
        "gdelt-file" { return Read-GdeltFileItems $NewsSource }
        default { return Read-FeedItems $NewsSource }
    }
}

function Select-NewsSources {
    param(
        $Settings,
        [string]$RequestedSource
    )

    $enabled = @($Settings.sources | Where-Object { $_.enabled -ne $false })
    $sourceId = if ($RequestedSource) { $RequestedSource } else { $Settings.defaultSource }

    if ([string]::IsNullOrWhiteSpace($sourceId) -or $sourceId -eq "all") {
        return $enabled
    }

    $found = @($enabled | Where-Object { $_.id -eq $sourceId })
    if ($found.Count -eq 0) {
        $available = ($enabled | ForEach-Object { $_.id }) -join ", "
        throw "Unknown source '$sourceId'. Available sources: $available"
    }

    return $found
}

function Remove-DuplicateItems {
    param($Items)

    $seen = @{}
    $results = @()

    foreach ($item in $Items) {
        $key = Get-DedupeKey $item
        if ([string]::IsNullOrWhiteSpace($key) -or $seen.ContainsKey($key)) {
            continue
        }

        $seen[$key] = $true
        $results += $item
    }

    return $results
}

function Get-DedupeKey {
    param($Item)

    if ($Item.sourceKind -eq "world-monitor-wire" -and $Item.title) {
        return [string]$Item.title
    }
    if ($Item.link) {
        return [string]$Item.link
    }
    if ($Item.id) {
        return [string]$Item.id
    }
    return [string]$Item.title
}

function Sort-NewsItems {
    param($Items)

    return @($Items | Sort-Object -Property @{ Expression = {
        if ($_.intensity) {
            [int]$_.intensity
        }
        else {
            0
        }
    }; Descending = $true }, @{ Expression = {
        if ($_.mentionCount) {
            [int]$_.mentionCount
        }
        else {
            0
        }
    }; Descending = $true }, @{ Expression = {
        if ($_.pubDate) {
            [DateTimeOffset]::Parse($_.pubDate)
        }
        else {
            [DateTimeOffset]::MinValue
        }
    }; Descending = $true })
}

function Test-FocusItem {
    param(
        $Item,
        [string]$Patterns
    )

    $text = "$($Item.title) $($Item.description) $($Item.rawSummary) $($Item.locationName) $($Item.country)"
    return $text -match $Patterns
}

function Select-FinalItems {
    param(
        $Items,
        [int]$MaxItems,
        $NewsSources
    )

    $sorted = Sort-NewsItems $Items
    $wireSource = @($NewsSources | Where-Object { $_.type -like "world-monitor-wire*" } | Select-Object -First 1)
    if ($wireSource.Count -eq 0 -or -not $wireSource[0].article.focus) {
        return @($sorted | Select-Object -First $MaxItems)
    }

    $focus = $wireSource[0].article.focus
    $longTail = $wireSource[0].article.longTail
    $minFocusItems = if ($focus.minItems) { [int]$focus.minItems } else { 0 }
    $minLongTailItems = if ($longTail -and $longTail.minItems) { [int]$longTail.minItems } else { 0 }
    $maxLongTailIntensity = if ($longTail -and $longTail.maxIntensity) { [int]$longTail.maxIntensity } else { 0 }

    if ($minFocusItems -le 0 -and $minLongTailItems -le 0) {
        return @($sorted | Select-Object -First $MaxItems)
    }

    $reservedLongTailSlots = [Math]::Min($minLongTailItems, $MaxItems)
    $focusLimit = [Math]::Min($minFocusItems, [Math]::Max(0, $MaxItems - $reservedLongTailSlots))
    $focusItems = @()
    if ($focusLimit -gt 0 -and -not [string]::IsNullOrWhiteSpace([string]$focus.patterns)) {
        $focusItems = @(Sort-NewsItems (@($Items | Where-Object { Test-FocusItem $_ $focus.patterns })) |
            Select-Object -First $focusLimit)
    }

    $longTailItems = @()
    if ($reservedLongTailSlots -gt 0 -and $maxLongTailIntensity -gt 0) {
        $longTailItems = @(Sort-NewsItems (@($Items | Where-Object {
            $_.sourceKind -eq "world-monitor-wire" -and
                $_.intensity -and
                [int]$_.intensity -le $maxLongTailIntensity -and
                $_.categoryId -eq "low-heat"
        })) | Select-Object -First $reservedLongTailSlots)
    }

    $selected = @()
    $seen = @{}

    foreach ($item in $focusItems) {
        $key = Get-DedupeKey $item
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $selected += $item
        }
    }

    $mainLimit = [Math]::Max(0, $MaxItems - $reservedLongTailSlots)
    foreach ($item in $sorted) {
        if ($selected.Count -ge $mainLimit) {
            break
        }

        $key = Get-DedupeKey $item
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $selected += $item
        }
    }

    foreach ($item in $longTailItems) {
        if ($selected.Count -ge $MaxItems) {
            break
        }

        $key = Get-DedupeKey $item
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $selected += $item
        }
    }

    foreach ($item in $sorted) {
        if ($selected.Count -ge $MaxItems) {
            break
        }

        $key = Get-DedupeKey $item
        if (-not $seen.ContainsKey($key)) {
            $seen[$key] = $true
            $selected += $item
        }
    }

    return $selected
}

function Render-Markdown {
    param(
        $Items,
        $Settings,
        [string]$DateLabel,
        [datetime]$GeneratedAt,
        [int]$DaysBack,
        $NewsSources,
        [System.TimeZoneInfo]$TimeZone
    )

    $wireItems = @($Items | Where-Object { $_.sourceKind -eq "world-monitor-wire" })
    if ($wireItems.Count -gt 0) {
        return Render-WireArticle $wireItems $Settings $DateLabel $GeneratedAt $DaysBack $NewsSources $TimeZone
    }

    $titleTemplate = if ($Settings.wechat.titleTemplate) { $Settings.wechat.titleTemplate } else { "Daily News {date}" }
    $title = $titleTemplate.Replace("{date}", $DateLabel)
    $sourceNames = ($NewsSources | ForEach-Object { if ($_.name) { $_.name } else { $_.id } }) -join ", "
    $includeLinks = $Settings.wechat.includeOriginalLinks -ne $false
    $labels = $Settings.wechat.labels

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $title")
    $lines.Add("")
    if ($Settings.wechat.intro) {
        $lines.Add([string]$Settings.wechat.intro)
        $lines.Add("")
    }
    $lines.Add((Get-Label $labels "generatedAt" "Generated at") + ": " + (Format-Date $GeneratedAt $TimeZone "yyyy-MM-dd HH:mm"))
    $lines.Add((Get-Label $labels "sources" "Sources") + ": $sourceNames")
    $windowText = if ($Settings.wechat.windowTemplate) {
        ([string]$Settings.wechat.windowTemplate).Replace("{days}", [string]$DaysBack)
    }
    else {
        "last $DaysBack day(s)"
    }
    $lines.Add((Get-Label $labels "window" "Window") + ": $windowText")
    $lines.Add("")
    $lines.Add("## " + (Get-Label $labels "topStories" "Top Stories"))
    $lines.Add("")

    if ($Items.Count -eq 0) {
        $lines.Add((Get-Label $labels "noItems" "No matching news items were found today."))
        return ($lines -join "`n") + "`n"
    }

    for ($index = 0; $index -lt $Items.Count; $index++) {
        $item = $Items[$index]
        $number = $index + 1
        $lines.Add("### $number. $($item.title)")
        if ($item.description) {
            $lines.Add((Get-Label $labels "summary" "Summary") + ": $($item.description)")
        }
        if ($item.pubDate) {
            $date = [datetime]::Parse($item.pubDate)
            $lines.Add((Get-Label $labels "time" "Time") + ": " + (Format-Date $date $TimeZone "yyyy-MM-dd HH:mm"))
        }
        if ($includeLinks -and $item.link) {
            $lines.Add((Get-Label $labels "original" "Original") + ": $($item.link)")
        }
        $lines.Add("")
    }

    $lines.Add("## " + (Get-Label $labels "checklistTitle" "Pre-publish Checklist"))
    $lines.Add("")
    $checklist = @($Settings.wechat.checklist)
    if ($checklist.Count -eq 0) {
        $checklist = @(
            "Check titles, timestamps, and facts.",
            "Do not republish full articles without permission.",
            "Keep source links or source attribution."
        )
    }
    foreach ($checkItem in $checklist) {
        $lines.Add("- $checkItem")
    }

    return ($lines -join "`n") + "`n"
}

function Clean-PublishText {
    param([string]$Text)

    $fullWidthComma = [string][char]0xFF0C
    $clean = [regex]::Replace($Text, "WIRE\s+\p{IsCJKUnifiedIdeographs}{4}[$fullWidthComma,]?", "")
    $oldFallback = "WIRE " + [string][char]0x5C06 + [string][char]0x8BE5 + [string][char]0x4E8B + [string][char]0x4EF6 + [string][char]0x6807 + [string][char]0x8BB0 + [string][char]0x4E3A
    $newFallback = [string][char]0x8BE5 + [string][char]0x4E8B + [string][char]0x4EF6 + [string][char]0x88AB + [string][char]0x6807 + [string][char]0x8BB0 + [string][char]0x4E3A
    $clean = $clean.Replace($oldFallback, $newFallback)
    return $clean
}

function Convert-MarkdownToPlainText {
    param([string]$Markdown)

    $lines = New-Object System.Collections.Generic.List[string]
    foreach ($line in ($Markdown -split "`r?`n")) {
        $clean = $line
        $clean = [regex]::Replace($clean, "^#{1,6}\s*", "")
        if ($clean -eq "---") {
            continue
        }
        $lines.Add($clean)
    }

    return (($lines -join "`r`n").Trim() + "`r`n")
}

function Render-WireArticle {
    param(
        $Items,
        $Settings,
        [string]$DateLabel,
        [datetime]$GeneratedAt,
        [int]$DaysBack,
        $NewsSources,
        [System.TimeZoneInfo]$TimeZone
    )

    $source = $NewsSources[0]
    $article = $source.article
    $labels = $article.labels
    $title = if ($article.titleTemplate) { [string]$article.titleTemplate } else { "World Monitor Wire Brief" }
    $title = $title.Replace("{date}", $DateLabel)

    $lines = New-Object System.Collections.Generic.List[string]
    $lines.Add("# $title")
    $lines.Add("")
    if ($article.intro) {
        $lines.Add(([string]$article.intro).Replace("{date}", $DateLabel))
        $lines.Add("")
    }

    $windowText = (Get-ArticleLabel $labels "lastDays" "last {days} day(s)").Replace("{days}", [string]$DaysBack)
    $lines.Add((Get-ArticleLabel $labels "generatedAt" "Generated at") + ": " + (Format-Date $GeneratedAt $TimeZone "yyyy-MM-dd HH:mm"))
    $lines.Add((Get-ArticleLabel $labels "window" "Window") + ": $windowText")
    $lines.Add((Get-ArticleLabel $labels "eventCount" "Events") + ": $($Items.Count) " + (Get-ArticleLabel $labels "eventUnit" "item(s)"))
    $lines.Add("")

    $orderedCategoryIds = @($article.categoryOrder)
    $seenCategories = @{}
    $sectionNumber = 1

    foreach ($categoryId in $orderedCategoryIds) {
        $categoryItems = @($Items | Where-Object { $_.categoryId -eq $categoryId })
        if ($categoryItems.Count -eq 0) {
            continue
        }

        $seenCategories[$categoryId] = $true
        $sectionName = $categoryItems[0].categoryName
        Add-WireCategorySection $lines $sectionNumber $sectionName $categoryItems $TimeZone $labels $article.showMeta
        $sectionNumber += 1
    }

    $remaining = @($Items | Where-Object { -not $seenCategories.ContainsKey($_.categoryId) })
    if ($remaining.Count -gt 0) {
        Add-WireCategorySection $lines $sectionNumber "Other" $remaining $TimeZone $labels $article.showMeta
    }

    if ($article.closing) {
        $lines.Add("## " + (Get-ArticleLabel $labels "closingTitle" "Closing"))
        $lines.Add("")
        $lines.Add([string]$article.closing)
        $lines.Add("")
    }

    if ($article.sourceNote) {
        $lines.Add("---")
        $lines.Add("")
        $lines.Add([string]$article.sourceNote)
    }

    return ($lines -join "`n") + "`n"
}

function Add-WireCategorySection {
    param(
        [System.Collections.Generic.List[string]]$Lines,
        [int]$SectionNumber,
        [string]$SectionName,
        $Items,
        [System.TimeZoneInfo]$TimeZone,
        $Labels,
        $ShowMeta
    )

    $Lines.Add("## $SectionNumber. $SectionName")
    $Lines.Add("")

    for ($index = 0; $index -lt $Items.Count; $index++) {
        $item = $Items[$index]
        $itemNumber = $index + 1
        $Lines.Add("### $itemNumber. $($item.title)")
        $Lines.Add("")
        $Lines.Add([string]$item.description)
        $Lines.Add("")

        if ($ShowMeta -eq $true) {
            $meta = (Get-ArticleLabel $Labels "intensity" "Intensity") + ": $($item.intensity)/5; " +
                (Get-ArticleLabel $Labels "mentions" "WIRE mentions") + ": $($item.mentionCount) " +
                (Get-ArticleLabel $Labels "mentionUnit" "time(s)") + "; " +
                (Get-ArticleLabel $Labels "location" "Location") + ": $($item.locationName)"
            if ($item.country) {
                $meta += ", $($item.country)"
            }
            if ($item.pubDate) {
                $date = [datetime]::Parse($item.pubDate)
                $meta += "; " + (Get-ArticleLabel $Labels "updatedAt" "Updated at") + ": " + (Format-Date $date $TimeZone "yyyy-MM-dd HH:mm")
            }
            $Lines.Add($meta)
            $Lines.Add("")
        }
    }
}

function Get-ArticleLabel {
    param(
        $Labels,
        [string]$Name,
        [string]$Fallback
    )

    if ($Labels -and $Labels.$Name) {
        return [string]$Labels.$Name
    }

    return $Fallback
}

function Get-Label {
    param(
        $Labels,
        [string]$Name,
        [string]$Fallback
    )

    if ($Labels -and $Labels.$Name) {
        return [string]$Labels.$Name
    }

    return $Fallback
}

$configPath = Resolve-ProjectPath $Config
$settings = Get-Content -LiteralPath $configPath -Raw -Encoding utf8 | ConvertFrom-Json

$selectedSources = @(Select-NewsSources $settings $Source)
$maxItems = if ($Limit -gt 0) { $Limit } else { [int]$settings.limit }
$daysBack = if ($Days -gt 0) { $Days } else { [int]$settings.daysBack }
$outputDir = Resolve-ProjectPath $(if ($Out) { $Out } else { $settings.outputDir })
$timeZone = Get-TimeZoneInfo $settings.timezone

$allItems = @()
foreach ($newsSource in $selectedSources) {
    $allItems += Read-SourceItems $newsSource
}

$cutoff = [DateTimeOffset]::UtcNow.AddDays(-1 * $daysBack)
$candidateItems = @(Remove-DuplicateItems $allItems |
    Where-Object {
        if (-not $_.pubDate) {
            return $true
        }

        return ([DateTimeOffset]::Parse($_.pubDate) -ge $cutoff)
    })
$recentItems = @(Select-FinalItems $candidateItems $maxItems $selectedSources)

$generatedAt = [datetime]::UtcNow
$dateLabel = Format-Date $generatedAt $timeZone "yyyy-MM-dd"
$sourceLabel = if ($Source) { $Source } else { $settings.defaultSource }
$slug = ([regex]::Replace($sourceLabel.ToLowerInvariant(), "[^a-z0-9_-]+", "-")).Trim("-")
$baseName = "$dateLabel`_$slug"

New-Item -ItemType Directory -Force -Path $outputDir | Out-Null

$markdownPath = Join-Path $outputDir "$baseName.md"
$jsonPath = Join-Path $outputDir "$baseName.json"

$markdown = Render-Markdown $recentItems $settings $dateLabel $generatedAt $daysBack $selectedSources $timeZone
$markdown = Clean-PublishText $markdown
Set-Content -LiteralPath $markdownPath -Value $markdown -Encoding utf8

$textPath = $null
if ($TextOut -or $settings.textOutputDir) {
    $textOutputDir = Resolve-ProjectPath $(if ($TextOut) { $TextOut } else { $settings.textOutputDir })
    New-Item -ItemType Directory -Force -Path $textOutputDir | Out-Null
    $textPath = Join-Path $textOutputDir "$baseName.txt"
    $plainText = Convert-MarkdownToPlainText $markdown
    Set-Content -LiteralPath $textPath -Value $plainText -Encoding utf8
}

$payload = [pscustomobject]@{
    generatedAt = $generatedAt.ToString("o")
    timezone = $settings.timezone
    sources = @($selectedSources | ForEach-Object {
        [pscustomobject]@{
            id = $_.id
            name = $_.name
            url = $_.url
        }
    })
    count = $recentItems.Count
    items = $recentItems
}

$payload | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $jsonPath -Encoding utf8

Write-Host "Generated $($recentItems.Count) item(s)."
Write-Host "Markdown: $markdownPath"
Write-Host "JSON: $jsonPath"
if ($textPath) {
    Write-Host "TXT: $textPath"
}
