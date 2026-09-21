Set-StrictMode -Version Latest

function Protect-MigrationErrorText {
    param(
        [AllowNull()] [string] $Text,
        [string[]] $KnownSecrets = @()
    )

    if ($null -eq $Text) { return $null }
    $safeText = $Text
    foreach ($secret in $KnownSecrets) {
        if (-not [string]::IsNullOrEmpty($secret)) {
            $safeText = $safeText.Replace($secret, '<redacted>')
        }
    }
    $safeText `
        -replace '(?i)(Password|Pwd|Access[ _-]?Token|AccountKey|SharedAccessSignature)\s*=\s*[^;\s]*', '$1=<redacted>' `
        -replace '(?i)(Authorization\s*[:=,]?\s*Bearer|Bearer)[\s:_-]+[A-Za-z0-9._~+/-]+=*', '$1 <redacted>' `
        -replace '\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\b', '<redacted-jwt>' `
        -replace '(?i)([?&](sig|se|sp|sv|sr|st)=)[^&\s]*', '$1<redacted>'
}

function Write-MigrationError {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)] [string] $Phase,
        [Parameter(Mandatory)] [string] $Operation,
        [Parameter(Mandatory)]
        [System.Management.Automation.ErrorRecord] $ErrorRecord,
        [string] $DatabaseOrResource = 'Not available',
        [string] $DiagnosticsPath = 'Not written',
        [string] $NextAction = 'Stop and inspect the reported failure.',
        [string[]] $KnownSecrets = @()
    )

    $safeMessage = Protect-MigrationErrorText `
        -Text ([string] $ErrorRecord.Exception.Message) `
        -KnownSecrets $KnownSecrets
    if ([string]::IsNullOrWhiteSpace($safeMessage)) {
        $safeMessage = 'No error message was returned.'
    }

    $errorCode = if ($ErrorRecord.FullyQualifiedErrorId) {
        Protect-MigrationErrorText `
            -Text ([string] $ErrorRecord.FullyQualifiedErrorId) `
            -KnownSecrets $KnownSecrets
    } else {
        'Not available'
    }

    Write-Host 'Status: Failed' -ForegroundColor Red
    Write-Host ('Phase: {0}' -f $Phase)
    Write-Host ('Database/resource: {0}' -f $DatabaseOrResource)
    Write-Host ('Operation: {0}' -f $Operation)
    Write-Host ('Error: {0}' -f $safeMessage) -ForegroundColor Red
    Write-Host ('Error code: {0}' -f $errorCode)
    Write-Host ('Diagnostics: {0}' -f $DiagnosticsPath)
    Write-Host ('Next action: {0}' -f $NextAction)
}
