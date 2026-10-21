[CmdletBinding(SupportsShouldProcess = $true)]
param(
    [string]$InterfaceAlias = 'Wi-Fi',
    [ValidateRange(1024, 65534)]
    [int]$Port = 5000
)

$ErrorActionPreference = 'Stop'
$resultPath = Join-Path $PSScriptRoot 'logs\phone-firewall-result.json'
$changedBlocks = @()
$createdRule = $false
$ruleName = "HeatGuard-WiFi-API-$Port"

try {
    $pythonPath = Join-Path $PSScriptRoot '.venv\Scripts\python.exe'
    $pythonProgram = & $pythonPath -c 'import sys; print(sys._base_executable)'
    if ($LASTEXITCODE -ne 0) { throw 'Could not identify the HeatGuard Python executable.' }
    $pythonProgram = $pythonProgram.Trim()
    $address = Get-NetIPAddress -InterfaceAlias $InterfaceAlias -AddressFamily IPv4 |
        Where-Object { $_.AddressState -eq 'Preferred' -and $_.IPAddress -notlike '169.254.*' } |
        Select-Object -First 1 -ExpandProperty IPAddress
    if (-not $address) { throw "No active IPv4 address was found for $InterfaceAlias." }

    $blocks = @()
    $otherPorts = @("1-$($Port - 1)", "$($Port + 1)-65535")
    foreach ($rule in @(Get-NetFirewallRule -PolicyStore PersistentStore -Direction Inbound -Enabled True -Action Block)) {
        $application = $rule | Get-NetFirewallApplicationFilter
        if ($application.Program -ine $pythonProgram) { continue }
        $filter = $rule | Get-NetFirewallPortFilter
        if ($filter.Protocol -ne 'TCP') { continue }
        if ((@($filter.LocalPort) -join ',') -eq ($otherPorts -join ',')) { continue }
        if (@($filter.LocalPort).Count -ne 1 -or $filter.LocalPort -ne 'Any') {
            throw 'A custom Python TCP block needs review before changing phone access.'
        }
        $blocks += [pscustomobject]@{ Name = $rule.Name; LocalPort = @($filter.LocalPort) }
    }

    $plan = [ordered]@{
        Interface = $InterfaceAlias
        Address = $address
        Port = $Port
        Program = $pythonProgram
        RemoteAddress = 'LocalSubnet'
        ExistingTcpBlocks = @($blocks | Select-Object -ExpandProperty Name)
    }
    if ($WhatIfPreference) {
        $plan | ConvertTo-Json -Depth 4
        return
    }

    $principal = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    if (-not $principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Run this script from PowerShell as Administrator to change Windows Firewall.'
    }

    if ($PSCmdlet.ShouldProcess("$InterfaceAlias $address TCP/$Port", 'Allow HeatGuard from the local subnet')) {
        $existing = Get-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -ErrorAction SilentlyContinue
        if ($existing) {
            Set-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -Enabled True -Action Allow `
                -Direction Inbound -Profile Any -Program $pythonProgram -Protocol TCP -LocalPort $Port `
                -LocalAddress $address -RemoteAddress LocalSubnet -InterfaceAlias $InterfaceAlias |
                Out-Null
        }
        else {
            New-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -DisplayName "HeatGuard Wi-Fi API ($Port)" `
                -Group HeatGuard -Enabled True -Action Allow -Direction Inbound -Profile Any `
                -Program $pythonProgram -Protocol TCP -LocalPort $Port -LocalAddress $address `
                -RemoteAddress LocalSubnet -InterfaceAlias $InterfaceAlias -EdgeTraversalPolicy Block |
                Out-Null
            $createdRule = $true
        }

        # Windows block rules override allow rules. Preserve each existing Python
        # TCP block on every other port, leaving only this API port for the allow rule.
        foreach ($block in $blocks) {
            Get-NetFirewallRule -PolicyStore PersistentStore -Name $block.Name |
                Get-NetFirewallPortFilter |
                Set-NetFirewallPortFilter -LocalPort $otherPorts |
                Out-Null
            $changedBlocks += $block
        }
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resultPath) -Force | Out-Null
    @{ ok = $true; api = "http://${address}:$Port"; interface = $InterfaceAlias; changed_blocks = $changedBlocks.Count } |
        ConvertTo-Json | Set-Content -LiteralPath $resultPath -Encoding UTF8
    Write-Output "Phone API address: http://${address}:$Port"
}
catch {
    # Roll back this invocation if a firewall command fails partway through.
    foreach ($block in $changedBlocks) {
        Get-NetFirewallRule -PolicyStore PersistentStore -Name $block.Name -ErrorAction SilentlyContinue |
            Get-NetFirewallPortFilter |
            Set-NetFirewallPortFilter -LocalPort $block.LocalPort -ErrorAction SilentlyContinue |
            Out-Null
    }
    if ($createdRule) {
        Remove-NetFirewallRule -PolicyStore PersistentStore -Name $ruleName -ErrorAction SilentlyContinue
    }
    New-Item -ItemType Directory -Path (Split-Path -Parent $resultPath) -Force | Out-Null
    @{ ok = $false; error = $_.Exception.Message } | ConvertTo-Json |
        Set-Content -LiteralPath $resultPath -Encoding UTF8
    throw
}
