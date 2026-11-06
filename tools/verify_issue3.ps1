param([switch]$RetryIncomplete)

$ErrorActionPreference = 'Continue'
$workspace = Split-Path $PSScriptRoot -Parent
Push-Location $workspace
try {
    $run = Join-Path 'build\verification' ('issue-3-' + (Get-Date -Format 'yyyyMMdd-HHmmss'))
    New-Item -ItemType Directory -Path $run -Force | Out-Null
    & flutter analyze --no-pub 2>&1 | Tee-Object -FilePath (Join-Path $run 'analyze.log')
    if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
    $tests = @(
        'test/book_catalog_verifier_test.dart',
        'test/mixed_catalog_probe_test.dart',
        'test/catalog_pagination_model_test.dart',
        'test/book_access_classification_test.dart',
        'test/book_access_probe_regression_test.dart',
        'test/brave_filter_refresh_test.dart',
        'test/book_probe_route_test.dart',
        'test/section_brave_filter_test.dart',
        'test/background_work_test.dart',
        'test/investigate_brave_test.dart',
        'test/browsing_defaults_test.dart',
        'test/cover_image_test.dart',
        'test/filtered_pagination_test.dart',
        'test/search_page_test.dart',
        'test/cloud_history_swipe_delete_test.dart',
        'test/user_profile_model_test.dart',
        'test/user_profile_actions_test.dart',
        'test/reader_access_test.dart',
        'test/chapter_page_model_test.dart',
        'test/reader_bootstrap_test.dart',
        'test/reader_cache_test.dart',
        'test/book_grid_density_test.dart',
        'test/my_profile_experience_test.dart',
        'test/home_book_actions_test.dart'
    )
    $results = @()
    foreach ($testPath in $tests) {
        Write-Output "==== $testPath ===="
        $output = @(& flutter test --no-pub --concurrency=1 $testPath --reporter expanded --timeout 45s 2>&1)
        $code = $LASTEXITCODE
        $initialCode = $code
        $attempts = 1
        $name = Split-Path $testPath -Leaf
        $output | Out-File -FilePath (Join-Path $run ($name + '.log')) -Encoding utf8
        $output | Select-Object -Last $(if ($code -eq 0) { 2 } else { 18 })
        $text = $output -join "`n"
        # Never retry a real assertion, compile error, exception or timeout.
        # The optional fallback is for an incomplete Flutter test process only.
        if ($RetryIncomplete -and $code -ne 0 -and $text -match 'did not complete' -and
            $text -notmatch 'Expected:|TestFailure|EXCEPTION|AssertionError|Compilation failed|Failed to load|TimeoutException|timed out after') {
            Write-Output 'INCOMPLETE PROCESS: one explicit rerun; original log is retained.'
            $attempts = 2
            $output = @(& flutter test --no-pub --concurrency=1 $testPath --reporter expanded --timeout 45s 2>&1)
            $code = $LASTEXITCODE
            $output | Out-File -FilePath (Join-Path $run ($name + '.rerun.log')) -Encoding utf8
            $output | Select-Object -Last $(if ($code -eq 0) { 2 } else { 18 })
        }
        $count = 0
        foreach ($line in $output) {
            if ("$line" -match '\+(\d+): All tests passed!') { $count = [int]$Matches[1] }
        }
        $results += [pscustomobject]@{ test = $testPath; initialExitCode = $initialCode; exitCode = $code; attempts = $attempts; testCount = $count }
    }
    $results | ConvertTo-Json | Out-File -FilePath (Join-Path $run 'summary.json') -Encoding utf8
    Write-Output ('VERIFICATION_DIR=' + $run)
    $failed = @($results | Where-Object exitCode -ne 0)
    if ($failed.Count) { $failed | Format-Table; exit 1 }
    $total = ($results | Measure-Object -Property testCount -Sum).Sum
    $reruns = @($results | Where-Object attempts -gt 1)
    Write-Output ('ALL FINAL ATTEMPTS PASSED: ' + $tests.Count + ' files, ' + $total + ' tests')
    if ($reruns.Count) { Write-Output ('INCOMPLETE-PROCESS RERUNS=' + $reruns.Count); $reruns | Format-Table }
    & git diff --check
    exit $LASTEXITCODE
} finally {
    Pop-Location
}
