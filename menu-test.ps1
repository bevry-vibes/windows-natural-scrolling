# menu-test.ps1 - tests for menu.ps1.
# Read-MenuChoice drives Console.ReadKey, so the keystroke paths themselves cannot be automated;
# these tests cover what CAN be verified non-interactively: syntax, dot-sourcing (demo skipped),
# the guard clauses, and that a direct run reaches the demo.
# Run:  pwsh ./menu-test.ps1
$ErrorActionPreference = 'Stop'
$menuPath = Join-Path $PSScriptRoot 'menu.ps1'

$failures = 0
function Check([string]$Name, [bool]$Ok) {
	if ($Ok) { Write-Host "$($PSStyle.Foreground.Green)PASS$($PSStyle.Reset)  $Name" }
	else { Write-Host "$($PSStyle.Foreground.Red)FAIL$($PSStyle.Reset)  $Name"; $script:failures++ }
}

# --- Parses cleanly ---
$t = $null; $e = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($menuPath, [ref]$t, [ref]$e)
Check 'menu.ps1 parses without errors' ($e.Count -eq 0)

# --- Dot-sourcing defines Read-MenuChoice and skips the demo ---
# (If the demo ran here it would call Read-MenuChoice, which throws under redirected input.)
. $menuPath
Check 'dot-sourcing defines Read-MenuChoice (demo skipped)' ($null -ne (Get-Command Read-MenuChoice -ErrorAction SilentlyContinue))

# --- Guard: no rows (rejected at binding or by the function) ---
$msg = $null
try { Read-MenuChoice -Rows @() } catch { $msg = "$($_.Exception.Message)" }
Check 'empty rows -> throws' ($msg -match 'empty array|at least one row')

# --- Guard: requires an interactive console ---
if ([Console]::IsInputRedirected) {
	$msg = $null
	try { Read-MenuChoice -Rows @('Alpha', 'Beta') } catch { $msg = "$($_.Exception.Message)" }
	Check 'redirected input -> throws interactive-console error' ($msg -like '*interactive console*')

	# --- Direct run reaches the demo (blocked inside Read-MenuChoice only because input is redirected) ---
	$direct = & pwsh -NoProfile -File $menuPath 2>&1 | Out-String
	Check 'direct run reaches the demo menu' ("$direct" -like '*interactive console*')
} else {
	Write-Host 'SKIP  redirected-input guard and direct-run demo checks (interactive console - direct run would block on a key press)'
}

Write-Host ''
Write-Host "Failures: $failures"
exit ($failures -gt 0 ? 1 : 0)