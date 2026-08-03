# adjust-natural-scroll-test.ps1 - function-level tests for adjust-natural-scroll.ps1.
# The real function definitions are AST-extracted from the script and exercised against a
# scratch registry key under HKCU (no admin needed, nothing under HKLM is touched).
# Run:  pwsh ./adjust-natural-scroll-test.ps1
$ErrorActionPreference = 'Stop'
$scriptPath = Join-Path $PSScriptRoot 'adjust-natural-scroll.ps1'

$failures = 0
function Check([string]$Name, [bool]$Ok) {
	if ($Ok) { Write-Host "$($S.Success)PASS$($S.Reset)  $Name" }
	else { Write-Host "$($S.Failure)FAIL$($S.Reset)  $Name"; $script:failures++ }
}

# --- $S stub required by the extracted functions (mirrors the script's style map) ---
$S = @{
	Header  = $PSStyle.Bold + $PSStyle.Foreground.Cyan
	Subtle  = $PSStyle.Dim
	On      = $PSStyle.Foreground.Green
	Off     = $PSStyle.Foreground.Yellow
	Absent  = $PSStyle.Dim
	Unknown = $PSStyle.Foreground.Magenta
	Success = $PSStyle.Foreground.Green
	Failure = $PSStyle.Bold + $PSStyle.Foreground.Red
	Warn    = $PSStyle.Foreground.Yellow
	Prompt  = $PSStyle.Foreground.Cyan
	Reset   = $PSStyle.Reset
}

# --- Parses cleanly ---
$t = $null; $e = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($scriptPath, [ref]$t, [ref]$e)
Check 'adjust-natural-scroll.ps1 parses without errors' ($e.Count -eq 0)

# --- Extract the real function definitions ---
$wanted = 'Get-ScrollAxisValue','Get-ScrollAxisStateLabel','Get-ScrollAxisStateStyle','Get-ScrollAxisStyledLabel','Get-ScrollAxisParameterName','Set-ScrollAxisValue','Write-ScrollAxisOutcome','Resolve-ScrollingDevice','Get-DeviceDescriptor','Get-ScrollingDevice','Out-DeviceList'
$funcs = $ast.FindAll({ param($n) $n -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
foreach ($f in $funcs) { if ($wanted -contains $f.Name) { . ([ScriptBlock]::Create($f.Extent.Text)) } }

# --- Registry scratch key (HKCU, no admin needed) ---
$scratch = 'HKCU:\Software\AdjustNaturalScrollTest'
Remove-Item $scratch -Recurse -ErrorAction SilentlyContinue
New-Item $scratch -Force | Out-Null

$r = Set-ScrollAxisValue -RegPath $scratch -ParameterName 'FlipFlopWheel' -Action 'Enable'
Check 'Enable on absent -> Changed' ($r.State -eq 'Changed' -and $null -eq $r.Before -and $r.After -eq 1)
$r = Set-ScrollAxisValue -RegPath $scratch -ParameterName 'FlipFlopWheel' -Action 'Enable'
Check 'Enable again -> AlreadyInState' ($r.State -eq 'AlreadyInState')
$r = Set-ScrollAxisValue -RegPath $scratch -ParameterName 'FlipFlopWheel' -Action 'Disable'
Check 'Disable -> Changed 1->0' ($r.State -eq 'Changed' -and $r.Before -eq 1 -and $r.After -eq 0)
$r = Set-ScrollAxisValue -RegPath $scratch -ParameterName 'FlipFlopWheel' -Action 'Delete'
Check 'Delete -> Changed 0->absent' ($r.State -eq 'Changed' -and $r.Before -eq 0 -and $null -eq $r.After)
$r = Set-ScrollAxisValue -RegPath $scratch -ParameterName 'FlipFlopWheel' -Action 'Delete'
Check 'Delete again -> AlreadyInState' ($r.State -eq 'AlreadyInState')
$r = Set-ScrollAxisValue -RegPath 'HKCU:\Software\AdjustNaturalScrollTest\Missing\Key' -ParameterName 'FlipFlopWheel' -Action 'Enable'
Check 'Enable on missing key -> Failed' ($r.State -eq 'Failed' -and $r.Error)

$changed = Set-ScrollAxisValue -RegPath $scratch -ParameterName 'FlipFlopHScroll' -Action 'Enable'
Check 'Write-ScrollAxisOutcome Changed -> true' ((Write-ScrollAxisOutcome -AxisLabel 'Horizontal' -Result $changed) -eq $true)
$again = Set-ScrollAxisValue -RegPath $scratch -ParameterName 'FlipFlopHScroll' -Action 'Enable'
Check 'Write-ScrollAxisOutcome AlreadyInState -> false' ((Write-ScrollAxisOutcome -AxisLabel 'Horizontal' -Result $again) -eq $false)

# --- Device resolution (fake devices; InstanceId matching is what matters) ---
$fake = @(
	[pscustomobject]@{ InstanceId = 'HID\VID_05AC&PID_0278&MI_00\7&AAAA&0&0000'; RegPath = $scratch; Descriptor = 'Apple built-in trackpad (USB)' },
	[pscustomobject]@{ InstanceId = 'HID\VID_046D&PID_C534&MI_01\7&BBBB&0&0001'; RegPath = $scratch; Descriptor = 'Logitech scrolling device (USB)' }
)
Check 'exact match' ((Resolve-ScrollingDevice -Devices $fake -DeviceId 'HID\VID_05AC&PID_0278&MI_00\7&AAAA&0&0000').Descriptor -like 'Apple*')
Check 'unique substring' ((Resolve-ScrollingDevice -Devices $fake -DeviceId '05ac').Descriptor -like 'Apple*')
Check 'unique substring case-insensitive' ((Resolve-ScrollingDevice -Devices $fake -DeviceId 'pid_c534').Descriptor -like 'Logitech*')
Check 'zero matches -> null' ($null -eq (Resolve-ScrollingDevice -Devices $fake -DeviceId 'deadbeef'))
Check 'ambiguous -> null' ($null -eq (Resolve-ScrollingDevice -Devices $fake -DeviceId 'HID\VID'))

# --- Axis resolver ---
Check 'Vertical -> FlipFlopWheel' ((Get-ScrollAxisParameterName -AxisLabel 'Vertical') -eq 'FlipFlopWheel')
Check 'Horizontal -> FlipFlopHScroll' ((Get-ScrollAxisParameterName -AxisLabel 'Horizontal') -eq 'FlipFlopHScroll')

# --- Out-DeviceList: structured objects when stdout is redirected (as in CI); styled output otherwise ---
if ([Console]::IsOutputRedirected) {
	Set-ItemProperty -Path $scratch -Name 'FlipFlopWheel' -Value 0
	Remove-ItemProperty -Path $scratch -Name 'FlipFlopHScroll' -ErrorAction SilentlyContinue
	$items = @(Out-DeviceList -Devices $fake)
	Check 'Out-DeviceList emits objects when redirected' ($items.Count -eq 2 -and $items[0].InstanceId -like 'HID*' -and $items[0].Vertical -eq 'natural OFF' -and $items[0].Horizontal -eq 'absent')
} else {
	Out-DeviceList -Devices $fake | Out-Null
	Write-Host "SKIP  Out-DeviceList object check (interactive console - styled branch printed above)"
}

# --- Live enumeration smoke test (works non-elevated; needs at least one compatible device, else the function exits 1 by design) ---
$live = @(Get-ScrollingDevice)
Check 'Get-ScrollingDevice runs without throwing' ($live.Count -ge 1)

Remove-Item $scratch -Recurse -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "Failures: $failures"
exit ($failures -gt 0 ? 1 : 0)