#Requires -Version 7.6
#Requires -RunAsAdministrator

<#
.SYNOPSIS
Adjust natural scrolling for USB and Bluetooth scrolling devices (mice and trackpads) - interactively, or from the command line.

.DESCRIPTION
Natural scrolling: pulling the mouse wheel DOWN moves the page DOWN (the text above comes into view), like a trackpad / macOS. Unnatural a.k.a. Microsoft default scrolling: pulling the wheel DOWN moves the page UP (the text below comes into view).

Run WITHOUT arguments for the interactive TUI: pick a device from the arrow-key device menu (devices and states re-enumerated every time it is shown), pick the vertical or horizontal axis, then pick Enable / Disable / Remove. The cursor always starts on the option matching the current state, marked "[already the case]", so browsing changes nothing. Esc backs out one level, Ctrl+C quits gracefully from anywhere. The reconnect reminder is only shown when a change was actually applied, so a quit-only run is a pure inspection.

Run WITH arguments for scripting:

  adjust-natural-scroll.ps1 list
      Print every compatible scrolling device with its instance ID and current vertical/horizontal state (non-interactive). The instance IDs are what "set" needs.

  adjust-natural-scroll.ps1 set <device-id> <vertical|horizontal> <enable|disable|delete>
      Apply one change to one device, non-interactively. <device-id> is the device instance ID (exact, or a unique substring such as a VID/PID fragment); "delete" removes the registry value entirely.

The direction is controlled by two per-device registry values under HKLM:\SYSTEM\CurrentControlSet\Enum\<instance>\Device Parameters: FlipFlopWheel (vertical) and FlipFlopHScroll (horizontal); 1 = natural, 0 = unnatural, absent = system default (unnatural).

Supported devices: any scrolling device from Get-PnpDevice -Class Mouse whose instance ID starts with "HID\". The Mouse PnP class covers mice and trackpads; "HID\*" matches USB ("HID\VID_...") and Bluetooth ("HID\{00001812-...}...") devices. Legacy PS/2 devices ("ACPI\...") are skipped because they do not carry these values.

Output is color-coded via $PSStyle (ANSI): headers in cyan, axis states color-coded (green = natural ON, yellow = natural OFF, dim = absent, magenta = unknown), successes in green, errors in red.

.PARAMETER Command
"list" or "set". Omit for the interactive TUI.

.PARAMETER DeviceId
(set mode) The target device's instance ID, e.g. "HID\VID_05AC&PID_0278&...". An exact match is tried first, then a unique substring match; zero or multiple matches produce an error listing the candidates.

.PARAMETER Axis
(set mode) "Vertical" (FlipFlopWheel) or "Horizontal" (FlipFlopHScroll).

.PARAMETER Action
(set mode) "Enable" (set the value to 1), "Disable" (set it to 0), or "Delete" (remove the registry value).

.EXAMPLE
.\adjust-natural-scroll.ps1
Interactive TUI: navigate devices and axes with the arrow keys.

.EXAMPLE
.\adjust-natural-scroll.ps1 list
List all compatible scrolling devices with their instance IDs and current state.

.EXAMPLE
.\adjust-natural-scroll.ps1 set 05ac vertical enable
Enable natural vertical scrolling on the (unique) device whose instance ID contains "05ac".

.NOTES
Requires PowerShell 7.6+ (pwsh) and administrator rights; both are enforced declaratively by the #Requires directives at the top of this script (the registry values live under HKLM).

Changes only take effect after the device is disconnected and reconnected to the same port, or after Windows is restarted.

Not needed on Windows 11 24H2, which added a built-in scrolling-direction option in Settings.
#>

param(
	[Parameter(Position = 0)]
	[ValidateSet('list', 'set')]
	[string]$Command,

	[Parameter(Position = 1)]
	[string]$DeviceId,

	[Parameter(Position = 2)]
	[ValidateSet('Vertical', 'Horizontal')]
	[string]$Axis,

	[Parameter(Position = 3)]
	[ValidateSet('Enable', 'Disable', 'Delete')]
	[string]$Action
)


# ---------------------------------------------------------------------------
# Semantic ANSI styles via $PSStyle (guaranteed by "#Requires -Version 7.6"). Each value is an escape-sequence prefix; $S.Reset terminates styling. Embed directly in interpolated strings, e.g. "$($S.On)natural ON$($S.Reset)".
# ---------------------------------------------------------------------------
$S = @{
	Header    = $PSStyle.Bold + $PSStyle.Foreground.Cyan
	Subtle    = $PSStyle.Dim
	On        = $PSStyle.Foreground.Green
	Off       = $PSStyle.Foreground.Yellow
	Absent    = $PSStyle.Dim
	Unknown   = $PSStyle.Foreground.Magenta
	Success   = $PSStyle.Foreground.Green
	Failure   = $PSStyle.Bold + $PSStyle.Foreground.Red
	Warn      = $PSStyle.Foreground.Yellow
	Prompt    = $PSStyle.Foreground.Cyan
	Reset     = $PSStyle.Reset
}


# ---------------------------------------------------------------------------
# The arrow-key menu lives in menu.ps1 (dot-sourced; must sit next to this script). #Requires is evaluated for dot-sourced files too, but a failure only fails the source statement rather than the calling script, so verify the function actually arrived.
# ---------------------------------------------------------------------------
$menuPath = Join-Path $PSScriptRoot 'menu.ps1'
if (-not (Test-Path $menuPath)) {
	Write-Host "$($S.Failure)menu.ps1 not found (expected next to this script at $menuPath).$($S.Reset)"
	exit 1
}
. $menuPath
if (-not (Get-Command Read-MenuChoice -ErrorAction SilentlyContinue)) {
	Write-Host "$($S.Failure)Failed to load Read-MenuChoice from menu.ps1.$($S.Reset)"
	exit 1
}


# ---------------------------------------------------------------------------
# Read one FlipFlop* registry value. Returns the integer value when present, or $null when the value (or its key) is absent. Robust: Get-ItemProperty is called WITHOUT -Name (which would throw on a missing value) and membership is tested explicitly, so an absent value yields $null instead of an error.
# ---------------------------------------------------------------------------
function Get-ScrollAxisValue {
	param(
		[string]$RegPath,
		[string]$ParameterName
	)
	$props = Get-ItemProperty -Path $RegPath -ErrorAction SilentlyContinue
	if ($props -and ($props.PSObject.Properties.Name -contains $ParameterName)) {
		return $props.$ParameterName
	}
	return $null
}


# ---------------------------------------------------------------------------
# Compact one-line state label ("absent" / "natural ON" / "natural OFF" / "unknown(N)") for a raw FlipFlop* value ($null means the registry entry is absent). The type guard comes first so a non-integer (or absent) value is reported as "absent" rather than matching 0/1 through PowerShell's loose -eq coercion.
# ---------------------------------------------------------------------------
function Get-ScrollAxisStateLabel {
	param(
		[object]$Value
	)
	switch ($Value) {
		{ $_ -isnot [int] } { return "absent" }
		1 { return "natural ON" }
		0 { return "natural OFF" }
		default { return "unknown($Value)" }
	}
}


# ---------------------------------------------------------------------------
# The ANSI style (from $S) matching a raw FlipFlop* value: natural ON -> green, natural OFF -> yellow, absent -> dim, anything else -> magenta.
# ---------------------------------------------------------------------------
function Get-ScrollAxisStateStyle {
	param(
		[object]$Value
	)
	switch ($Value) {
		{ $_ -isnot [int] } { return $S.Absent }
		1 { return $S.On }
		0 { return $S.Off }
		default { return $S.Unknown }
	}
}


# ---------------------------------------------------------------------------
# A styled "<label>" for a raw FlipFlop* value (style + label + reset in one), for embedding in menu rows and reports.
# ---------------------------------------------------------------------------
function Get-ScrollAxisStyledLabel {
	param(
		[object]$Value
	)
	"$(Get-ScrollAxisStateStyle -Value $Value)$(Get-ScrollAxisStateLabel -Value $Value)$($S.Reset)"
}


# ---------------------------------------------------------------------------
# Resolve an axis label ("Vertical"/"Horizontal") to its registry value name.
# ---------------------------------------------------------------------------
function Get-ScrollAxisParameterName {
	param(
		[ValidateSet('Vertical', 'Horizontal')]
		[string]$AxisLabel
	)
	$AxisLabel -eq 'Vertical' ? 'FlipFlopWheel' : 'FlipFlopHScroll'
}


# ---------------------------------------------------------------------------
# Apply one action ("Enable" -> 1, "Disable" -> 0, "Delete" -> remove the value) to one FlipFlop* value of one device. Shared by the interactive action menu and "set" mode. Returns a result object with State = "Changed" / "AlreadyInState" / "Failed" plus the before/after raw values ($null = absent) so callers can render "old -> new" without re-reading. A write that fails (e.g. the device key vanished because the device was unplugged mid-session) becomes a caught "Failed" result, never a false success.
# ---------------------------------------------------------------------------
function Set-ScrollAxisValue {
	[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changing state is the explicit purpose of this function (one registry value, applied via the menu or the set command); -WhatIf was considered and declined.')]
	[CmdletBinding()]
	param(
		[string]$RegPath,
		[string]$ParameterName,
		[ValidateSet('Enable', 'Disable', 'Delete')]
		[string]$Action
	)
	$before = Get-ScrollAxisValue -RegPath $RegPath -ParameterName $ParameterName

	# Already satisfied? Enable -> 1, Disable -> 0, Delete -> absent.
	$satisfied = switch ($Action) {
		'Enable'  { $before -is [int] -and $before -eq 1 }
		'Disable' { $before -is [int] -and $before -eq 0 }
		'Delete'  { $before -isnot [int] }
	}
	if ($satisfied) {
		return [pscustomobject]@{ Action = $Action; State = 'AlreadyInState'; Before = $before; After = $before; Error = $null }
	}

	try {
		switch ($Action) {
			'Enable'  { Set-ItemProperty -Path $RegPath -Name $ParameterName -Value 1 -ErrorAction Stop }
			'Disable' { Set-ItemProperty -Path $RegPath -Name $ParameterName -Value 0 -ErrorAction Stop }
			'Delete'  { Remove-ItemProperty -Path $RegPath -Name $ParameterName -ErrorAction Stop }
		}
	} catch {
		return [pscustomobject]@{ Action = $Action; State = 'Failed'; Before = $before; After = $before; Error = "$_" }
	}
	$after = Get-ScrollAxisValue -RegPath $RegPath -ParameterName $ParameterName
	[pscustomobject]@{ Action = $Action; State = 'Changed'; Before = $before; After = $after; Error = $null }
}


# ---------------------------------------------------------------------------
# Render a one-line outcome for a Set-ScrollAxisValue result ("Vertical scroll: natural OFF -> natural ON" / dim "no change" / red failure). Shared by the interactive action menu and "set" mode. Returns $true when a change was applied.
# ---------------------------------------------------------------------------
function Write-ScrollAxisOutcome {
	param(
		[string]$AxisLabel,
		[Parameter(Mandatory)]
		$Result
	)
	switch ($Result.State) {
		'Changed' {
			Write-Host "$($S.Success)$AxisLabel scroll: $(Get-ScrollAxisStateLabel -Value $Result.Before) -> $(Get-ScrollAxisStateLabel -Value $Result.After)$($S.Reset)"
			return $true
		}
		'AlreadyInState' {
			Write-Host "$($S.Subtle)$AxisLabel scroll: no change needed - already $(Get-ScrollAxisStateLabel -Value $Result.Before)$($S.Reset)"
			return $false
		}
		default {
			Write-Host "$($S.Failure)$AxisLabel scroll: failed to $($Result.Action.ToLower()) ($($Result.Error))$($S.Reset)"
			return $false
		}
	}
}


# ---------------------------------------------------------------------------
# Resolve a <device-id> argument to one device: exact instance-ID match first (case-insensitive), then a unique substring match. On zero or multiple matches, prints a styled error listing the compatible devices and their instance IDs (doubling as non-interactive ID discovery) and returns $null.
# ---------------------------------------------------------------------------
function Resolve-ScrollingDevice {
	param(
		[Parameter(Mandatory)]
		[array]$Devices,
		[Parameter(Mandatory)]
		[string]$DeviceId
	)
	$exact = @($Devices | Where-Object { $_.InstanceId -eq $DeviceId })
	if ($exact.Count -eq 1) { return $exact[0] }

	$partial = @($Devices | Where-Object { $_.InstanceId -like "*$DeviceId*" })
	if ($partial.Count -eq 1) { return $partial[0] }

	if ($partial.Count -eq 0) {
		Write-Host "$($S.Failure)No compatible scrolling device matches '$DeviceId'.$($S.Reset)"
	} else {
		Write-Host "$($S.Failure)'$DeviceId' is ambiguous - it matches $($partial.Count) devices:$($S.Reset)"
		$partial | ForEach-Object { Write-Host "    $($S.Subtle)$($_.InstanceId)$($S.Reset)" }
		return $null
	}
	Write-Host "$($S.Subtle)Compatible devices:$($S.Reset)"
	$Devices | ForEach-Object { Write-Host "    $($S.Subtle)$($_.InstanceId)$($S.Reset)" }
	return $null
}


# ---------------------------------------------------------------------------
# Build a human-readable name for a scrolling device from its HardwareID:
#   <Vendor> <model> (<bus>)            when the VID/PID is curated
#   <Vendor> scrolling device (<bus>)   otherwise (still better than "HID-compliant mouse")
#   <FriendlyName> (<bus>)              when no USB VID is available (e.g. plain Bluetooth)
# The InstanceId is always shown separately so devices stay unambiguous.
# ---------------------------------------------------------------------------
function Get-DeviceDescriptor {
	param(
		[string]$InstanceId,
		[string]$FriendlyName
	)

	# USB Vendor ID -> vendor name. Extend freely; unknown VIDs fall back below.
	$vendorByVid = @{
		'05AC' = 'Apple'
		'046D' = 'Logitech'
		'045E' = 'Microsoft'
		'1532' = 'Razer'
		'0B05' = 'ASUS'
		'413C' = 'Dell'
		'17EF' = 'Lenovo'
	}

	# Known VID:PID -> model label. Only add entries you are sure about; everything else falls back to "<Vendor> scrolling device (<bus>)".
	$modelByVidPid = @{
		'05AC:0278' = 'built-in trackpad'
	}

	$hwids = @((Get-ItemProperty -Path "HKLM:\SYSTEM\CurrentControlSet\Enum\$InstanceId" -ErrorAction SilentlyContinue).HardwareID)
	$hwid = $hwids | Where-Object { $_ } | Select-Object -First 1

	$bus = 'HID'
	$vendorId = $null
	$prodId = $null
	if ($hwid) {
		if ($hwid -like 'HID\{*') { $bus = 'Bluetooth' }
		elseif ($hwid -like 'ACPI\*') { $bus = 'PS/2' }
		elseif ($hwid -like 'HID\*') { $bus = 'USB' }
		if ($hwid -match 'VID_(?<vid>[0-9A-Fa-f]{4})') { $vendorId = $matches.vid.ToUpper() }
		if ($hwid -match 'PID_(?<pid>[0-9A-Fa-f]{4})') { $prodId = $matches.pid.ToUpper() }
	}

	$vendor = $null
	if ($vendorId) {
		$vendor = $vendorByVid.ContainsKey($vendorId) ? $vendorByVid[$vendorId] : "Vendor $vendorId"
	}

	$model = $null
	if ($vendorId -and $prodId) {
		$key = "${vendorId}:$prodId"
		if ($modelByVidPid.ContainsKey($key)) { $model = $modelByVidPid[$key] }
	}

	if ($model) { return "$vendor $model ($bus)" }
	if ($vendor) { return "$vendor scrolling device ($bus)" }
	$name = $FriendlyName ?? 'Scrolling device'
	return "$name ($bus)"
}


# ---------------------------------------------------------------------------
# Enumerate compatible scrolling devices: HID-backed entries from Get-PnpDevice -Class Mouse (the Mouse class covers mice and trackpads; "HID\*" matches USB and Bluetooth, legacy PS/2 "ACPI\..." entries are reported and skipped), each with a human-readable descriptor and its "Device Parameters" registry path. Enumeration failure (e.g. the Plug and Play service is not running), or finding nothing compatible, is fatal and exits 1. Called fresh on every device-menu render as well as by "list"/"set".
# ---------------------------------------------------------------------------
function Get-ScrollingDevice {
	try {
		$devices = Get-PnpDevice -Class Mouse -ErrorAction Stop
	} catch {
		Write-Host "$($S.Failure)Failed to enumerate scrolling devices: $_$($S.Reset)"
		exit 1
	}
	$collected = @()
	if ($devices) {
		$collected = @(foreach ($device in $devices) {
			$name = $device.FriendlyName ?? "(unnamed device)"
			$path = $device.InstanceID
			if (!($path -like "HID\*")) {
				Write-Host "$($S.Subtle)Not a compatible scrolling device, skipping: $name ($path)$($S.Reset)"
				continue
			}
			[pscustomobject]@{
				InstanceId = $path
				RegPath    = "HKLM:\SYSTEM\CurrentControlSet\Enum\$path\Device Parameters"
				Descriptor = Get-DeviceDescriptor -InstanceId $path -FriendlyName $name
			}
		})
	}
	if ($collected.Count -eq 0) {
		Write-Host "$($S.Failure)No compatible (HID) scrolling devices found; nothing to do.$($S.Reset)"
		exit 1
	}
	return $collected
}


# ---------------------------------------------------------------------------
# Render the device list for "list" mode. On a console: styled host output for humans. When stdout is redirected (piped or to a file): structured objects instead, so the output is scriptable (e.g. "... list | ConvertTo-Json").
# ---------------------------------------------------------------------------
function Out-DeviceList {
	param(
		[Parameter(Mandatory)]
		[array]$Devices
	)
	$redirected = [Console]::IsOutputRedirected
	$i = 0
	foreach ($d in $Devices) {
		$i++
		$v = Get-ScrollAxisValue -RegPath $d.RegPath -ParameterName 'FlipFlopWheel'
		$h = Get-ScrollAxisValue -RegPath $d.RegPath -ParameterName 'FlipFlopHScroll'
		if ($redirected) {
			[pscustomobject]@{
				Number     = $i
				InstanceId = $d.InstanceId
				Descriptor = $d.Descriptor
				Vertical   = Get-ScrollAxisStateLabel -Value $v
				Horizontal = Get-ScrollAxisStateLabel -Value $h
			}
		} else {
			if ($i -eq 1) { Write-Host "$($S.Header)Detected scrolling devices:$($S.Reset)" }
			Write-Host "  $($S.Header)[$i]$($S.Reset) $($d.Descriptor)"
			Write-Host "      $($S.Subtle)$($d.InstanceId)$($S.Reset)    vertical: $(Get-ScrollAxisStyledLabel -Value $v), horizontal: $(Get-ScrollAxisStyledLabel -Value $h)"
		}
	}
}


# ---------------------------------------------------------------------------
# The three-level interactive session: device menu (devices AND states re-enumerated on every render, so plug/unplug and changes are visible immediately) -> axis menu -> action menu -> back to the refreshed device menu. Esc backs out one level (quits at the top); Ctrl+C aborts the whole session. Returns an object: Changes = $true when at least one change was applied (reconnect reminder), Aborted = $true when quit via Ctrl+C (exit code 130).
# ---------------------------------------------------------------------------
function Invoke-InteractiveSession {
	$changesMade = $false
	$aborted = $false
	$deviceIndex = 0

	while ($true) {
		# --- Level 1: device menu, re-enumerated on every render (Get-ScrollingDevice exits 1 when nothing compatible is found, including mid-session). ---
		$Devices = @(Get-ScrollingDevice)
		Write-Host ""
		Write-Host "$($S.Header)Detected scrolling devices:$($S.Reset) $($S.Subtle)(up/down + Enter, digits jump, Esc = back, Ctrl+C = quit)$($S.Reset)"
		$deviceRows = @(foreach ($d in $Devices) {
			$v = Get-ScrollAxisValue -RegPath $d.RegPath -ParameterName 'FlipFlopWheel'
			$h = Get-ScrollAxisValue -RegPath $d.RegPath -ParameterName 'FlipFlopHScroll'
			"$($d.Descriptor)  $($S.Subtle)vertical:$($S.Reset) $(Get-ScrollAxisStyledLabel -Value $v)$($S.Subtle), horizontal:$($S.Reset) $(Get-ScrollAxisStyledLabel -Value $h)"
		})
		$deviceRows += "$($S.Subtle)Quit$($S.Reset)"
		$deviceIndex = Read-MenuChoice -Rows $deviceRows -Initial ([Math]::Min($deviceIndex, $deviceRows.Count - 2))
		if ($deviceIndex -eq -2) { $aborted = $true; break }
		if ($deviceIndex -eq -1 -or $deviceIndex -eq $deviceRows.Count - 1) { break }

		$d = $Devices[$deviceIndex]
		while ($true) {
			# --- Level 2: axis menu for the chosen device (states re-read here too). ---
			Write-Host ""
			Write-Host "$($S.Header)$($d.Descriptor)$($S.Reset)"
			Write-Host "    $($S.Subtle)$($d.InstanceId)$($S.Reset)"
			$v = Get-ScrollAxisValue -RegPath $d.RegPath -ParameterName 'FlipFlopWheel'
			$h = Get-ScrollAxisValue -RegPath $d.RegPath -ParameterName 'FlipFlopHScroll'
			$axisRows = @(
				"Vertical scroll    $($S.Subtle)(current:$($S.Reset) $(Get-ScrollAxisStyledLabel -Value $v)$($S.Subtle))$($S.Reset)",
				"Horizontal scroll  $($S.Subtle)(current:$($S.Reset) $(Get-ScrollAxisStyledLabel -Value $h)$($S.Subtle))$($S.Reset)",
				"$($S.Subtle)Back to devices$($S.Reset)"
			)
			$axisIndex = Read-MenuChoice -Rows $axisRows -Initial 0
			if ($axisIndex -eq -2) { $aborted = $true; break }
			if ($axisIndex -lt 0 -or $axisIndex -eq 2) { break }

			# --- Level 3: action menu for the chosen axis. ---
			$axisLabel = $axisIndex -eq 0 ? 'Vertical' : 'Horizontal'
			$paramName = Get-ScrollAxisParameterName -AxisLabel $axisLabel
			$current = Get-ScrollAxisValue -RegPath $d.RegPath -ParameterName $paramName
			$currentIndex = ($current -is [int] -and $current -eq 1) ? 0 : (($current -is [int] -and $current -eq 0) ? 1 : 2)
			$tag = "  $($S.Subtle)[already the case]$($S.Reset)"
			$actionRows = @(
				"$($S.Prompt)(1)$($S.Reset) Enable natural scroll$($currentIndex -eq 0 ? $tag : '')",
				"$($S.Prompt)(2)$($S.Reset) Disable natural scroll$($currentIndex -eq 1 ? $tag : '')",
				"$($S.Prompt)(3)$($S.Reset) Remove the registry entry$($currentIndex -eq 2 ? $tag : '')",
				"$($S.Prompt)(4)$($S.Reset) $($S.Subtle)Back$($S.Reset)"
			)
			Write-Host ""
			Write-Host "$($S.Header)[$axisLabel scroll]$($S.Reset) $($S.Subtle)current:$($S.Reset) $(Get-ScrollAxisStyledLabel -Value $current)"
			$actionIndex = Read-MenuChoice -Rows $actionRows -Initial $currentIndex
			if ($actionIndex -eq -2) { $aborted = $true; break }
			if ($actionIndex -lt 0 -or $actionIndex -eq 3) { continue }

			$action = @('Enable', 'Disable', 'Delete')[$actionIndex]
			$result = Set-ScrollAxisValue -RegPath $d.RegPath -ParameterName $paramName -Action $action
			if (Write-ScrollAxisOutcome -AxisLabel $axisLabel -Result $result) { $changesMade = $true }
			break  # action completed -> back to the (re-enumerated) device menu
		}
		if ($aborted) { break }
	}

	[pscustomobject]@{ Changes = $changesMade; Aborted = $aborted }
}


# ---------------------------------------------------------------------------
# Print a styled usage error and exit 1.
# ---------------------------------------------------------------------------
function Show-UsageError {
	param(
		[Parameter(Mandatory)]
		[string]$Message
	)
	Write-Host "$($S.Failure)$Message$($S.Reset)"
	Write-Host "$($S.Subtle)Usage: adjust-natural-scroll.ps1            (interactive menu)"
	Write-Host "       adjust-natural-scroll.ps1 list       (list devices, instance IDs, current state)"
	Write-Host "       adjust-natural-scroll.ps1 set <device-id> <vertical|horizontal> <enable|disable|delete>$($S.Reset)"
	exit 1
}


# ---------------------------------------------------------------------------
# Dispatch on the command.
# ---------------------------------------------------------------------------
switch ($Command) {
	'list' {
		if ($DeviceId -or $Axis -or $Action) { Show-UsageError "'list' does not take further arguments." }
		$scrollingDevices = @(Get-ScrollingDevice)
		Out-DeviceList -Devices $scrollingDevices
		exit 0
	}
	'set' {
		if (!$DeviceId -or !$Axis -or !$Action) { Show-UsageError "'set' requires all three arguments: set <device-id> <vertical|horizontal> <enable|disable|delete>" }
		$scrollingDevices = @(Get-ScrollingDevice)
		$target = Resolve-ScrollingDevice -Devices $scrollingDevices -DeviceId $DeviceId
		if (!$target) { exit 1 }
		$paramName = Get-ScrollAxisParameterName -AxisLabel $Axis
		Write-Host "$($S.Header)$($target.Descriptor)$($S.Reset)"
		Write-Host "    $($S.Subtle)$($target.InstanceId)$($S.Reset)"
		$result = Set-ScrollAxisValue -RegPath $target.RegPath -ParameterName $paramName -Action $Action
		$applied = Write-ScrollAxisOutcome -AxisLabel $Axis -Result $result
		if ($result.State -eq 'Failed') { exit 1 }
		if ($applied) {
			Write-Host "$($S.Warn)Reconnect the device (or restart Windows) for the change to take effect.$($S.Reset)"
		}
		exit 0
	}
	default {
		if ($DeviceId -or $Axis -or $Action) { Show-UsageError "Unexpected arguments without a command ('list' or 'set')." }
		if ([Console]::IsInputRedirected) {
			Write-Host "$($S.Failure)No interactive console detected; use 'list' or 'set <device-id> <vertical|horizontal> <enable|disable|delete>' instead.$($S.Reset)"
			exit 1
		}
		$session = Invoke-InteractiveSession
		if ($session.Changes) {
			Write-Host ""
			Write-Host "$($S.Warn)Done. Reconnect each scrolling device (or restart Windows) for changes to take effect.$($S.Reset)"
		}
		if ($session.Aborted) { exit 130 }
	}
}