# Copyright (c) Microsoft Corporation.
# Licensed under the MIT license.

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ApprovedTargetSkuCatalog {
  param(
    [string] $Path = (Join-Path $PSScriptRoot `
      'azure-sql-db-vcore-sku-limits.json')
  )

  if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
    throw "Approved target SKU catalog '$Path' was not found."
  }
  $document = Get-Content -LiteralPath $Path -Raw | ConvertFrom-Json
  try {
    $sourceUpdatedAt = [DateTimeOffset]::Parse(
      [string] $document.SourceUpdatedAt,
      [Globalization.CultureInfo]::InvariantCulture,
      [Globalization.DateTimeStyles]::AssumeUniversal
    ).ToUniversalTime().ToString(
      'yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture
    )
  } catch {
    throw "Approved target SKU catalog '$Path' has an invalid SourceUpdatedAt timestamp."
  }
  if ($document.SchemaVersion -ne 1 -or
      $document.Source -cne 'https://learn.microsoft.com/en-us/azure/azure-sql/database/resource-limits-vcore-single-databases?view=azuresql' -or
      $document.SourceDate -cne '2026-03-09' -or
      $sourceUpdatedAt -cne '2026-04-10T17:39:00Z' -or
      @($document.Entries).Count -eq 0) {
    throw "Approved target SKU catalog '$Path' has an unsupported or incomplete schema."
  }

  $stableDefinitions = @{
    'GP_Gen5_{0}' = [pscustomobject]@{
      ServiceType = 'GeneralPurpose'; Objective = 'Provisioned - standard-series (Gen5)'
      VCores = @(2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80, 128)
      MaxSizes = @(1024, 1024, 1536, 2048, 2048, 3072, 3072, 3072, 3072, 3072, 4096, 4096, 4096, 4096, 4096)
    }
    'GP_S_Gen5_{0}' = [pscustomobject]@{
      ServiceType = 'GeneralPurpose'; Objective = 'Serverless - standard-series (Gen5)'
      VCores = @(1, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80)
      MaxSizes = @(512, 1024, 1024, 1024, 2048, 2048, 3072, 3072, 3072, 3072, 3072, 4096, 4096, 4096, 4096)
    }
    'GP_DC_{0}' = [pscustomobject]@{
      ServiceType = 'GeneralPurpose'; Objective = 'Provisioned - DC-series'
      VCores = @(2, 4, 6, 8)
      MaxSizes = @(1024, 1536, 3072, 3072)
    }
    'BC_Gen5_{0}' = [pscustomobject]@{
      ServiceType = 'BusinessCritical'; Objective = 'Provisioned - standard-series (Gen5)'
      VCores = @(2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80, 128)
      MaxSizes = @(1024, 1024, 1536, 2048, 2048, 3072, 3072, 3072, 3072, 3072, 4096, 4096, 4096, 4096, 4096)
    }
    'BC_DC_{0}' = [pscustomobject]@{
      ServiceType = 'BusinessCritical'; Objective = 'Provisioned - DC-series'
      VCores = @(2, 4, 6, 8)
      MaxSizes = @(768, 768, 768, 768)
    }
    'HS_Gen5_{0}' = [pscustomobject]@{
      ServiceType = 'Hyperscale'; Objective = 'Provisioned - standard-series (Gen5)'
      VCores = @(2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80)
      MaxSizes = @(131072) * 14
    }
    'HS_S_Gen5_{0}' = [pscustomobject]@{
      ServiceType = 'Hyperscale'; Objective = 'Serverless - standard-series (Gen5)'
      VCores = @(2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 80)
      MaxSizes = @(131072) * 14
    }
    'HS_DC_{0}' = [pscustomobject]@{
      ServiceType = 'Hyperscale'; Objective = 'Provisioned - DC-series'
      VCores = @(2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 32, 40)
      MaxSizes = @(131072) * 12
    }
    'HS_PRMS_{0}' = [pscustomobject]@{
      ServiceType = 'Hyperscale'; Objective = 'Provisioned - premium-series'
      VCores = @(2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 64, 80, 128)
      MaxSizes = @(131072) * 16
    }
    'HS_MOPRMS_{0}' = [pscustomobject]@{
      ServiceType = 'Hyperscale'; Objective = 'Provisioned - premium-series memory optimized'
      VCores = @(2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 32, 40, 64, 80)
      MaxSizes = @(131072) * 15
    }
  }
  if (@($document.Entries).Count -ne $stableDefinitions.Count) {
    throw "Approved target SKU catalog must contain exactly $($stableDefinitions.Count) stable entries."
  }

  foreach ($entry in @($document.Entries)) {
    foreach ($propertyName in @(
      'ServiceType', 'ServiceObjective', 'DatabaseServiceObjectiveTemplate',
      'AllowedVCores', 'DocumentedMaxDataSizeGBByVCore'
    )) {
      if (-not $entry.PSObject.Properties[$propertyName]) {
        throw "Approved target SKU catalog entry is missing '$propertyName'."
      }
    }
    $template = [string]$entry.DatabaseServiceObjectiveTemplate
    $definition = $stableDefinitions[$template]
    if (-not $definition) {
      throw "Approved target SKU catalog contains unsupported, preview, or unavailable family '$template'."
    }
    if (@($document.Entries | Where-Object {
          $_.DatabaseServiceObjectiveTemplate -ceq $template
        }).Count -ne 1) {
      throw "Approved target SKU catalog family '$template' is not unique."
    }
    if ($entry.ServiceType -cne $definition.ServiceType -or
        $entry.ServiceObjective -cne $definition.Objective -or
        (@($entry.AllowedVCores) -join ',') -cne
          (@($definition.VCores) -join ',')) {
      throw "Approved target SKU catalog family '$template' does not match the published stable definition."
    }
    $limits = $entry.DocumentedMaxDataSizeGBByVCore
    foreach ($vCore in @($entry.AllowedVCores)) {
      $limitProperty = $limits.PSObject.Properties[[string][int]$vCore]
      if (-not $limitProperty -or [int]$limitProperty.Value -le 0) {
        throw "Approved target SKU '$($entry.ServiceObjective)' has no positive documented maximum data size for vCore '$vCore'."
      }
    }
    $actualMaxSizes = @($entry.AllowedVCores | ForEach-Object {
      [int]$limits.PSObject.Properties[[string][int]$_].Value
    })
    if (($actualMaxSizes -join ',') -cne
        (@($definition.MaxSizes) -join ',')) {
      throw "Approved target SKU catalog family '$template' does not match the published maximum data-size limits."
    }
    $limitKeys = @($limits.PSObject.Properties.Name | Sort-Object)
    $vCoreKeys = @($entry.AllowedVCores | ForEach-Object {
      [string][int]$_
    } | Sort-Object)
    if (($limitKeys -join ',') -cne ($vCoreKeys -join ',')) {
      throw "Approved target SKU '$($entry.ServiceObjective)' contains missing or unsupported vCore size limits."
    }
  }

  @($document.Entries)
}

function New-TargetConfigurationInputTracker {
  [pscustomobject]@{
    ServiceType = [pscustomobject]@{
      Status = 'Pending'
      Value = $null
      Options = @('GeneralPurpose', 'BusinessCritical', 'Hyperscale')
      DisplayOptions = @(
        [pscustomobject]@{ Label = 'General Purpose'; Value = 'GeneralPurpose' }
        [pscustomobject]@{ Label = 'Business Critical'; Value = 'BusinessCritical' }
        [pscustomobject]@{ Label = 'Hyperscale'; Value = 'Hyperscale' }
      )
    }
    ServiceObjective = [pscustomobject]@{
      Status = 'Blocked'
      Value = $null
      Options = @()
    }
    VCore = [pscustomobject]@{
      Status = 'Blocked'
      Value = $null
      Options = @()
      InputType = 'Integer'
    }
    MaximumSizeGB = [pscustomobject]@{
      Status = 'Blocked'
      Value = $null
      Options = @()
      InputType = 'Integer'
    }
  }
}

function Set-TargetConfigurationServiceType {
  param(
    [Parameter(Mandatory)] [object] $Tracker,
    [Parameter(Mandatory)] [object[]] $ApprovedCatalog,
    [Parameter(Mandatory)]
    [ValidateSet('GeneralPurpose', 'BusinessCritical', 'Hyperscale')]
    [string] $ServiceType
  )

  $objectives = @($ApprovedCatalog | Where-Object {
    $_.ServiceType -ceq $ServiceType
  } | ForEach-Object { [string] $_.ServiceObjective } | Sort-Object -Unique)
  if ($objectives.Count -eq 0) {
    throw "The approved catalog has no service objectives for '$ServiceType'."
  }

  $Tracker.ServiceType.Status = 'Complete'
  $Tracker.ServiceType.Value = $ServiceType
  $Tracker.ServiceObjective.Status = 'Pending'
  $Tracker.ServiceObjective.Value = $null
  $Tracker.ServiceObjective.Options = $objectives
  $Tracker.VCore.Status = 'Blocked'
  $Tracker.VCore.Value = $null
  $Tracker.VCore.Options = @()
  $Tracker.MaximumSizeGB.Status = 'Blocked'
  $Tracker.MaximumSizeGB.Value = $null
  $Tracker.MaximumSizeGB.Options = @()
  $Tracker
}

function Set-TargetConfigurationServiceObjective {
  param(
    [Parameter(Mandatory)] [object] $Tracker,
    [Parameter(Mandatory)] [object[]] $ApprovedCatalog,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()]
    [string] $ServiceObjective
  )

  if ($Tracker.ServiceType.Status -cne 'Complete') {
    throw 'Select the service type before selecting a service objective.'
  }
  if ($ServiceObjective -cnotin @($Tracker.ServiceObjective.Options)) {
    throw "Service objective '$ServiceObjective' is not an approved option for '$($Tracker.ServiceType.Value)'."
  }
  $matches = @($ApprovedCatalog | Where-Object {
    $_.ServiceType -ceq $Tracker.ServiceType.Value -and
    $_.ServiceObjective -ceq $ServiceObjective
  })
  if ($matches.Count -ne 1) {
    throw "Service objective '$ServiceObjective' is not a unique approved catalog entry."
  }
  $allowedVCoresProperty = $matches[0].PSObject.Properties['AllowedVCores']
  if (-not $allowedVCoresProperty) {
    throw "Approved service objective '$ServiceObjective' has no AllowedVCores list."
  }
  $allowedVCores = @($allowedVCoresProperty.Value | ForEach-Object { [int] $_ })
  if ($allowedVCores.Count -eq 0) {
    throw "Approved service objective '$ServiceObjective' has no selectable vCore values."
  }

  $Tracker.ServiceObjective.Status = 'Complete'
  $Tracker.ServiceObjective.Value = $ServiceObjective
  $Tracker.VCore.Status = 'Pending'
  $Tracker.VCore.Value = $null
  $Tracker.VCore.Options = $allowedVCores
  $Tracker.MaximumSizeGB.Status = 'Blocked'
  $Tracker.MaximumSizeGB.Value = $null
  $Tracker.MaximumSizeGB.Options = @()
  $Tracker
}

function Set-TargetConfigurationVCore {
  param(
    [Parameter(Mandatory)] [object] $Tracker,
    [Parameter(Mandatory)] [object[]] $ApprovedCatalog,
    [Parameter(Mandatory)] [ValidateRange(1, 128)]
    [int] $VCore
  )

  if ($Tracker.ServiceObjective.Status -cne 'Complete') {
    throw 'Select the service objective before entering vCore.'
  }
  if ($VCore -notin @($Tracker.VCore.Options)) {
    throw "vCore '$VCore' is not approved for '$($Tracker.ServiceObjective.Value)'. Allowed values: $($Tracker.VCore.Options -join ', ')."
  }
  $entry = @($ApprovedCatalog | Where-Object {
    $_.ServiceType -ceq $Tracker.ServiceType.Value -and
    $_.ServiceObjective -ceq $Tracker.ServiceObjective.Value
  })[0]
  $maximumSizesProperty =
    $entry.PSObject.Properties['DocumentedMaxDataSizeGBByVCore']
  if (-not $maximumSizesProperty) {
    throw "Approved service objective '$($Tracker.ServiceObjective.Value)' has no DocumentedMaxDataSizeGBByVCore map."
  }
  $maximumSizesByVCore = $maximumSizesProperty.Value
  $vCoreProperty = $maximumSizesByVCore.PSObject.Properties[[string]$VCore]
  $maximumSizes = @(if ($vCoreProperty) {
    @([int]$vCoreProperty.Value)
  } else { @() })
  if ($maximumSizes.Count -eq 0) {
    throw "Approved service objective '$($Tracker.ServiceObjective.Value)' has no documented maximum size for vCore '$VCore'."
  }

  $Tracker.VCore.Status = 'Complete'
  $Tracker.VCore.Value = $VCore
  # Apply the one published resource-limit ceiling for this SKU/vCore directly.
  $Tracker.MaximumSizeGB.Status = 'Complete'
  $Tracker.MaximumSizeGB.Value = $maximumSizes[0]
  $Tracker.MaximumSizeGB.Options = $maximumSizes
  $Tracker
}

function Resolve-ApprovedTargetSkuSelection {
  param(
    [Parameter(Mandatory)] [object[]] $ApprovedCatalog,
    [Parameter(Mandatory)]
    [ValidateSet('GeneralPurpose', 'BusinessCritical', 'Hyperscale')]
    [string] $ServiceType,
    [Parameter(Mandatory)] [ValidateNotNullOrEmpty()]
    [string] $ServiceObjective,
    [Parameter(Mandatory)] [ValidateRange(1, 128)]
    [int] $VCore,
    [Parameter(Mandatory)] [ValidateRange(1, 2147483647)]
    [int] $MaximumSizeGB
  )

  if ($ApprovedCatalog.Count -eq 0) {
    throw 'The approved target SKU catalog is empty.'
  }
  $catalogMatches = @($ApprovedCatalog | Where-Object {
    $_.ServiceType -ceq $ServiceType -and
    $_.ServiceObjective -ceq $ServiceObjective
  })
  if ($catalogMatches.Count -ne 1) {
    throw "Service objective '$ServiceObjective' is not a unique approved catalog entry for '$ServiceType'."
  }
  $entry = $catalogMatches[0]
  $allowedVCoresProperty = $entry.PSObject.Properties['AllowedVCores']
  if (-not $allowedVCoresProperty -or
      $VCore -notin @($allowedVCoresProperty.Value | ForEach-Object { [int] $_ })) {
    throw "vCore '$VCore' is not approved for '$ServiceObjective'."
  }
  $maximumSizesProperty =
    $entry.PSObject.Properties['DocumentedMaxDataSizeGBByVCore']
  if (-not $maximumSizesProperty) {
    throw "Approved catalog entry '$ServiceObjective' has no DocumentedMaxDataSizeGBByVCore map."
  }
  $maximumSizesByVCore = $maximumSizesProperty.Value
  $vCoreProperty = $maximumSizesByVCore.PSObject.Properties[[string]$VCore]
  $allowedMaximumSizesGB = if ($vCoreProperty) {
    @([int]$vCoreProperty.Value)
  } else { @() }
  if ($MaximumSizeGB -notin $allowedMaximumSizesGB) {
    throw "Maximum size '$MaximumSizeGB GB' is not approved for '$ServiceObjective'. Allowed values: $($allowedMaximumSizesGB -join ', ') GB."
  }
  $templateProperty =
    $entry.PSObject.Properties['DatabaseServiceObjectiveTemplate']
  if (-not $templateProperty -or
      [string]::IsNullOrWhiteSpace([string]$templateProperty.Value) -or
      [string]$templateProperty.Value -cnotmatch '\{0\}') {
    throw "Approved catalog entry '$ServiceObjective' has no valid DatabaseServiceObjectiveTemplate."
  }
  $databaseServiceObjective =
    [string]::Format([string]$templateProperty.Value, $VCore)
  $expectedPrefix = switch ($ServiceType) {
    'GeneralPurpose' { 'GP_' }
    'BusinessCritical' { 'BC_' }
    'Hyperscale' { 'HS_' }
  }
  if (-not $databaseServiceObjective.StartsWith(
      $expectedPrefix,
      [StringComparison]::OrdinalIgnoreCase
    )) {
    throw "Resolved database service objective '$databaseServiceObjective' does not belong to service type '$ServiceType'."
  }

  [pscustomobject]@{
    ServiceType = $ServiceType
    ServiceObjective = $ServiceObjective
    VCore = $VCore
    MaximumSizeGB = $MaximumSizeGB
    DatabaseEdition = $ServiceType
    DatabaseServiceObjective = $databaseServiceObjective
  }
}

function Complete-TargetConfiguration {
  param(
    [Parameter(Mandatory)] [object] $Tracker,
    [Parameter(Mandatory)] [object[]] $ApprovedCatalog
  )

  $incompleteInputs = @(
    'ServiceType', 'ServiceObjective', 'VCore', 'MaximumSizeGB' |
      Where-Object { $Tracker.$_.Status -cne 'Complete' }
  )
  if ($incompleteInputs.Count -gt 0) {
    throw "Target configuration is incomplete. Complete: $($incompleteInputs -join ', ')."
  }

  Resolve-ApprovedTargetSkuSelection `
    -ApprovedCatalog $ApprovedCatalog `
    -ServiceType $Tracker.ServiceType.Value `
    -ServiceObjective $Tracker.ServiceObjective.Value `
    -VCore $Tracker.VCore.Value `
    -MaximumSizeGB $Tracker.MaximumSizeGB.Value
}

# SIG # Begin signature block
# MIInUwYJKoZIhvcNAQcCoIInRDCCJ0ACAQExDzANBglghkgBZQMEAgEFADB5Bgor
# BgEEAYI3AgEEoGswaTA0BgorBgEEAYI3AgEeMCYCAwEAAAQQH8w7YFlLCE63JNLG
# KX7zUQIBAAIBAAIBAAIBAAIBADAxMA0GCWCGSAFlAwQCAQUABCCk9jaHqr/G4iru
# DDIQqLFko6/GHcCOeHoZJN+s8xN1KqCCDMkwggYEMIID7KADAgECAhMzAAACHPrN
# xZvoL37EAAAAAAIcMA0GCSqGSIb3DQEBCwUAMFcxCzAJBgNVBAYTAlVTMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xKDAmBgNVBAMTH01pY3Jvc29mdCBD
# b2RlIFNpZ25pbmcgUENBIDIwMjQwHhcNMjYwNDE2MTg1OTQxWhcNMjcwNDE1MTg1
# OTQxWjB0MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UE
# BxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMR4wHAYD
# VQQDExVNaWNyb3NvZnQgQ29ycG9yYXRpb24wggEiMA0GCSqGSIb3DQEBAQUAA4IB
# DwAwggEKAoIBAQDVsZfgOKmM31HPfoWOoNEiw0SlCiIxUMC0I9NMWbucKOw/e9lP
# oAoehQVu6SG65V4EPzrYsnBnFPNoi4/HoOdjhz1qkrEt4I6tEcxXU6oOeY9zGveC
# /3iBeuhLYxM3M/PkcUoebF+Nednm8OkdSPoDu8imViHPQq/8CQUu0WRR4rE+dMRf
# rpVqfmNi2qWCX94T4MsepijGVkwE//tJg0ryAiYdHT34LSnlG/RSBZmQRGWZ5g8j
# qnKjRParSqMft1gvjuUTVgtWNZfgcLFSK5Wa0myrq8OPcgTGGsRgun+tnSS+IxDT
# xVsAPH1OzvPjwomguByhUe/OcvUN0D5Wmp7xAgMBAAGjggGqMIIBpjAOBgNVHQ8B
# Af8EBAMCB4AwHwYDVR0lBBgwFgYKKwYBBAGCN0wIAQYIKwYBBQUHAwMwHQYDVR0O
# BBYEFNoH7a2YDjOSwpkp6DHcmUS7J+0yMFQGA1UdEQRNMEukSTBHMS0wKwYDVQQL
# EyRNaWNyb3NvZnQgSXJlbGFuZCBPcGVyYXRpb25zIExpbWl0ZWQxFjAUBgNVBAUT
# DTIzMDAxMis1MDc1NjkwHwYDVR0jBBgwFoAUf1k/VCHarU/vBeXmo9ctBpQSCDEw
# YAYDVR0fBFkwVzBVoFOgUYZPaHR0cDovL3d3dy5taWNyb3NvZnQuY29tL3BraW9w
# cy9jcmwvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmclMjBQQ0ElMjAyMDI0LmNy
# bDBtBggrBgEFBQcBAQRhMF8wXQYIKwYBBQUHMAKGUWh0dHA6Ly93d3cubWljcm9z
# b2Z0LmNvbS9wa2lvcHMvY2VydHMvTWljcm9zb2Z0JTIwQ29kZSUyMFNpZ25pbmcl
# MjBQQ0ElMjAyMDI0LmNydDAMBgNVHRMBAf8EAjAAMA0GCSqGSIb3DQEBCwUAA4IC
# AQAUnEqhaRXe0T3hIJjvdQErEkrA/7bByjn6t5IArODkkRjzkYwtKMc2yYj2quaN
# rLutWw2YZcngKPy1b71YyDJQTy4NDRwaSh9Tw5thrk3NmcPrAHia5vtcBJ1CgtKK
# 7mQbIcQ22d/N3813ayCDDFewu1+jsZmX+r/aTEqaOM4TVxVtRSkuCy8nAXKuChOK
# Li/zA4XuH8iEYqIsj2YoNaeSxVmeGiERXpKdo3dDmYi0kO5w2D8VS4c3+9h6gElY
# BaAAg/dYErBg27qT3vv0zRDJhJufvCNylA8S7/+8H5E/PV5cng6na9VV/w9OV3qu
# uND6zdGa2EX38Glp50F9AIQk3p2xXmcvorDeM4XJ7UlWYBi6g80J1SSOQnInCYFE
# msfUNn3+1AaTJKSJL83quKArTac2pKhu0Yzzzrzo6HrsRiQKzpnRBb1/dMa6P3hz
# 75XbMRBctNsFhZC07WCmjExdLg2eHW5uV0TY8D5+6wozJf7vF3+WHkYPO85Z+BC6
# U4FkNbYNycZ9cE4j1tXRdyDCfml6c0HWPHjNVDObrv9lKt3qUqFpX38VCqVCyNOO
# 1UcXfQiVjJw32U2WUKZjt/neJKHEBsm9kFsLuWzkQ53+qcaSaytmsCnk2gOglrlD
# 5d3kKyvvAw+rzm0lT8K38P6PLxfZQHhu4W8dV7Av8N2ZmDCCBr0wggSloAMCAQIC
# EzMAAAA5O7Y3Gb8GHWcAAAAAADkwDQYJKoZIhvcNAQEMBQAwgYgxCzAJBgNVBAYT
# AlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYD
# VQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xMjAwBgNVBAMTKU1pY3Jvc29mdCBS
# b290IENlcnRpZmljYXRlIEF1dGhvcml0eSAyMDExMB4XDTI0MDgwODIwNTQxOFoX
# DTM2MDMyMjIyMTMwNFowVzELMAkGA1UEBhMCVVMxHjAcBgNVBAoTFU1pY3Jvc29m
# dCBDb3Jwb3JhdGlvbjEoMCYGA1UEAxMfTWljcm9zb2Z0IENvZGUgU2lnbmluZyBQ
# Q0EgMjAyNDCCAiIwDQYJKoZIhvcNAQEBBQADggIPADCCAgoCggIBANgBnB7jOMeq
# lRYHNa265v4IY9fH8TKhemHfPINe1gpLaV3dhg324WwH06LcHbpnsBukCDNitryo
# 0dtS/EW6I/yEL/bLSY8hKpbfQuWusBPr9qazYcDxCW/qnjb5JsI1s8bNOg3bVATv
# QVL4tcf03aTycsz8QeCdM0l/yHRObJ9QqazM1r6VPEOJ7LL+uEEb73w6QCuhs89a
# 1uv1zerOYMnsneRRwCbpyW11IcggU0cRKDDq1pjVJzIbIF6+oiXXbReOsgeI8zu1
# FyQfK0fVkaya8SmVHQ/tOf23mZ4W9k0Ri22QW9p3UgSC5OUDktKxxcCmGL6tXLfO
# GSWHIIV4YrTJTT6PNty5REojHJuZHArkF9VnHTERWoTjAzfI3kP+5b4alUdhgAZ7
# ttOu1bVnXfHaqPYl2rPs20ji03LOVWsh/radgE17es5hL+t6lV0eVHrVhsssROWJ
# uz2MXMCt7iw7lFPG9LXKGjsmonn2gotGdHIuEg5JnJMJVmixd5LRlkmgYRZKzhxS
# CwyoGIq0PhaA7Y+VPct5pCHkijcIIDm0nlkK+0KyepolcqGm0T/GYQRMhHJlGOOm
# VQop36wUVUYklUy++vDWeEgEo4s7hxN6mIbf2MSIQ/iIfMZgJxC69oukMUXCrOC3
# SkE/xIkgpfl22MM1itkZ35nNXkMolU1lAgMBAAGjggFOMIIBSjAOBgNVHQ8BAf8E
# BAMCAYYwEAYJKwYBBAGCNxUBBAMCAQAwHQYDVR0OBBYEFH9ZP1Qh2q1P7wXl5qPX
# LQaUEggxMBkGCSsGAQQBgjcUAgQMHgoAUwB1AGIAQwBBMA8GA1UdEwEB/wQFMAMB
# Af8wHwYDVR0jBBgwFoAUci06AjGQQ7kUBU7h6qfHMdEjiTQwWgYDVR0fBFMwUTBP
# oE2gS4ZJaHR0cDovL2NybC5taWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNybDBeBggrBgEFBQcBAQRSMFAw
# TgYIKwYBBQUHMAKGQmh0dHA6Ly93d3cubWljcm9zb2Z0LmNvbS9wa2kvY2VydHMv
# TWljUm9vQ2VyQXV0MjAxMV8yMDExXzAzXzIyLmNydDANBgkqhkiG9w0BAQwFAAOC
# AgEAFJQfOChP7onn6fLIMKrSlN1WYKwDFgAddymOUO3FrM8d7B/W/iQ6DxXsDn7D
# 5W4wMwYeLystcEqfkjz4NURRgazyMu5yRzQh4LqjA4tStTcJh1opExo7nn5PuPBY
# nbu0+THSuVHTe0VTTPVhily/piFrDo3axQ9P4C+Ol5yet+2gTfekICS5xS+cYfSI
# vgn0JksVBVMYVI5QFu/qhnLhsEFEUzG8fvv0hjgkO+lkpV9ty6GkN4vdnd7ya6Q6
# aR9y34aiM1qmxaxBi6OUnyNl6fkuun/diTFnYDLTppOkr/mg5WSfCiDVMNCxtj4w
# PKC5OmHm1DQIt/MNokbbH3UGsFP1QbzsLocuSqLCvH09Io3fDPTmscR9Y75G4qX7
# RTX8AdBPo0I6OEojf39zuFZt0qOHm65YWQE69cZM2ueE1MB05dNNgHK9gTE7zKvK
# /fg8B2qjW88MT/WF5V5uvZGtqa9FSL2RazArA+rDPuf6JGYz4HpgMZHB4S6szWSK
# YBv0VisCzfxgeU+dquXW9bd0auYlOB58DPcOYKdc3Se94g+xL4pcEhbB54JOgAkw
# YTu/9dLeH2pDqeJZAABVDWRQCaXfO5LgyKwKCLYXpigrZYCjUSBcr+Ve8PFWMhVT
# Ql0v4q8J/AUmQN5W4n101cY2L4A7GTQG1h32HHAvfQESWP0xghngMIIZ3AIBATBu
# MFcxCzAJBgNVBAYTAlVTMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# KDAmBgNVBAMTH01pY3Jvc29mdCBDb2RlIFNpZ25pbmcgUENBIDIwMjQCEzMAAAIc
# +s3Fm+gvfsQAAAAAAhwwDQYJYIZIAWUDBAIBBQCggZAwGQYJKoZIhvcNAQkDMQwG
# CisGAQQBgjcCAQQwLwYJKoZIhvcNAQkEMSIEICeJuSZZg3Nt7G2iTLkqr8VrXL8p
# L/otdjYmB2Sddc5vMEIGCisGAQQBgjcCAQwxNDAyoBSAEgBNAGkAYwByAG8AcwBv
# AGYAdKEagBhodHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20wDQYJKoZIhvcNAQEBBQAE
# ggEAVaRCrl4l9RFQYzsZjaxvOSEbA3KIUXHqmkIwNU9cTIcaBvPdWj+G31evNPa1
# ORbbXEa8mOWhly71XEfV6/PG+HQai7X1DZ7LqVsOLv+oeS+Od3j7eC3kznagWHgt
# 2nO2SfImal923zFOV98oPEH4tulc4XDrsXRgEjzpdX0wvr8fePwYlXHe8FEYHTQe
# lHX1SSZR+uFzObHp8bqdT7RZb4acraD6fQCCIHjM+qMvCPkJxiREpzcQfEJntxqQ
# YY256fuwaJfuvPdF3YZ1HCzcFLvp6Dfrj44rdFVpn61AZLBm+Q6PSIOAedulSfcp
# THjm6rzrwGZ2tf6rF2yPyf0xLqGCF7AwghesBgorBgEEAYI3AwMBMYIXnDCCF5gG
# CSqGSIb3DQEHAqCCF4kwgheFAgEDMQ8wDQYJYIZIAWUDBAIBBQAwggFaBgsqhkiG
# 9w0BCRABBKCCAUkEggFFMIIBQQIBAQYKKwYBBAGEWQoDATAxMA0GCWCGSAFlAwQC
# AQUABCAUjI4jU/IrTvv/qOcOX1TBfG1lXZvcQ7obhDodHXNNqQIGavNrjKVDGBMy
# MDI2MTExMzIyMTAxNS4wNjFaMASAAgH0oIHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2
# RjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaCCEf4wggcoMIIFEKADAgECAhMzAAACMxBftzbaqEBSAAEAAAIzMA0GCSqG
# SIb3DQEBCwUAMHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAw
# DgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24x
# JjAkBgNVBAMTHU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMB4XDTI2MTAx
# NTE4Mzc0MFoXDTI4MDExMTE4Mzc0MFowgdMxCzAJBgNVBAYTAlVTMRMwEQYDVQQI
# EwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRtb25kMR4wHAYDVQQKExVNaWNyb3Nv
# ZnQgQ29ycG9yYXRpb24xLTArBgNVBAsTJE1pY3Jvc29mdCBJcmVsYW5kIE9wZXJh
# dGlvbnMgTGltaXRlZDEnMCUGA1UECxMeblNoaWVsZCBUU1MgRVNOOjZGMUEtMDVF
# MC1EOTQ3MSUwIwYDVQQDExxNaWNyb3NvZnQgVGltZS1TdGFtcCBTZXJ2aWNlMIIC
# IjANBgkqhkiG9w0BAQEFAAOCAg8AMIICCgKCAgEAvJeYUpkXCzUl9TgLYm5Z20zo
# 1Yt1XXD87sEzAs5mcGBr6rM3uo4i5fMAfljkijJfwY3ypfnBuPX8IYS/SKq5k3q0
# Z2BzrVzMLMLTA81OPNgU/HspMj9wd/AxEuz7A0wH5vivLQWOribIaX5Efp4OFt3v
# S1FS2bDNL8ojhv1v+yVKRX0WAmcN1j1lGKl/7qgPd2fJnQJAbMVS6NjAW16l7gLJ
# YrFET/D9glQNAt0ZoNvtNhWQH3TxoOvtHl3VVFZpbpdbotXMdLb031/DTXBVcVwc
# KE+z29ZzKul/ZQf1xyBQFbvqEbsjeBplOoYwlIfnZsnExCvpza3mGK9F49UIjR4F
# g98DkOAy145xkiTG/lO1AWcBo5k6IgniKePSeus4TROMEFDh9/TrK7Shx4PFvLQY
# TsN088WtIBd1nM/Ab0XWPlBpoKJN2tVCJs/t7L7t7r0WnHdhiqNcM7CdUAgWwrcI
# yRHhNfHFoR8tZmXG+D1XDcVD832wLqTxfhEZDZf6MOWyFM/p75pVdpUjMK6L7BRt
# Lqmq7+3sltGgVTuCy23OTvKMzZ0MgzzSIQ57/XIZyyUl6VpaEBR8vjxIjVfPCgSW
# UISK9jNatLFHQeZJmQ0YZbEmhBNFGbcHI+lSXrTXiVJQ65U9VdpK5Q+iD4GWvzTo
# NN3bsjiqRGZ1cn0z0gUCAwEAAaOCAUkwggFFMB0GA1UdDgQWBBQ03ANXWvlTdHvR
# /foC/vNWzgmesjAfBgNVHSMEGDAWgBSfpxVdAF5iXYP05dJlpxtTNRnpcjBfBgNV
# HR8EWDBWMFSgUqBQhk5odHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL2Ny
# bC9NaWNyb3NvZnQlMjBUaW1lLVN0YW1wJTIwUENBJTIwMjAxMCgxKS5jcmwwbAYI
# KwYBBQUHAQEEYDBeMFwGCCsGAQUFBzAChlBodHRwOi8vd3d3Lm1pY3Jvc29mdC5j
# b20vcGtpb3BzL2NlcnRzL01pY3Jvc29mdCUyMFRpbWUtU3RhbXAlMjBQQ0ElMjAy
# MDEwKDEpLmNydDAMBgNVHRMBAf8EAjAAMBYGA1UdJQEB/wQMMAoGCCsGAQUFBwMI
# MA4GA1UdDwEB/wQEAwIHgDANBgkqhkiG9w0BAQsFAAOCAgEAVBdJbvLNhLsdPPzE
# hg+/bkLJeRDxAcsUg/npuOGDq8SCzm7jXTCjm8ZTENfAxH/2guw/nrBZLOe5kLbP
# j3gPLgYm9k9GOsBhswMi48rtl6V0gb1OOckVQQkCSQXyjyOsjIzIgpIexnufffaw
# OeDC5t2rrMpOvx1mtqVnfNZIGMpygpoGh5qbF/P74uhNuaM52UEA3+VxXUf9dSUP
# 9LgYzY4kLHrnJulkSQ6QHixMa2ImGNYiGP7ftpe8k8dkvjbGzTouoljlqCqHiJmY
# rjPl68x9rPr3+kilKuemvawyLtQ6zb0WzvSKLSv6LvE8DbmuAecnbR8CjDNyeKiV
# qnyY7YVKh8xcKXGv20MWFViRNrJwD662RmKjOrrpfEi+LzTVffR7FB9ITRnflMCb
# oRiPIm4unHv7zKGFDP2e7QoW17dAy0QGGBeR40Ux/zDFU2YCRMB80OxUYEgmp6jH
# 06dIWeR65b/wAm2yb2h0ka4bgSe77B5L/eZFRi2WwY7f7BFC36Hp/fXkMMo5Q8XH
# EDQfQtUHWY3xRD1sCiRUT0g9JvA9U2+tRh/UXr+rnHW91EIW2xqrEwLCnwrR6Yqm
# H4VK4LSQJ85/mtrDzE0wKOhBcZCPgKSFYxYTXDIXg5q1xeE32Y8i1BYYq3GdG7uX
# U7tTnNE3WcLtI2idcLTdyBtXoZowggdxMIIFWaADAgECAhMzAAAAFcXna54Cm0mZ
# AAAAAAAVMA0GCSqGSIb3DQEBCwUAMIGIMQswCQYDVQQGEwJVUzETMBEGA1UECBMK
# V2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0
# IENvcnBvcmF0aW9uMTIwMAYDVQQDEylNaWNyb3NvZnQgUm9vdCBDZXJ0aWZpY2F0
# ZSBBdXRob3JpdHkgMjAxMDAeFw0yMTA5MzAxODIyMjVaFw0zMDA5MzAxODMyMjVa
# MHwxCzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdS
# ZWRtb25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMT
# HU1pY3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwMIICIjANBgkqhkiG9w0BAQEF
# AAOCAg8AMIICCgKCAgEA5OGmTOe0ciELeaLL1yR5vQ7VgtP97pwHB9KpbE51yMo1
# V/YBf2xK4OK9uT4XYDP/XE/HZveVU3Fa4n5KWv64NmeFRiMMtY0Tz3cywBAY6GB9
# alKDRLemjkZrBxTzxXb1hlDcwUTIcVxRMTegCjhuje3XD9gmU3w5YQJ6xKr9cmmv
# Haus9ja+NSZk2pg7uhp7M62AW36MEBydUv626GIl3GoPz130/o5Tz9bshVZN7928
# jaTjkY+yOSxRnOlwaQ3KNi1wjjHINSi947SHJMPgyY9+tVSP3PoFVZhtaDuaRr3t
# pK56KTesy+uDRedGbsoy1cCGMFxPLOJiss254o2I5JasAUq7vnGpF1tnYN74kpEe
# HT39IM9zfUGaRnXNxF803RKJ1v2lIH1+/NmeRd+2ci/bfV+AutuqfjbsNkz2K26o
# ElHovwUDo9Fzpk03dJQcNIIP8BDyt0cY7afomXw/TNuvXsLz1dhzPUNOwTM5TI4C
# vEJoLhDqhFFG4tG9ahhaYQFzymeiXtcodgLiMxhy16cg8ML6EgrXY28MyTZki1ug
# poMhXV8wdJGUlNi5UPkLiWHzNgY1GIRH29wb0f2y1BzFa/ZcUlFdEtsluq9QBXps
# xREdcu+N+VLEhReTwDwV2xo3xwgVGD94q0W29R6HXtqPnhZyacaue7e3PmriLq0C
# AwEAAaOCAd0wggHZMBIGCSsGAQQBgjcVAQQFAgMBAAEwIwYJKwYBBAGCNxUCBBYE
# FCqnUv5kxJq+gpE8RjUpzxD/LwTuMB0GA1UdDgQWBBSfpxVdAF5iXYP05dJlpxtT
# NRnpcjBcBgNVHSAEVTBTMFEGDCsGAQQBgjdMg30BATBBMD8GCCsGAQUFBwIBFjNo
# dHRwOi8vd3d3Lm1pY3Jvc29mdC5jb20vcGtpb3BzL0RvY3MvUmVwb3NpdG9yeS5o
# dG0wEwYDVR0lBAwwCgYIKwYBBQUHAwgwGQYJKwYBBAGCNxQCBAweCgBTAHUAYgBD
# AEEwCwYDVR0PBAQDAgGGMA8GA1UdEwEB/wQFMAMBAf8wHwYDVR0jBBgwFoAU1fZW
# y4/oolxiaNE9lJBb186aGMQwVgYDVR0fBE8wTTBLoEmgR4ZFaHR0cDovL2NybC5t
# aWNyb3NvZnQuY29tL3BraS9jcmwvcHJvZHVjdHMvTWljUm9vQ2VyQXV0XzIwMTAt
# MDYtMjMuY3JsMFoGCCsGAQUFBwEBBE4wTDBKBggrBgEFBQcwAoY+aHR0cDovL3d3
# dy5taWNyb3NvZnQuY29tL3BraS9jZXJ0cy9NaWNSb29DZXJBdXRfMjAxMC0wNi0y
# My5jcnQwDQYJKoZIhvcNAQELBQADggIBAJ1VffwqreEsH2cBMSRb4Z5yS/ypb+pc
# FLY+TkdkeLEGk5c9MTO1OdfCcTY/2mRsfNB1OW27DzHkwo/7bNGhlBgi7ulmZzpT
# Td2YurYeeNg2LpypglYAA7AFvonoaeC6Ce5732pvvinLbtg/SHUB2RjebYIM9W0j
# VOR4U3UkV7ndn/OOPcbzaN9l9qRWqveVtihVJ9AkvUCgvxm2EhIRXT0n4ECWOKz3
# +SmJw7wXsFSFQrP8DJ6LGYnn8AtqgcKBGUIZUnWKNsIdw2FzLixre24/LAl4FOmR
# sqlb30mjdAy87JGA0j3mSj5mO0+7hvoyGtmW9I/2kQH2zsZ0/fZMcm8Qq3UwxTSw
# ethQ/gpY3UA8x1RtnWN0SCyxTkctwRQEcb9k+SS+c23Kjgm9swFXSVRk2XPXfx5b
# RAGOWhmRaw2fpCjcZxkoJLo4S5pu+yFUa2pFEUep8beuyOiJXk+d0tBMdrVXVAmx
# aQFEfnyhYWxz/gq77EFmPWn9y8FBSX5+k77L+DvktxW/tM4+pTFRhLy/AsGConsX
# HRWJjXD+57XQKBqJC4822rpM+Zv/Cuk0+CQ1ZyvgDbjmjJnW4SLq8CdCPSWU5nR0
# W2rRnj7tfqAxM328y+l7vzhwRNGQ8cirOoo6CGJ/2XBjU02N7oJtpQUQwXEGahC0
# HVUzWLOhcGbyoYIDWTCCAkECAQEwggEBoYHZpIHWMIHTMQswCQYDVQQGEwJVUzET
# MBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMHUmVkbW9uZDEeMBwGA1UEChMV
# TWljcm9zb2Z0IENvcnBvcmF0aW9uMS0wKwYDVQQLEyRNaWNyb3NvZnQgSXJlbGFu
# ZCBPcGVyYXRpb25zIExpbWl0ZWQxJzAlBgNVBAsTHm5TaGllbGQgVFNTIEVTTjo2
# RjFBLTA1RTAtRDk0NzElMCMGA1UEAxMcTWljcm9zb2Z0IFRpbWUtU3RhbXAgU2Vy
# dmljZaIjCgEBMAcGBSsOAwIaAxUAWxPKLDixcu4ygj3RSJig/nteDBSggYMwgYCk
# fjB8MQswCQYDVQQGEwJVUzETMBEGA1UECBMKV2FzaGluZ3RvbjEQMA4GA1UEBxMH
# UmVkbW9uZDEeMBwGA1UEChMVTWljcm9zb2Z0IENvcnBvcmF0aW9uMSYwJAYDVQQD
# Ex1NaWNyb3NvZnQgVGltZS1TdGFtcCBQQ0EgMjAxMDANBgkqhkiG9w0BAQsFAAIF
# AO6h3g4wIhgPMjAyNjExMTMxOTA1NTBaGA8yMDI2MTExNDE5MDU1MFowdzA9Bgor
# BgEEAYRZCgQBMS8wLTAKAgUA7qHeDgIBADAKAgEAAgIwbQIB/zAHAgEAAgIUADAK
# AgUA7qMvjgIBADA2BgorBgEEAYRZCgQCMSgwJjAMBgorBgEEAYRZCgMCoAowCAIB
# AAIDB6EgoQowCAIBAAIDAYagMA0GCSqGSIb3DQEBCwUAA4IBAQAYQI90GTcFxtKu
# SAhhJGBjfaR1IKvdllkFICekTlxPgzAZI615QX1oXmd6yINIfSBkcPkUcRVn9TKb
# /hQ1wLq4k5qWq9o9xF1sCxwJXXA05KktRTbwOj4k6dJV5l+Vt+6MtIWEKum+Q7sS
# Y/6P3sb69p3SnxPKbqn1pPwZpfl9ABsaxOBKnS4GosvHkXPPC1qOamvBvnMS/UlY
# h8XENXqsf/+ofU/9mSBw+E3LxtDqmDRJG5N/6s2cpmGjDiuOltvChZmCSxv3VmsS
# yGQoVZXmufASrAsveONT4UU623K4WSY8SysAMHFStJFeB6ga/fwa8hK3I7/9HU+5
# djHLpowfMYIEDTCCBAkCAQEwgZMwfDELMAkGA1UEBhMCVVMxEzARBgNVBAgTCldh
# c2hpbmd0b24xEDAOBgNVBAcTB1JlZG1vbmQxHjAcBgNVBAoTFU1pY3Jvc29mdCBD
# b3Jwb3JhdGlvbjEmMCQGA1UEAxMdTWljcm9zb2Z0IFRpbWUtU3RhbXAgUENBIDIw
# MTACEzMAAAIzEF+3NtqoQFIAAQAAAjMwDQYJYIZIAWUDBAIBBQCgggFKMBoGCSqG
# SIb3DQEJAzENBgsqhkiG9w0BCRABBDAvBgkqhkiG9w0BCQQxIgQgH4e4ItBUKFqG
# D+bvXiwrybzMUjhqlhVPS1InJzsGkxowgfoGCyqGSIb3DQEJEAIvMYHqMIHnMIHk
# MIG9BCCWue5iC0tIXWaU0QT/Up3MULZUb5U9e96q40RB0g45lzCBmDCBgKR+MHwx
# CzAJBgNVBAYTAlVTMRMwEQYDVQQIEwpXYXNoaW5ndG9uMRAwDgYDVQQHEwdSZWRt
# b25kMR4wHAYDVQQKExVNaWNyb3NvZnQgQ29ycG9yYXRpb24xJjAkBgNVBAMTHU1p
# Y3Jvc29mdCBUaW1lLVN0YW1wIFBDQSAyMDEwAhMzAAACMxBftzbaqEBSAAEAAAIz
# MCIEIDW3sWZdgP4ml/+1ngYFaVtmdPIyhJMkexUBeFxViGk6MA0GCSqGSIb3DQEB
# CwUABIICAFoI64BTvH1evJfvZ1AZfwwmJIxswk7povHH+S5QiQyk5Zq34ejQ3xYs
# iU42tJwsyWQWzUhisoeVXYd4vHVTRsU6SYCUnN381pO75QaLtZpHiewZp/nc+gDY
# mLbCAbdnShrj/3Huslh8nBpGBT1O+NRHbBrCcatuOyb/4R7mDmV0JmuYXNCvatl3
# tSFyizcxWCO50UqKEYPc7EZKwwP3IeR8sg+q9GssQ5VXpNx7VoYwJu/Q2Z6iT6vl
# KP983OIa0IXuymRQ26zvYJFJO+lDiMHkVrJaEegz3jyTwOMB9nlpKWKzIyj+Xc8a
# ni6+3biwAMIzEHagXcIPCxACKIdZmTRTkpzkD6WUIExVSAE5UQG+LAmcBx3juClU
# MiTYkxkYcvEvn9A89WBHtDoKfQtc6AUfoLQbI8ZCFNhe0clIqTS31vgVJ3eybyny
# /YjSFlhOxNrhVQZQW8UiI/OkvxMn3zu8UgeEMGARU/hUjTJZU7Vr/r9/h+HAfU2U
# SjVPz+cbyyh/2X9Ua1+mGHpKd7Ql6mXYPPBDwlzV6nPejiCgvMlxBIT5tnapg5b/
# Z8UjQz8BcICkgBYzBIuBksR3QIcDy75brc0iGtJks7GYDZ4VnGoasJgkyD40/Zz6
# oJIt68m/mFo5uR0cjXne7XiqSytHxrteiYEMe6idHX/dGaJILSRd
# SIG # End signature block
