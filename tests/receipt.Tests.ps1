#Requires -Version 7.4
# Runs receipt.ps1 against a fake GitHub REST API. No network.
# Usage: pwsh -NoProfile -File tests/receipt.Tests.ps1

Set-StrictMode -Version 3.0
$ErrorActionPreference = 'Stop'

$ScriptPath = Join-Path $PSScriptRoot '..' 'receipt.ps1'
$Api = 'https://api.github.test'
$Repository = 'octo/widgets'
$Sha = '0123456789abcdef0123456789abcdef01234567'
$Directory = '.github/copilot-ledger/receipts'
$ReceiptPath = "$Directory/feature-ledger-0a1b2c3d.md"
$FilesUri = "GET $Api/repos/$Repository/pulls/7/files?per_page=100&page=1"
$ContentUri = "GET $Api/repos/$Repository/contents/.github/copilot-ledger/receipts/feature-ledger-0a1b2c3d.md?ref=$Sha"
$CommentsUri = "GET $Api/repos/$Repository/issues/7/comments?per_page=100&page=1"
$CreateUri = "POST $Api/repos/$Repository/issues/7/comments"

$ReceiptText = @'
<!-- copilot-ledger-receipt -->
### CopilotLedger receipt for `feature/ledger` — 56.00 AI credits

<details>
<summary>Data</summary>

```json
{
  "schemaVersion": 1,
  "branch": "feature/ledger"
}
```

</details>
'@.ReplaceLineEndings("`n") + "`n"

$Fake = @{ Requests = $null; Bodies = $null; Headers = $null; Responses = $null }
$Failures = [System.Collections.Generic.List[string]]::new()

# Replaces the cmdlet for receipt.ps1, which runs in a child scope of this script.
function Invoke-WebRequest {
    param(
        [string] $Uri,
        [string] $Method,
        [hashtable] $Headers,
        [byte[]] $Body,
        [string] $ContentType)
    $key = "$Method $Uri"
    $Fake.Requests.Add($key)
    $Fake.Headers = $Headers
    if ($null -ne $Body) {
        $Fake.Bodies.Add("$ContentType $([System.Text.Encoding]::UTF8.GetString($Body))")
    }

    if (-not $Fake.Responses.ContainsKey($key)) {
        throw "Unexpected request: $key"
    }

    return [pscustomobject]@{ Content = $Fake.Responses[$key] }
}

function ConvertTo-CompactJson($Value) {
    return ConvertTo-Json -InputObject $Value -Compress -Depth 5
}

function New-Files([object[]] $Files) {
    return ConvertTo-CompactJson @($Files | ForEach-Object { [ordered]@{ filename = $_[0]; status = $_[1] } })
}

function New-Content([string] $Text, [long] $Size = -1) {
    $bytes = [System.Text.UTF8Encoding]::new($false).GetBytes($Text)
    return ConvertTo-CompactJson ([ordered]@{
        size = if ($Size -ge 0) { $Size } else { $bytes.Length }
        encoding = 'base64'
        content = [System.Convert]::ToBase64String($bytes, [System.Base64FormattingOptions]::InsertLineBreaks)
    })
}

function New-Comment([long] $Id, [string] $Login, [string] $Body) {
    return [ordered]@{
        id = $Id
        user = [ordered]@{ login = $Login }
        body = $Body
        html_url = "https://github.test/octo/widgets/pull/7#issuecomment-$Id"
    }
}

function Invoke-Receipt([hashtable] $Responses, [hashtable] $Environment = @{}) {
    $Fake.Requests = [System.Collections.Generic.List[string]]::new()
    $Fake.Bodies = [System.Collections.Generic.List[string]]::new()
    $Fake.Headers = $null
    $Fake.Responses = $Responses
    $outputFile = [System.IO.Path]::GetTempFileName()
    $values = @{
        GITHUB_API_URL = $Api
        GITHUB_REPOSITORY = $Repository
        GITHUB_OUTPUT = $outputFile
        RECEIPT_TOKEN = 'test-token'
        RECEIPTS_DIRECTORY = $Directory
        COMMENT_AUTHOR = 'github-actions[bot]'
        EVENT_NAME = 'pull_request'
        PR_NUMBER = '7'
        HEAD_REF = 'feature/ledger'
        HEAD_SHA = $Sha
        HEAD_REPOSITORY = $Repository
    }
    foreach ($name in $Environment.Keys) {
        $values[$name] = $Environment[$name]
    }

    foreach ($name in $values.Keys) {
        [System.Environment]::SetEnvironmentVariable($name, $values[$name])
    }

    $global:LASTEXITCODE = 0
    try {
        [string[]] $lines = @(& $ScriptPath *>&1 | ForEach-Object { "$_" })
    }
    catch {
        # An unexpected request fails this case, not the whole run.
        [string[]] $lines = @("exception: $($_.Exception.Message)")
        $global:LASTEXITCODE = 99
    }

    $run = [pscustomobject]@{
        ExitCode = $global:LASTEXITCODE
        Lines = $lines
        Outputs = [System.IO.File]::ReadAllText($outputFile)
        Requests = [string[]] $Fake.Requests.ToArray()
        Bodies = [string[]] $Fake.Bodies.ToArray()
        Headers = $Fake.Headers
    }
    Remove-Item -LiteralPath $outputFile
    return $run
}

function Assert-Equal($Expected, $Actual, [string] $Message) {
    $expectedJson = ConvertTo-Json -InputObject $Expected -Compress -Depth 5 -EscapeHandling EscapeNonAscii
    $actualJson = ConvertTo-Json -InputObject $Actual -Compress -Depth 5 -EscapeHandling EscapeNonAscii
    if (-not [string]::Equals($expectedJson, $actualJson, [System.StringComparison]::Ordinal)) {
        $Failures.Add("$Message`n  expected: $expectedJson`n  actual:   $actualJson")
    }
}

function Get-PostedBody([string] $Request) {
    $json = $Request.Substring('application/json '.Length)
    return [System.Text.Json.JsonDocument]::Parse($json).RootElement.GetProperty('body').GetString()
}

# AC1: a new receipt is posted as a new comment.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(@('src/app.cs', 'modified'), @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText
    $CommentsUri = '[]'
    $CreateUri = ConvertTo-CompactJson (New-Comment 100 'github-actions[bot]' $ReceiptText)
}
Assert-Equal 0 $run.ExitCode 'AC1 exit code'
Assert-Equal @('CopilotLedger receipt created: https://github.test/octo/widgets/pull/7#issuecomment-100') $run.Lines 'AC1 log'
Assert-Equal "result=created`ncomment-url=https://github.test/octo/widgets/pull/7#issuecomment-100`n" $run.Outputs 'AC1 outputs'
Assert-Equal @($FilesUri, $ContentUri, $CommentsUri, $CreateUri) $run.Requests 'AC1 requests'
Assert-Equal 1 $run.Bodies.Count 'AC1 body count'
Assert-Equal $ReceiptText (Get-PostedBody $run.Bodies[0]) 'AC1 posted body'
Assert-Equal 'Bearer test-token' $run.Headers['Authorization'] 'AC1 authorization header'
Assert-Equal 'application/vnd.github+json' $run.Headers['Accept'] 'AC1 accept header'
Assert-Equal '2026-03-10' $run.Headers['X-GitHub-Api-Version'] 'AC1 API version header'

# AC2: the bot's earlier receipt comment is updated in place.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'modified'))
    $ContentUri = New-Content $ReceiptText
    $CommentsUri = ConvertTo-CompactJson @(
        (New-Comment 54 'octocat' 'Looks good'),
        (New-Comment 55 'github-actions[bot]' "<!-- copilot-ledger-receipt -->`nold"))
    "PATCH $Api/repos/$Repository/issues/comments/55" = ConvertTo-CompactJson (New-Comment 55 'github-actions[bot]' $ReceiptText)
}
Assert-Equal 0 $run.ExitCode 'AC2 exit code'
Assert-Equal @('CopilotLedger receipt updated: https://github.test/octo/widgets/pull/7#issuecomment-55') $run.Lines 'AC2 log'
Assert-Equal "result=updated`ncomment-url=https://github.test/octo/widgets/pull/7#issuecomment-55`n" $run.Outputs 'AC2 outputs'
Assert-Equal @($FilesUri, $ContentUri, $CommentsUri, "PATCH $Api/repos/$Repository/issues/comments/55") $run.Requests 'AC2 requests'
Assert-Equal $ReceiptText (Get-PostedBody $run.Bodies[0]) 'AC2 posted body'

# AC3: an identical comment (stored with CRLF line endings) isn't edited.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText
    $CommentsUri = ConvertTo-CompactJson @(, (New-Comment 56 'github-actions[bot]' $ReceiptText.Replace("`n", "`r`n")))
}
Assert-Equal 0 $run.ExitCode 'AC3 exit code'
Assert-Equal @('CopilotLedger receipt unchanged: https://github.test/octo/widgets/pull/7#issuecomment-56') $run.Lines 'AC3 log'
Assert-Equal "result=unchanged`ncomment-url=https://github.test/octo/widgets/pull/7#issuecomment-56`n" $run.Outputs 'AC3 outputs'
Assert-Equal @($FilesUri, $ContentUri, $CommentsUri) $run.Requests 'AC3 requests'

# AC4: a marker comment by someone else isn't touched; the action adds its own.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText
    $CommentsUri = ConvertTo-CompactJson @(, (New-Comment 57 'octocat' $ReceiptText))
    $CreateUri = ConvertTo-CompactJson (New-Comment 101 'github-actions[bot]' $ReceiptText)
}
Assert-Equal 0 $run.ExitCode 'AC4 exit code'
Assert-Equal "result=created`ncomment-url=https://github.test/octo/widgets/pull/7#issuecomment-101`n" $run.Outputs 'AC4 outputs'
Assert-Equal @($FilesUri, $ContentUri, $CommentsUri, $CreateUri) $run.Requests 'AC4 requests'

# AC5: no receipt in the pull request (a removed receipt doesn't count).
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(@('src/app.cs', 'modified'), @($ReceiptPath, 'removed'), @("$Directory/notes.txt", 'added'))
}
Assert-Equal 0 $run.ExitCode 'AC5 exit code'
Assert-Equal @('::notice::No CopilotLedger receipt changed in this pull request. Run gh ledger export-pr on the branch, then commit the file it writes under .github/copilot-ledger/receipts/.') $run.Lines 'AC5 log'
Assert-Equal "result=no-receipt`ncomment-url=`n" $run.Outputs 'AC5 outputs'
Assert-Equal @(, $FilesUri) $run.Requests 'AC5 requests'

# AC6: pull requests from forks are skipped without any request.
$run = Invoke-Receipt @{} @{ HEAD_REPOSITORY = 'fork-owner/widgets' }
Assert-Equal 0 $run.ExitCode 'AC6 exit code'
Assert-Equal @('::notice::Skipped the CopilotLedger receipt: workflows for pull requests from forks get a read-only token, so they can''t comment.') $run.Lines 'AC6 log'
Assert-Equal "result=skipped`ncomment-url=`n" $run.Outputs 'AC6 outputs'
Assert-Equal @() $run.Requests 'AC6 requests'

# AC7: other events fail without any request.
$run = Invoke-Receipt @{} @{ EVENT_NAME = 'pull_request_target' }
Assert-Equal 1 $run.ExitCode 'AC7 exit code'
Assert-Equal @('::error::The CopilotLedger receipt action runs on pull_request events, not pull_request_target.') $run.Lines 'AC7 log'
Assert-Equal '' $run.Outputs 'AC7 outputs'
Assert-Equal @() $run.Requests 'AC7 requests'

# AC8: a receipt for another branch fails.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText
} @{ HEAD_REF = 'feature/other' }
Assert-Equal 1 $run.ExitCode 'AC8 exit code'
Assert-Equal @('::error::No receipt for feature/other changed in this pull request; found receipts for: feature/ledger.') $run.Lines 'AC8 log'
Assert-Equal @($FilesUri, $ContentUri) $run.Requests 'AC8 requests'

# AC9: a file without the marker fails.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content ("# Notes`n" + $ReceiptText)
}
Assert-Equal 1 $run.ExitCode 'AC9 exit code'
Assert-Equal @("::error::$ReceiptPath doesn't start with <!-- copilot-ledger-receipt -->, so it isn't a CopilotLedger receipt.") $run.Lines 'AC9 log'

# AC10: a receipt over 65,536 bytes fails before it's decoded.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText 65537
}
Assert-Equal 1 $run.ExitCode 'AC10 exit code'
Assert-Equal @("::error::$ReceiptPath is 65537 bytes; a receipt can be at most 65536 bytes.") $run.Lines 'AC10 log'

# AC11: invalid JSON in the data block fails.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText.Replace('"schemaVersion": 1,', '"schemaVersion": 1')
}
Assert-Equal 1 $run.ExitCode 'AC11 exit code'
Assert-Equal 1 $run.Lines.Count 'AC11 log line count'
Assert-Equal $true ($run.Lines[0].StartsWith("::error::$ReceiptPath has invalid JSON data: ", [System.StringComparison]::Ordinal)) 'AC11 log'

# AC12: an unsupported schema version fails.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText.Replace('"schemaVersion": 1,', '"schemaVersion": 2,')
}
Assert-Equal 1 $run.ExitCode 'AC12 exit code'
Assert-Equal @("::error::$ReceiptPath has an unsupported schemaVersion; this action reads schemaVersion 1.") $run.Lines 'AC12 log'

# AC13: pages are read until one has fewer than 100 items.
$page1 = @(1..100 | ForEach-Object { , @("src/file$_.cs", 'modified') })
$run = Invoke-Receipt @{
    $FilesUri = New-Files $page1
    "GET $Api/repos/$Repository/pulls/7/files?per_page=100&page=2" = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText
    $CommentsUri = '[]'
    $CreateUri = ConvertTo-CompactJson (New-Comment 102 'github-actions[bot]' $ReceiptText)
}
Assert-Equal 0 $run.ExitCode 'AC13 exit code'
Assert-Equal @($FilesUri, "GET $Api/repos/$Repository/pulls/7/files?per_page=100&page=2", $ContentUri, $CommentsUri, $CreateUri) $run.Requests 'AC13 requests'

# AC14: a receipts-directory input with surrounding slashes still matches.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText
    $CommentsUri = '[]'
    $CreateUri = ConvertTo-CompactJson (New-Comment 103 'github-actions[bot]' $ReceiptText)
} @{ RECEIPTS_DIRECTORY = "/$Directory/" }
Assert-Equal 0 $run.ExitCode 'AC14 exit code'
Assert-Equal "result=created`ncomment-url=https://github.test/octo/widgets/pull/7#issuecomment-103`n" $run.Outputs 'AC14 outputs'

# AC15: branch names are compared case-sensitively.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText
} @{ HEAD_REF = 'Feature/Ledger' }
Assert-Equal 1 $run.ExitCode 'AC15 exit code'
Assert-Equal @('::error::No receipt for Feature/Ledger changed in this pull request; found receipts for: feature/ledger.') $run.Lines 'AC15 log'

# AC16: a branch that differs only by a zero-width space doesn't match.
$zeroWidthBranch = "feature/ledger$([char] 0x200B)"
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content $ReceiptText.Replace('"branch": "feature/ledger"', "`"branch`": `"$zeroWidthBranch`"")
}
Assert-Equal 1 $run.ExitCode 'AC16 exit code'
Assert-Equal @("::error::No receipt for feature/ledger changed in this pull request; found receipts for: $zeroWidthBranch.") $run.Lines 'AC16 log'
Assert-Equal @($FilesUri, $ContentUri) $run.Requests 'AC16 requests'

# AC17: a receipt that starts with a byte order mark fails the marker check.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'added'))
    $ContentUri = New-Content ("$([char] 0xFEFF)" + $ReceiptText)
}
Assert-Equal 1 $run.ExitCode 'AC17 exit code'
Assert-Equal @("::error::$ReceiptPath doesn't start with <!-- copilot-ledger-receipt -->, so it isn't a CopilotLedger receipt.") $run.Lines 'AC17 log'
Assert-Equal @($FilesUri, $ContentUri) $run.Requests 'AC17 requests'

# AC18: comment-author matches the comment's login case-insensitively, as GitHub logins do.
$run = Invoke-Receipt @{
    $FilesUri = New-Files @(, @($ReceiptPath, 'modified'))
    $ContentUri = New-Content $ReceiptText
    $CommentsUri = ConvertTo-CompactJson @(, (New-Comment 58 'github-actions[bot]' "<!-- copilot-ledger-receipt -->`nold"))
    "PATCH $Api/repos/$Repository/issues/comments/58" = ConvertTo-CompactJson (New-Comment 58 'github-actions[bot]' $ReceiptText)
} @{ COMMENT_AUTHOR = 'GitHub-Actions[bot]' }
Assert-Equal 0 $run.ExitCode 'AC18 exit code'
Assert-Equal "result=updated`ncomment-url=https://github.test/octo/widgets/pull/7#issuecomment-58`n" $run.Outputs 'AC18 outputs'
Assert-Equal @($FilesUri, $ContentUri, $CommentsUri, "PATCH $Api/repos/$Repository/issues/comments/58") $run.Requests 'AC18 requests'

if ($Failures.Count -gt 0) {
    $Failures | ForEach-Object { Write-Host "FAIL: $_" }
    Write-Host "$($Failures.Count) assertion(s) failed."
    exit 1
}

Write-Host 'All receipt action tests passed.'
exit 0
