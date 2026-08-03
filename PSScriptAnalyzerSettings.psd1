# PSScriptAnalyzer settings for this repository.
# PSAvoidUsingWriteHost is excluded repo-wide: these are interactive host-UI scripts -
# styled console output via Write-Host / [Console]::Write is the intended mechanism
# (paths that must be scriptable emit real objects instead - see Out-DeviceList).
# Lint with:  Invoke-ScriptAnalyzer -Path . -Settings .\PSScriptAnalyzerSettings.psd1
@{
	ExcludeRules = @('PSAvoidUsingWriteHost')
}