#Requires -Version 7.4
# Posts the CopilotLedger receipt that a pull request commits as one comment, and updates that comment on later runs.
# action.yml passes the inputs and pull request fields as environment variables. See README.md.
# Strings are compared with [string]::Equals and an ordinal StringComparison, never -eq or -ceq: PowerShell compares
# strings with culture rules, which ignore zero-width characters and a byte order mark.

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$Marker = '<!-- copilot-ledger-receipt -->'
$MaximumBytes = 65536
$PageSize = 100
$MaximumPages = 30

function ConvertTo-CommandValue([string] $Value) {
    return $Value.Replace('%', '%25').Replace("`r", '%0D').Replace("`n", '%0A')
}

function Write-Notice([string] $Message) {
    Write-Host "::notice::$(ConvertTo-CommandValue $Message)"
}

function Stop-WithError([string] $Message) {
    Write-Host "::error::$(ConvertTo-CommandValue $Message)"
    exit 1
}

function Set-ActionOutput([string] $Name, [string] $Value) {
    [System.IO.File]::AppendAllText(
        $env:GITHUB_OUTPUT,
        "$Name=$Value`n",
        [System.Text.UTF8Encoding]::new($false))
}

function Invoke-GitHubApi([string] $Method, [string] $Path, [string] $Body = '') {
    $parameters = @{
        Uri = "$($env:GITHUB_API_URL.TrimEnd('/'))/$Path"
        Method = $Method
        Headers = @{
            Authorization = "Bearer $($env:RECEIPT_TOKEN)"
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2026-03-10'
        }
    }
    if ($Body.Length -gt 0) {
        $parameters.Body = [System.Text.Encoding]::UTF8.GetBytes($Body)
        $parameters.ContentType = 'application/json'
    }

    $response = Invoke-WebRequest @parameters
    return [System.Text.Json.JsonDocument]::Parse([string] $response.Content).RootElement.Clone()
}

function Get-StringProperty([System.Text.Json.JsonElement] $Element, [string] $Name) {
    $value = [System.Text.Json.JsonElement]::new()
    if ($Element.ValueKind -eq [System.Text.Json.JsonValueKind]::Object -and
        $Element.TryGetProperty($Name, [ref] $value) -and
        $value.ValueKind -eq [System.Text.Json.JsonValueKind]::String) {
        return $value.GetString()
    }

    return $null
}

function Get-Pages([string] $Path) {
    $items = [System.Collections.Generic.List[System.Text.Json.JsonElement]]::new()
    for ($page = 1; $page -le $MaximumPages; $page++) {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $array = Invoke-GitHubApi 'GET' "$Path${separator}per_page=$PageSize&page=$page"
        $count = 0
        foreach ($item in $array.EnumerateArray()) {
            $items.Add($item)
            $count++
        }

        if ($count -lt $PageSize) {
            break
        }
    }

    return , $items
}

function Read-Receipt([string] $Repository, [string] $Path, [string] $Sha) {
    $encodedPath = ($Path.Split('/') | ForEach-Object { [System.Uri]::EscapeDataString($_) }) -join '/'
    $item = Invoke-GitHubApi 'GET' "repos/$Repository/contents/$($encodedPath)?ref=$Sha"
    $size = $item.GetProperty('size').GetInt64()
    if ($size -gt $MaximumBytes) {
        Stop-WithError "$Path is $size bytes; a receipt can be at most $MaximumBytes bytes."
    }

    $bytes = [System.Convert]::FromBase64String((Get-StringProperty $item 'content'))
    try {
        $text = [System.Text.UTF8Encoding]::new($false, $true).GetString($bytes)
    }
    catch [System.Text.DecoderFallbackException] {
        Stop-WithError "$Path is not valid UTF-8."
    }

    [string[]] $lines = @($text.Split("`n") | ForEach-Object { $_.TrimEnd("`r") })
    if (-not [string]::Equals($lines[0], $Marker, [System.StringComparison]::Ordinal)) {
        Stop-WithError "$Path doesn't start with $Marker, so it isn't a CopilotLedger receipt."
    }

    $start = [System.Array]::IndexOf($lines, '```json')
    $end = if ($start -lt 0) { -1 } else { [System.Array]::IndexOf($lines, '```', $start + 1) }
    if ($start -lt 0 -or $end -le $start + 1) {
        Stop-WithError "$Path has no JSON data block."
    }

    try {
        $data = [System.Text.Json.JsonDocument]::Parse(($lines[($start + 1)..($end - 1)] -join "`n")).RootElement.Clone()
    }
    catch [System.Text.Json.JsonException] {
        Stop-WithError "$Path has invalid JSON data: $($_.Exception.Message)"
    }

    $version = [System.Text.Json.JsonElement]::new()
    if ($data.ValueKind -ne [System.Text.Json.JsonValueKind]::Object -or
        -not $data.TryGetProperty('schemaVersion', [ref] $version) -or
        $version.ValueKind -ne [System.Text.Json.JsonValueKind]::Number -or
        -not [string]::Equals($version.GetRawText(), '1', [System.StringComparison]::Ordinal)) {
        Stop-WithError "$Path has an unsupported schemaVersion; this action reads schemaVersion 1."
    }

    $branch = Get-StringProperty $data 'branch'
    if ($null -eq $branch) {
        Stop-WithError "$Path has no branch."
    }

    return [pscustomobject]@{ Path = $Path; Branch = $branch; Text = $text }
}

if (-not [string]::Equals($env:EVENT_NAME, 'pull_request', [System.StringComparison]::Ordinal)) {
    Stop-WithError "The CopilotLedger receipt action runs on pull_request events, not $($env:EVENT_NAME)."
}

$repository = $env:GITHUB_REPOSITORY
if (-not [string]::Equals($env:HEAD_REPOSITORY, $repository, [System.StringComparison]::OrdinalIgnoreCase)) {
    Write-Notice 'Skipped the CopilotLedger receipt: workflows for pull requests from forks get a read-only token, so they can''t comment.'
    Set-ActionOutput 'result' 'skipped'
    Set-ActionOutput 'comment-url' ''
    exit 0
}

$directory = $env:RECEIPTS_DIRECTORY.Trim('/') + '/'
$candidates = [System.Collections.Generic.List[string]]::new()
foreach ($file in (Get-Pages "repos/$repository/pulls/$($env:PR_NUMBER)/files")) {
    $name = Get-StringProperty $file 'filename'
    if ($null -ne $name -and
        -not [string]::Equals((Get-StringProperty $file 'status'), 'removed', [System.StringComparison]::Ordinal) -and
        $name.StartsWith($directory, [System.StringComparison]::Ordinal) -and
        $name.EndsWith('.md', [System.StringComparison]::Ordinal)) {
        $candidates.Add($name)
    }
}

if ($candidates.Count -eq 0) {
    Write-Notice "No CopilotLedger receipt changed in this pull request. Run gh ledger export-pr on the branch, then commit the file it writes under $directory."
    Set-ActionOutput 'result' 'no-receipt'
    Set-ActionOutput 'comment-url' ''
    exit 0
}

$receipts = @($candidates | ForEach-Object { Read-Receipt $repository $_ $env:HEAD_SHA })
$matching = @($receipts | Where-Object { [string]::Equals($_.Branch, $env:HEAD_REF, [System.StringComparison]::Ordinal) })
if ($matching.Count -eq 0) {
    $found = ($receipts | ForEach-Object { $_.Branch }) -join ', '
    Stop-WithError "No receipt for $($env:HEAD_REF) changed in this pull request; found receipts for: $found."
}

if ($matching.Count -gt 1) {
    $paths = ($matching | ForEach-Object { $_.Path }) -join ', '
    Stop-WithError "More than one receipt for $($env:HEAD_REF) changed in this pull request: $paths."
}

$receipt = $matching[0]
$existing = $null
foreach ($comment in (Get-Pages "repos/$repository/issues/$($env:PR_NUMBER)/comments")) {
    $user = [System.Text.Json.JsonElement]::new()
    $login = if ($comment.TryGetProperty('user', [ref] $user)) { Get-StringProperty $user 'login' } else { $null }
    $body = Get-StringProperty $comment 'body'
    if ($null -ne $login -and
        [string]::Equals($login, $env:COMMENT_AUTHOR, [System.StringComparison]::OrdinalIgnoreCase) -and
        $null -ne $body -and
        $body.StartsWith($Marker, [System.StringComparison]::Ordinal)) {
        $existing = $comment
        break
    }
}

$payload = '{"body":' + (ConvertTo-Json -InputObject $receipt.Text -Compress) + '}'
if ($null -eq $existing) {
    $created = Invoke-GitHubApi 'POST' "repos/$repository/issues/$($env:PR_NUMBER)/comments" $payload
    $result = 'created'
    $url = Get-StringProperty $created 'html_url'
}
elseif ([string]::Equals(
        (Get-StringProperty $existing 'body').Replace("`r`n", "`n"),
        $receipt.Text.Replace("`r`n", "`n"),
        [System.StringComparison]::Ordinal)) {
    $result = 'unchanged'
    $url = Get-StringProperty $existing 'html_url'
}
else {
    $id = $existing.GetProperty('id').GetInt64()
    $updated = Invoke-GitHubApi 'PATCH' "repos/$repository/issues/comments/$id" $payload
    $result = 'updated'
    $url = Get-StringProperty $updated 'html_url'
}

Write-Host "CopilotLedger receipt ${result}: $url"
Set-ActionOutput 'result' $result
Set-ActionOutput 'comment-url' $url
exit 0
