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
