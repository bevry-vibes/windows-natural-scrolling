#Requires -Version 7.6

<#
.SYNOPSIS
Reusable arrow-key console menu for PowerShell 7.6+ (ANSI styling via $PSStyle).

.DESCRIPTION
Dot-source this file, then call Read-MenuChoice with an array of pre-styled single-line strings:

    . "$PSScriptRoot\menu.ps1"
    $index = Read-MenuChoice -Rows @('Alpha', 'Beta', 'Quit') -Initial 0

The user navigates with the Up/Down arrow keys (wrap-around), confirms with Enter, jumps to a row with the digit keys, backs out with Esc, and quits with Ctrl+C. Read-MenuChoice returns the 0-based index of the chosen row, -1 for Esc ("back"), or -2 for Ctrl+C ("abort").

Running this file directly (pwsh menu.ps1) shows a demo menu.

Limitations: rows must be single-line; the row count must fit within the console buffer height; an interactive console is required (the function throws if input is redirected).

License: Reciprocal Public License 1.5 <http://spdx.org/licenses/RPL-1.5.html>
https://github.com/bevry-vibes/windows-natural-scrolling
#>


# ---------------------------------------------------------------------------
# Show an interactive arrow-key menu and return the chosen row.
#
# .PARAMETER Rows
# Pre-styled single-line strings, one per option. Any ANSI styling (colors, tags such as "[already the case]") is embedded by the caller; the highlighted row is shown in reverse video with a "> " prefix.
#
# .PARAMETER Initial
# 0-based index of the initially highlighted row (clamped into range).
#
# .OUTPUTS
# System.Int32 - the 0-based index of the chosen row, -1 for Esc ("back one level"), or -2 for Ctrl+C ("abort").
#
# The menu redraws in place (relative ANSI cursor-up + erase-to-end-of-line), so it updates itself without scrolling. Ctrl+C is captured as an ordinary key (TreatControlCAsInput) rather than tearing down the pipeline mid-redraw, and both that setting and cursor visibility are restored in "finally" whatever happens.
# ---------------------------------------------------------------------------
function Read-MenuChoice {
	param(
		[Parameter(Mandatory)]
		[string[]]$Rows,
		[int]$Initial = 0
	)

	if ($Rows.Count -eq 0) { throw "Read-MenuChoice requires at least one row" }
	if ([Console]::IsInputRedirected) { throw "Read-MenuChoice requires an interactive console" }

	$selected = [Math]::Min([Math]::Max($Initial, 0), $Rows.Count - 1)
	$esc = [char]27
	$highlight = $PSStyle.Reverse
	$reset = $PSStyle.Reset
	$previousTreatControlC = [Console]::TreatControlCAsInput
	$previousCursorVisible = [Console]::CursorVisible
	[Console]::TreatControlCAsInput = $true
	[Console]::CursorVisible = $false

	try {
		$firstDraw = $true
		while ($true) {
			if (-not $firstDraw) { [Console]::Write("$esc[$($Rows.Count)A") }
			$firstDraw = $false
			for ($i = 0; $i -lt $Rows.Count; $i++) {
				$line = ($i -eq $selected) ? "> $highlight$($Rows[$i])$reset" : "  $($Rows[$i])"
				[Console]::Write("$line$esc[K`r`n")
			}

			$key = [Console]::ReadKey($true)
			if ($key.Key -eq [ConsoleKey]::Enter) { return $selected }
			if ($key.Key -eq [ConsoleKey]::Escape) { return -1 }
			if ($key.Key -eq [ConsoleKey]::C -and ($key.Modifiers -band [ConsoleModifiers]::Control)) { return -2 }
			if ($key.Key -eq [ConsoleKey]::UpArrow) {
				$selected = ($selected - 1 + $Rows.Count) % $Rows.Count
			} elseif ($key.Key -eq [ConsoleKey]::DownArrow) {
				$selected = ($selected + 1) % $Rows.Count
			} elseif ($key.KeyChar -ge '1' -and $key.KeyChar -le '9') {
				$digit = [int]::Parse($key.KeyChar.ToString())
				if ($digit -le $Rows.Count) { return ($digit - 1) }
			}
		}
	} finally {
		[Console]::TreatControlCAsInput = $previousTreatControlC
		[Console]::CursorVisible = $previousCursorVisible
	}
}


# --- Demo when run directly (skipped when dot-sourced). ---
if ($MyInvocation.InvocationName -ne '.') {
	$demoRows = @(
		"$($PSStyle.Foreground.Green)Alpha$($PSStyle.Reset)",
		"$($PSStyle.Foreground.Yellow)Beta$($PSStyle.Reset)",
		"$($PSStyle.Foreground.Magenta)Gamma$($PSStyle.Reset)",
		"$($PSStyle.Dim)Quit$($PSStyle.Reset)"
	)
	Write-Host "Demo menu (up/down + Enter, digits jump, Esc = back, Ctrl+C = quit):"
	$result = Read-MenuChoice -Rows $demoRows -Initial 0
	Write-Host "Read-MenuChoice returned: $result"
}