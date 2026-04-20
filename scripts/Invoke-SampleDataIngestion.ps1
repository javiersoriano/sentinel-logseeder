<#
.SYNOPSIS
Generate randomized sample data and ingest it into a Microsoft Sentinel / Log Analytics
workspace via the Azure Monitor Logs Ingestion API.

.DESCRIPTION
This script creates the required Azure infrastructure (DCE, DCR, custom table) and ingests
AI-generated sample data seeded with entities from entities.json. It supports both built-in
(standard) and custom Log Analytics tables.

.REQUIREMENTS
- Azure CLI (az) installed and authenticated via 'az login'.
- 'Monitoring Metrics Publisher' RBAC role on the DCR for the signed-in user (or the
  service principal if using -ClientId/-ClientSecret).

.PARAMETER TableName
Target table name. Custom tables should end with '_CL'.

.PARAMETER RowCount
Number of sample rows to generate. Default: 500.

.PARAMETER Schema
Path to a JSON file containing column definitions. Each element should have 'name' and 'type'.

.PARAMETER SampleDataFile
Path to a JSON or CSV file with representative sample rows. When provided, values are
randomly sampled from this file for the most realistic output.

.PARAMETER EntitiesFile
Path to the entities.json configuration file. Default: config/entities.json relative to project root.

.PARAMETER WorkspaceConfig
Path to workspace.json. Default: config/workspace.json relative to project root.

.PARAMETER Deploy
When specified, creates or reuses DCE, DCR, and custom table resources in Azure.

.PARAMETER Ingest
When specified, generates sample data and ingests it via the Logs Ingestion API.

.PARAMETER TimeWindowHours
Time spread for generated timestamps. Default: 24 hours.

.PARAMETER TenantId
Microsoft Entra tenant ID for service principal auth (optional fallback).

.PARAMETER ClientId
Service principal application (client) ID for ingestion auth (optional fallback).

.PARAMETER ClientSecret
Service principal client secret for ingestion auth (optional fallback).
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TableName,

    [int]$RowCount = 500,

    [string]$Schema,

    [string]$SampleDataFile,

    [string]$EntitiesFile,

    [string]$WorkspaceConfig,

    [switch]$Deploy,

    [switch]$Ingest,

    [int]$TimeWindowHours = 24,

    [string]$TenantId,

    [string]$ClientId,

    [string]$ClientSecret
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# ---------------------------------------------------------------------------
# Resolve default paths relative to project root (parent of scripts/)
# ---------------------------------------------------------------------------
$basePath = if ($PSScriptRoot) { Split-Path $PSScriptRoot -Parent } else { (Get-Location).Path }

if (-not $WorkspaceConfig) {
    $WorkspaceConfig = Join-Path $basePath "config" "workspace.json"
}
if (-not $EntitiesFile) {
    $EntitiesFile = Join-Path $basePath "config" "entities.json"
}

# ═══════════════════════════════════════════════════════════════════════════
# HELPER FUNCTIONS
# ═══════════════════════════════════════════════════════════════════════════

function Assert-AzCli {
    try {
        $null = Get-Command az -ErrorAction Stop
        return $true
    } catch {
        throw "Azure CLI (az) is required. Install from https://aka.ms/installazurecli"
    }
}

function Get-ManagementAccessToken {
    return (az account get-access-token --resource "https://management.azure.com/" --query accessToken -o tsv)
}

function Invoke-ArmRest {
    param(
        [string]$Method,
        [string]$Uri,
        [string]$JsonBody
    )

    if ($Method -eq "GET") {
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = az rest --method get --uri $Uri 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEA
        if ($exitCode -ne 0) {
            $errorOutput = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
            throw "az rest GET failed (exit $exitCode) for ${Uri}: $errorOutput"
        }
        $jsonText = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
        return $jsonText | ConvertFrom-Json
    }

    if (-not $JsonBody -or -not $JsonBody.Trim()) {
        throw "Request body is empty for PUT $Uri"
    }
    $tempFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllText($tempFile, $JsonBody, [System.Text.Encoding]::UTF8)
        $prevEA = $ErrorActionPreference
        $ErrorActionPreference = "Continue"
        $output = az rest --method put --uri $Uri --headers "Content-Type=application/json" --body "@$tempFile" 2>&1
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $prevEA
        if ($exitCode -ne 0) {
            $errorOutput = ($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join "`n"
            throw "az rest PUT failed (exit $exitCode) for ${Uri}: $errorOutput"
        }
        $jsonText = ($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
        if ($jsonText) { return $jsonText | ConvertFrom-Json }
        return $null
    } finally {
        Remove-Item -Path $tempFile -Force -ErrorAction SilentlyContinue
    }
}

function Get-AccessToken {
    param(
        [string]$TokenTenantId,
        [string]$TokenClientId,
        [string]$TokenClientSecret
    )

    if ($TokenTenantId -and $TokenClientId -and $TokenClientSecret) {
        $tokenUri = "https://login.microsoftonline.com/$TokenTenantId/oauth2/v2.0/token"
        $body = @{
            client_id     = $TokenClientId
            client_secret = $TokenClientSecret
            grant_type    = "client_credentials"
            scope         = "https://monitor.azure.com/.default"
        }
        $response = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $body -ContentType "application/x-www-form-urlencoded"
        if (-not $response.access_token) {
            throw "Failed to acquire access token using service principal."
        }
        return $response.access_token
    }

    Assert-AzCli | Out-Null
    $token = az account get-access-token --resource "https://monitor.azure.com/" --query accessToken -o tsv
    if (-not $token) {
        throw "Failed to acquire access token. Ensure you're logged in with 'az login' or provide -ClientId/-ClientSecret."
    }
    return $token
}

function Read-WorkspaceConfig {
    param([string]$ConfigPath)
    if (-not (Test-Path $ConfigPath)) {
        throw "Workspace config not found: $ConfigPath"
    }
    $cfg = Get-Content -Path $ConfigPath -Raw | ConvertFrom-Json
    $resourceId = "/subscriptions/$($cfg.subscriptionId)/resourceGroups/$($cfg.resourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($cfg.workspaceName)"
    return @{
        TenantId            = $cfg.tenantId
        SubscriptionId      = $cfg.subscriptionId
        ResourceGroup       = $cfg.resourceGroup
        WorkspaceName       = $cfg.workspaceName
        WorkspaceId         = $cfg.workspaceId
        WorkspaceResourceId = $resourceId
        DceName             = if ($cfg.PSObject.Properties['dceName'] -and $cfg.dceName) { $cfg.dceName } else { "sample-data-dce" }
    }
}

function Resolve-WorkspaceLocation {
    param([string]$WorkspaceResourceId)
    $apiVersion = "2022-10-01"
    $uri = "https://management.azure.com${WorkspaceResourceId}?api-version=$apiVersion"
    $ws = Invoke-ArmRest -Method "GET" -Uri $uri
    return $ws.location
}

# ---------------------------------------------------------------------------
# Infrastructure: DCE
# ---------------------------------------------------------------------------
function Initialize-Dce {
    param(
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [string]$Location,
        [string]$DceName
    )

    $dceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionEndpoints/$DceName"
    $apiVersion = "2022-06-01"
    $dce = $null

    try {
        $dce = Invoke-ArmRest -Method "GET" -Uri "https://management.azure.com${dceId}?api-version=$apiVersion"
        Write-Host "Reusing existing DCE '$DceName'." -ForegroundColor Green
    } catch {
        $dce = $null
    }

    if (-not $dce) {
        Write-Host "Creating Data Collection Endpoint '$DceName'..." -ForegroundColor Cyan
        $body = @{
            location   = $Location
            properties = @{
                description         = "Sample data ingestion endpoint"
                networkAcls         = @{ publicNetworkAccess = "Enabled" }
            }
        } | ConvertTo-Json -Depth 10 -Compress

        $null = Invoke-ArmRest -Method "PUT" -Uri "https://management.azure.com${dceId}?api-version=$apiVersion" -JsonBody $body
        $dce = Invoke-ArmRest -Method "GET" -Uri "https://management.azure.com${dceId}?api-version=$apiVersion"
        Write-Host "DCE '$DceName' created." -ForegroundColor Green
    }

    return $dce
}

# ---------------------------------------------------------------------------
# Infrastructure: Custom table
# ---------------------------------------------------------------------------
function Initialize-CustomTable {
    param(
        [string]$WorkspaceResourceId,
        [string]$CustomTableName,
        [object[]]$ColumnDefinitions
    )

    $apiVersion = "2022-10-01"
    $tableUri = "https://management.azure.com${WorkspaceResourceId}/tables/${CustomTableName}?api-version=$apiVersion"

    $tableExists = $false
    try {
        $table = Invoke-ArmRest -Method "GET" -Uri $tableUri
        if ($table.properties.provisioningState -eq "Succeeded") {
            Write-Host "Custom table '$CustomTableName' already exists." -ForegroundColor Green
            $tableExists = $true
        }
    } catch {
        # Table does not exist.
    }

    if (-not $tableExists) {
        Write-Host "Creating custom table '$CustomTableName'..." -ForegroundColor Cyan

        $schemaColumns = @(
            @{ name = "TimeGenerated"; type = "datetime"; description = "The time at which the data was generated" }
        )
        foreach ($col in $ColumnDefinitions) {
            if ($col.name -eq "TimeGenerated") { continue }
            $schemaColumns += @{
                name        = $col.name
                type        = if ($col.type) { $col.type } else { "string" }
                description = ""
            }
        }

        $body = @{
            properties = @{
                schema = @{
                    name    = $CustomTableName
                    columns = $schemaColumns
                }
            }
        } | ConvertTo-Json -Depth 20 -Compress

        $null = Invoke-ArmRest -Method "PUT" -Uri $tableUri -JsonBody $body

        # Wait for provisioning
        for ($i = 0; $i -lt 12; $i++) {
            Start-Sleep -Seconds 5
            try {
                $table = Invoke-ArmRest -Method "GET" -Uri $tableUri
                if ($table.properties.provisioningState -eq "Succeeded") {
                    Write-Host "Custom table '$CustomTableName' created." -ForegroundColor Green
                    return
                }
            } catch { }
        }
        throw "Custom table '$CustomTableName' did not reach Succeeded state."
    }
}

# ---------------------------------------------------------------------------
# Infrastructure: DCR
# ---------------------------------------------------------------------------
function Test-IsBuiltInTable {
    param([string]$Name)
    return (-not $Name.EndsWith("_CL"))
}

function New-DcrTemplate {
    param(
        [string]$TargetTableName,
        [string]$WorkspaceResourceId,
        [string]$DceResourceId,
        [string]$Location,
        [object[]]$ColumnDefinitions,
        [string]$TransformKql
    )

    $isBuiltIn = Test-IsBuiltInTable -Name $TargetTableName

    if ($isBuiltIn) {
        $streamName   = "Custom-$TargetTableName"
        $outputStream = "Microsoft-$TargetTableName"
    } else {
        $baseName     = $TargetTableName.Substring(0, $TargetTableName.Length - 3)
        $streamName   = "Custom-$baseName"
        $outputStream = "Custom-$TargetTableName"
    }

    $columnDefs = @(
        foreach ($col in $ColumnDefinitions) {
            @{ name = $col.name; type = if ($col.type) { $col.type } else { "string" } }
        }
    )
    # Ensure TimeGenerated is present in stream declarations
    $hasTimeGenerated = $columnDefs | Where-Object { $_.name -eq "TimeGenerated" }
    if (-not $hasTimeGenerated) {
        $columnDefs += @{ name = "TimeGenerated"; type = "datetime" }
    }

    $transform = if ($TransformKql) { $TransformKql } else { "source" }

    $template = @{
        location   = $Location
        kind       = "Direct"
        properties = @{
            dataCollectionEndpointId = $DceResourceId
            streamDeclarations       = @{
                $streamName = @{
                    columns = $columnDefs
                }
            }
            destinations = @{
                logAnalytics = @(
                    @{
                        name                = "la"
                        workspaceResourceId = $WorkspaceResourceId
                    }
                )
            }
            dataFlows = @(
                @{
                    streams      = @($streamName)
                    destinations = @("la")
                    transformKql = $transform
                    outputStream = $outputStream
                }
            )
        }
    }

    return @{
        Template   = $template
        StreamName = $streamName
    }
}

function Initialize-Dcr {
    param(
        [string]$DcrName,
        [string]$SubscriptionId,
        [string]$ResourceGroupName,
        [hashtable]$Template
    )

    $apiVersion = "2023-03-11"
    $dcrId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroupName/providers/Microsoft.Insights/dataCollectionRules/$DcrName"
    $dcrUri = "https://management.azure.com${dcrId}?api-version=$apiVersion"

    # Check if DCR already exists
    $existing = $null
    try {
        $existing = Invoke-ArmRest -Method "GET" -Uri $dcrUri
    } catch { }

    if ($existing) {
        Write-Host "Reusing existing DCR '$DcrName'." -ForegroundColor Green
    } else {
        Write-Host "Creating DCR '$DcrName'..." -ForegroundColor Cyan
        $body = $Template | ConvertTo-Json -Depth 20 -Compress
        $null = Invoke-ArmRest -Method "PUT" -Uri $dcrUri -JsonBody $body
        Write-Host "DCR '$DcrName' created." -ForegroundColor Green
    }

    return $dcrId
}

function Get-DcrImmutableId {
    param([string]$DcrId)
    $apiVersion = "2023-03-11"
    $dcr = Invoke-ArmRest -Method "GET" -Uri "https://management.azure.com${DcrId}?api-version=$apiVersion"
    return $dcr.properties.immutableId
}

function Get-DcrIngestionEndpoint {
    param([string]$DcrId)
    $apiVersion = "2023-03-11"
    $dcr = Invoke-ArmRest -Method "GET" -Uri "https://management.azure.com${DcrId}?api-version=$apiVersion"
    if ($dcr.properties.endpoints -and $dcr.properties.endpoints.logsIngestion) {
        return $dcr.properties.endpoints.logsIngestion
    }
    return $null
}

# ---------------------------------------------------------------------------
# Data Generation
# ---------------------------------------------------------------------------
function Read-EntitiesConfig {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Entities config not found: $Path"
    }
    return Get-Content -Path $Path -Raw | ConvertFrom-Json
}

function Read-SchemaFile {
    param([string]$Path)
    if (-not (Test-Path $Path)) {
        throw "Schema file not found: $Path"
    }
    $raw = Get-Content -Path $Path -Raw | ConvertFrom-Json
    # Support both flat array and { columns: [...] } formats
    if ($raw.columns) { return @($raw.columns) }
    return @($raw)
}

function Read-SampleData {
    param([string]$Path)
    if (-not $Path -or -not (Test-Path $Path)) { return $null }
    $extension = [System.IO.Path]::GetExtension($Path).ToLowerInvariant()
    if ($extension -eq ".json") {
        $data = Get-Content -Path $Path -Raw | ConvertFrom-Json
        if ($data -is [System.Array]) { return @($data) }
        return @($data)
    }
    if ($extension -eq ".csv") {
        return @(Import-Csv -Path $Path)
    }
    throw "Unsupported sample data format: $extension (use .json or .csv)"
}

function Get-EntityColumnMapping {
    param([string]$ColumnName)

    $nameLower = $ColumnName.ToLowerInvariant()

    # IP address patterns
    if ($nameLower -match '(ipaddr|ipaddress|sourceip|destip|callerip|clientip|remoteip|srcip|dstip|_ip$|^ip$)') {
        return "ipAddresses"
    }
    # User patterns
    if ($nameLower -match '(username|userid|userupn|accountname|actorname|principalname|userprincipal|initiatedby|caller$|owner$)') {
        return "users"
    }
    # UPN patterns (more specific)
    if ($nameLower -match '(upn|userprincipalname|mail$|email)') {
        return "emailAddresses"
    }
    # Hostname/device patterns
    if ($nameLower -match '(hostname|computername|devicename|machinename|dvcname|workstation|^computer$|^device$|^dvc$|^host$)') {
        return "devices"
    }
    # FQDN patterns
    if ($nameLower -match '(fqdn|fullyqualified)') {
        return "devicesFqdn"
    }
    # URL patterns
    if ($nameLower -match '(^url$|^uri$|requesturl|targeturl|resourceurl|httpurl)') {
        return "urls"
    }
    # Domain patterns
    if ($nameLower -match '(^domain$|domainname|dnsdomain|targetdomain)') {
        return "domains"
    }

    return $null
}

function Get-EntityValue {
    param(
        [string]$EntityType,
        [object]$Entities
    )

    switch ($EntityType) {
        "ipAddresses" {
            $entry = $Entities.ipAddresses | Get-Random
            return $entry.address
        }
        "users" {
            $entry = $Entities.users | Get-Random
            return $entry.username
        }
        "emailAddresses" {
            return ($Entities.emailAddresses | Get-Random)
        }
        "devices" {
            $entry = $Entities.devices | Get-Random
            return $entry.hostname
        }
        "devicesFqdn" {
            $entry = $Entities.devices | Get-Random
            return $entry.fqdn
        }
        "urls" {
            return ($Entities.urls | Get-Random)
        }
        "domains" {
            return ($Entities.domains | Get-Random)
        }
        default { return $null }
    }
}

function New-RandomValueForType {
    param(
        [string]$ColumnType,
        [string]$ColumnName,
        [int]$WindowHours
    )

    $nameLower = $ColumnName.ToLowerInvariant()

    switch ($ColumnType.ToLowerInvariant()) {
        "datetime" {
            $offsetSeconds = Get-Random -Minimum 0 -Maximum ($WindowHours * 3600)
            return (Get-Date).ToUniversalTime().AddSeconds(-$offsetSeconds).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
        }
        { $_ -in @("int", "long") } {
            # Heuristic ranges based on column name
            if ($nameLower -match 'port') { return Get-Random -Minimum 1 -Maximum 65535 }
            if ($nameLower -match 'status|code|response') { return (200, 201, 301, 302, 400, 401, 403, 404, 500, 502, 503 | Get-Random) }
            if ($nameLower -match 'count|total') { return Get-Random -Minimum 1 -Maximum 1000 }
            if ($nameLower -match 'duration|latency|elapsed') { return Get-Random -Minimum 1 -Maximum 30000 }
            if ($nameLower -match 'size|length|bytes') { return Get-Random -Minimum 64 -Maximum 1048576 }
            if ($nameLower -match 'severity|level|priority') { return Get-Random -Minimum 0 -Maximum 5 }
            return Get-Random -Minimum 0 -Maximum 10000
        }
        "real" {
            if ($nameLower -match 'percent|ratio|confidence') {
                return [math]::Round((Get-Random -Minimum 0 -Maximum 10000) / 100.0, 2)
            }
            return [math]::Round((Get-Random -Minimum 0 -Maximum 100000) / 100.0, 2)
        }
        { $_ -in @("bool", "boolean") } {
            return ((Get-Random -Minimum 0 -Maximum 100) -lt 70)
        }
        "dynamic" {
            return @{}
        }
        "guid" {
            return [guid]::NewGuid().ToString()
        }
        default {
            # String — generate contextual value based on column name
            if ($nameLower -match 'result|outcome') {
                return ("Success", "Failure", "Partial", "NA" | Get-Random)
            }
            if ($nameLower -match 'action|operation') {
                return ("Create", "Read", "Update", "Delete", "Execute", "Login", "Logout" | Get-Random)
            }
            if ($nameLower -match 'protocol') {
                return ("TCP", "UDP", "HTTP", "HTTPS", "DNS", "ICMP", "TLS" | Get-Random)
            }
            if ($nameLower -match 'severity') {
                return ("Informational", "Low", "Medium", "High" | Get-Random)
            }
            if ($nameLower -match 'method') {
                return ("GET", "POST", "PUT", "DELETE", "PATCH", "HEAD" | Get-Random)
            }
            if ($nameLower -match 'useragent') {
                return ("Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36",
                        "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)",
                        "curl/8.4.0",
                        "python-requests/2.31.0" | Get-Random)
            }
            if ($nameLower -match 'country|region|geo') {
                return ("US", "GB", "DE", "FR", "JP", "AU", "CA", "BR", "IN", "NL" | Get-Random)
            }
            # Generic string
            $chars = "abcdefghijklmnopqrstuvwxyz0123456789"
            $len = Get-Random -Minimum 8 -Maximum 24
            return -join (1..$len | ForEach-Object { $chars[(Get-Random -Minimum 0 -Maximum $chars.Length)] })
        }
    }
}

function New-SampleRecords {
    param(
        [object[]]$ColumnDefinitions,
        [object]$Entities,
        [int]$Count,
        [int]$WindowHours,
        [object[]]$SampleData
    )

    # Build per-column value pools from sample data
    $samplePools = @{}
    if ($SampleData -and $SampleData.Count -gt 0) {
        foreach ($col in $ColumnDefinitions) {
            $values = @($SampleData | ForEach-Object {
                $val = $_.PSObject.Properties[$col.name]
                if ($val) { $val.Value }
            } | Where-Object { $null -ne $_ -and $_ -ne "" })
            if ($values.Count -gt 0) {
                $samplePools[$col.name] = $values
            }
        }
    }

    $records = @()
    for ($i = 0; $i -lt $Count; $i++) {
        $record = [ordered]@{}

        foreach ($col in $ColumnDefinitions) {
            $colName = $col.name
            $colType = if ($col.type) { $col.type } else { "string" }

            # Priority 1: TimeGenerated always gets a fresh timestamp
            if ($colName -eq "TimeGenerated") {
                $offsetSeconds = Get-Random -Minimum 0 -Maximum ($WindowHours * 3600)
                $record[$colName] = (Get-Date).ToUniversalTime().AddSeconds(-$offsetSeconds).ToString("yyyy-MM-ddTHH:mm:ss.fffZ")
                continue
            }

            # Priority 2: Schema-defined values (enum hints)
            if ($col.PSObject.Properties['values'] -and $col.values.Count -gt 0) {
                $record[$colName] = (Get-Random -InputObject $col.values)
                continue
            }

            # Priority 3: Sample data pool (most realistic)
            if ($samplePools.ContainsKey($colName)) {
                $record[$colName] = ($samplePools[$colName] | Get-Random)
                continue
            }

            # Priority 4: Entity mapping
            $entityType = Get-EntityColumnMapping -ColumnName $colName
            if ($entityType) {
                $entityVal = Get-EntityValue -EntityType $entityType -Entities $Entities
                if ($null -ne $entityVal) {
                    $record[$colName] = $entityVal
                    continue
                }
            }

            # Priority 5: Type-based random generation
            $record[$colName] = New-RandomValueForType -ColumnType $colType -ColumnName $colName -WindowHours $WindowHours
        }

        $records += [pscustomobject]$record
    }

    return $records
}

# ---------------------------------------------------------------------------
# Ingestion
# ---------------------------------------------------------------------------
function Get-JsonByteCount {
    param([string]$Json)
    return [System.Text.Encoding]::UTF8.GetByteCount($Json)
}

function Split-RecordsBySize {
    param(
        [array]$Records,
        [int]$MaxBytes = 900000
    )

    $current = @()
    $currentSize = 2  # []

    foreach ($record in $Records) {
        $recordJson = $record | ConvertTo-Json -Depth 20 -Compress
        $recordSize = (Get-JsonByteCount -Json $recordJson) + 1

        if (($currentSize + $recordSize) -gt $MaxBytes -and $current.Count -gt 0) {
            , $current
            $current = @()
            $currentSize = 2
        }

        $current += $record
        $currentSize += $recordSize
    }

    if ($current.Count -gt 0) {
        , $current
    }
}

function Send-Records {
    param(
        [string]$IngestionEndpoint,
        [string]$ImmutableId,
        [string]$StreamName,
        [array]$Records,
        [string]$AccessToken
    )

    if (-not $Records -or $Records.Count -eq 0) {
        Write-Host "No records to send." -ForegroundColor Yellow
        return
    }

    $apiVersion = "2023-01-01"
    $uri = "$IngestionEndpoint/dataCollectionRules/$ImmutableId/streams/${StreamName}?api-version=$apiVersion"
    $headers = @{
        Authorization  = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }

    $batches = @(Split-RecordsBySize -Records $Records)
    $totalSent = 0

    foreach ($batch in $batches) {
        $payload = $batch | ConvertTo-Json -Depth 20 -Compress
        # Ensure payload is always a JSON array
        if (-not $payload.StartsWith("[")) {
            $payload = "[$payload]"
        }

        $attempt = 0
        $maxAttempts = 4
        while ($true) {
            try {
                $clientRequestId = [guid]::NewGuid().ToString()
                $headers["x-ms-client-request-id"] = $clientRequestId
                $null = Invoke-RestMethod -Method Post -Uri $uri -Headers $headers -Body $payload
                $totalSent += $batch.Count
                break
            } catch {
                $exception = $_.Exception
                $statusCode = $null
                $responseBody = $null
                $retryAfterSeconds = $null

                if ($exception.Response) {
                    try { $statusCode = [int]$exception.Response.StatusCode } catch { }
                    try {
                        $reader = New-Object System.IO.StreamReader($exception.Response.GetResponseStream())
                        $responseBody = $reader.ReadToEnd()
                    } catch { }
                    try {
                        $retryAfterHeader = $exception.Response.Headers["Retry-After"]
                        if ($retryAfterHeader) {
                            [int]::TryParse($retryAfterHeader, [ref]$retryAfterSeconds) | Out-Null
                        }
                    } catch { }
                }

                $isInvalidStream = ($responseBody -and $responseBody -match "InvalidStream") -or ($exception.Message -match "InvalidStream")
                $isTransportError = $exception.Message -match "forcibly closed|underlying connection|transport connection|connection was closed"
                $isRetryable = ($statusCode -in @(429, 500, 502, 503, 504)) -or $isTransportError

                if (($isInvalidStream -or $isRetryable) -and $attempt -lt ($maxAttempts - 1)) {
                    $attempt++
                    $delaySeconds = if ($retryAfterSeconds -and $retryAfterSeconds -gt 0) { $retryAfterSeconds } else { [math]::Min(30, [math]::Pow(2, $attempt)) }
                    if ($isInvalidStream) {
                        Write-Host "InvalidStream — waiting for DCR propagation (attempt $attempt/$maxAttempts)..." -ForegroundColor Yellow
                    } else {
                        Write-Host "Transient error (status $statusCode). Retrying in $delaySeconds s (attempt $attempt/$maxAttempts)..." -ForegroundColor Yellow
                    }
                    Start-Sleep -Seconds $delaySeconds
                    continue
                }

                Write-Host "Ingestion failed: $($exception.Message)" -ForegroundColor Red
                if ($responseBody) { Write-Host "Response: $responseBody" -ForegroundColor Red }
                throw
            }
        }
    }

    Write-Host "Successfully ingested $totalSent records in $($batches.Count) batch(es)." -ForegroundColor Green
}

# ═══════════════════════════════════════════════════════════════════════════
# MAIN ORCHESTRATION
# ═══════════════════════════════════════════════════════════════════════════

Assert-AzCli | Out-Null

# --- Read configuration ---
$ws = Read-WorkspaceConfig -ConfigPath $WorkspaceConfig
Write-Host "Workspace: $($ws.WorkspaceName) (subscription $($ws.SubscriptionId))" -ForegroundColor Cyan

$entities = Read-EntitiesConfig -Path $EntitiesFile
Write-Host "Loaded entity pools: $($entities.users.Count) users, $($entities.ipAddresses.Count) IPs, $($entities.devices.Count) devices" -ForegroundColor Cyan

# --- Read schema ---
if (-not $Schema -and -not $SampleDataFile) {
    throw "Provide -Schema (column definitions JSON) or -SampleDataFile (sample rows to infer schema from)."
}

$columnDefs = $null
$sampleData = $null

if ($Schema) {
    $columnDefs = Read-SchemaFile -Path $Schema
    Write-Host "Loaded schema: $($columnDefs.Count) columns from $Schema" -ForegroundColor Cyan
}

if ($SampleDataFile) {
    $sampleData = Read-SampleData -Path $SampleDataFile
    Write-Host "Loaded $($sampleData.Count) sample rows from $SampleDataFile" -ForegroundColor Cyan

    # Infer schema from sample data if no explicit schema provided
    if (-not $columnDefs -and $sampleData.Count -gt 0) {
        $columnDefs = @()
        foreach ($prop in $sampleData[0].PSObject.Properties) {
            $inferredType = "string"
            $val = $prop.Value
            if ($val -is [bool]) { $inferredType = "boolean" }
            elseif ($val -is [int] -or $val -is [long]) { $inferredType = "long" }
            elseif ($val -is [double] -or $val -is [decimal]) { $inferredType = "real" }
            elseif ($val -is [datetime]) { $inferredType = "datetime" }
            elseif ($val -is [hashtable] -or $val -is [pscustomobject] -or $val -is [System.Array]) { $inferredType = "dynamic" }
            $columnDefs += @{ name = $prop.Name; type = $inferredType }
        }
        Write-Host "Inferred schema from sample data: $($columnDefs.Count) columns" -ForegroundColor Cyan
    }
}

if (-not $columnDefs) {
    throw "Could not determine column definitions. Provide -Schema or -SampleDataFile."
}

$isBuiltIn = Test-IsBuiltInTable -Name $TableName

# Variables shared between Deploy and Ingest phases
$immutableId       = $null
$ingestionEndpoint = $null
$streamName        = $null

# --- Deploy infrastructure ---
if ($Deploy) {
    Write-Host "`n--- Deploying infrastructure ---" -ForegroundColor Magenta

    $location = Resolve-WorkspaceLocation -WorkspaceResourceId $ws.WorkspaceResourceId
    Write-Host "Workspace location: $location" -ForegroundColor Cyan

    # 1. DCE
    $dce = Initialize-Dce -SubscriptionId $ws.SubscriptionId -ResourceGroupName $ws.ResourceGroup -Location $location -DceName $ws.DceName
    $dceId = $dce.id
    $ingestionEndpoint = $dce.properties.logsIngestion.endpoint

    # 2. Custom table (only for _CL tables)
    if (-not $isBuiltIn) {
        Initialize-CustomTable -WorkspaceResourceId $ws.WorkspaceResourceId -CustomTableName $TableName -ColumnDefinitions $columnDefs
    }

    # 3. DCR
    $dcrName = "sampledata-$($TableName -replace '_CL$', '' -replace '[^A-Za-z0-9-]', '-')"
    $dcrResult = New-DcrTemplate -TargetTableName $TableName -WorkspaceResourceId $ws.WorkspaceResourceId `
        -DceResourceId $dceId -Location $location -ColumnDefinitions $columnDefs
    $dcrId = Initialize-Dcr -DcrName $dcrName -SubscriptionId $ws.SubscriptionId `
        -ResourceGroupName $ws.ResourceGroup -Template $dcrResult.Template
    $streamName = $dcrResult.StreamName

    $immutableId = Get-DcrImmutableId -DcrId $dcrId

    Write-Host "`nInfrastructure ready:" -ForegroundColor Green
    Write-Host "  DCE endpoint : $ingestionEndpoint"
    Write-Host "  DCR name     : $dcrName"
    Write-Host "  DCR immutable: $immutableId"
    Write-Host "  Stream       : $streamName"
    Write-Host "  Table        : $TableName"

    # RBAC reminder
    Write-Host "`n[RBAC] Ensure you have 'Monitoring Metrics Publisher' role on the DCR:" -ForegroundColor Yellow
    Write-Host "  az role assignment create --role 'Monitoring Metrics Publisher' ``" -ForegroundColor Yellow
    Write-Host "    --assignee `"`$(az ad signed-in-user show --query id -o tsv)`" ``" -ForegroundColor Yellow
    Write-Host "    --scope '$dcrId'" -ForegroundColor Yellow

    # Save deployment info for subsequent -Ingest runs
    $deploymentInfo = @{
        dceEndpoint   = $ingestionEndpoint
        dcrId         = $dcrId
        immutableId   = $immutableId
        streamName    = $streamName
        tableName     = $TableName
    }
    $deployInfoPath = Join-Path $basePath "schemas" "$($TableName).deploy.json"
    $deployInfoDir = Split-Path $deployInfoPath -Parent
    if (-not (Test-Path $deployInfoDir)) {
        New-Item -ItemType Directory -Path $deployInfoDir -Force | Out-Null
    }
    $deploymentInfo | ConvertTo-Json -Depth 5 | Out-File -FilePath $deployInfoPath -Encoding utf8
    Write-Host "Deployment info saved to: $deployInfoPath" -ForegroundColor Cyan
}

# --- Ingest data ---
if ($Ingest) {
    Write-Host "`n--- Generating and ingesting sample data ---" -ForegroundColor Magenta

    # Load deployment info if not already in memory
    if (-not $immutableId -or -not $ingestionEndpoint -or -not $streamName) {
        $deployInfoPath = Join-Path $basePath "schemas" "$($TableName).deploy.json"
        if (-not (Test-Path $deployInfoPath)) {
            throw "No deployment info found for '$TableName'. Run with -Deploy first, or provide deployment info."
        }
        $deployInfo = Get-Content -Path $deployInfoPath -Raw | ConvertFrom-Json
        $ingestionEndpoint = $deployInfo.dceEndpoint
        $immutableId       = $deployInfo.immutableId
        $streamName        = $deployInfo.streamName
    }

    # Get access token
    $token = Get-AccessToken -TokenTenantId $TenantId -TokenClientId $ClientId -TokenClientSecret $ClientSecret
    Write-Host "Access token acquired." -ForegroundColor Green

    # Generate sample records
    Write-Host "Generating $RowCount sample records..." -ForegroundColor Cyan
    $records = New-SampleRecords -ColumnDefinitions $columnDefs -Entities $entities `
        -Count $RowCount -WindowHours $TimeWindowHours -SampleData $sampleData
    Write-Host "Generated $($records.Count) records." -ForegroundColor Green

    # Send to Log Ingestion API
    Write-Host "Ingesting into '$TableName' via stream '$streamName'..." -ForegroundColor Cyan
    Send-Records -IngestionEndpoint $ingestionEndpoint -ImmutableId $immutableId `
        -StreamName $streamName -Records $records -AccessToken $token

    Write-Host "`nData ingestion complete. It may take 5-10 minutes for data to appear in Log Analytics." -ForegroundColor Green
    Write-Host "Verify with: az monitor log-analytics query --workspace $($ws.WorkspaceId) --analytics-query `"$TableName | where TimeGenerated > ago(30m) | take 10`"" -ForegroundColor Cyan
}

if (-not $Deploy -and -not $Ingest) {
    Write-Host "No action specified. Use -Deploy, -Ingest, or both." -ForegroundColor Yellow
}

Write-Host "`nDone." -ForegroundColor Green
