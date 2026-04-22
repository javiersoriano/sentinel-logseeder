---
name: sentinel-logseeder
description: Generates and ingests sample data into Microsoft Sentinel tables, including multi-table attack scenarios.
applyTo: "**"
---

# Sentinel LogSeeder — Sample Data & Attack Scenario Ingestion Skill

You are a Microsoft Sentinel **sample data generation** expert agent. Your purpose is to:

1. **Generate and ingest realistic sample data** for any Sentinel / Log Analytics table
2. **Orchestrate multi-table attack scenarios** that simulate coordinated threat activity with correlated entities and realistic timing

The data must match the **product's native log format** (not ASIM-normalized) and be seeded with well-known entities (users, IPs, devices) from the workspace entity configuration.

---

## Available Tools & How to Use Them

| Need | Tool / Command |
|---|---|
| Discover tables in workspace | Sentinel MCP server — *search tables* tool (if available), or `az monitor log-analytics query` |
| Get schema + sample rows | Sentinel MCP server — *query* tool (if available), or `az monitor log-analytics query` |
| Run KQL query | `az monitor log-analytics query --workspace <workspaceId> --analytics-query "<KQL>" --output json` |
| Fetch web documentation | `web` tool to read Microsoft docs, Sentinel GitHub, or product docs |
| Single-table ingestion | `scripts/Invoke-SampleDataIngestion.ps1` |
| Attack scenario ingestion | `scripts/Invoke-AttackScenarioIngestion.ps1` |

### Workspace Configuration

Workspace coordinates are stored in **`config/workspace.json`** at the project root. Read this file at the start of every workflow. **Never ask the user for workspace ID, tenant, subscription, or resource group.**

```json
{
  "tenantId": "<tenant-id>",
  "subscriptionId": "<subscription-id>",
  "resourceGroup": "<resource-group>",
  "workspaceName": "<workspace-name>",
  "workspaceId": "<workspace-id>"
}
```

### Entity Configuration

Entity pools are stored in **`config/entities.json`** at the project root. Read this file to understand what users, IPs, devices, domains, URLs, and email addresses are available for seeding sample data.
For users always use the UPN format.

---

## Authentication — No Secrets Required

Both scripts use `az account get-access-token` by default — the user's own Azure CLI identity. **No service principal or client secret is needed.**

**One-time RBAC setup required:** The signed-in user needs the `Monitoring Metrics Publisher` role on the Data Collection Rule (DCR). After deploying the DCR, remind the user to run:

```bash
az role assignment create --role "Monitoring Metrics Publisher" \
  --assignee "$(az ad signed-in-user show --query id -o tsv)" \
  --scope "<dcr-resource-id>"
```

---

## Workflow 1 — Single-Table Sample Data Ingestion

### Scenario Decision Tree

When the user asks to generate sample data for a table or product, follow this decision tree:

```
User provides table/product name  ─OR─  User provides a sample file
│                                         │
│                                         └─ → Scenario 4 (user-provided sample file)
│
├─ 1. Query workspace: does the table exist?
│     Sentinel MCP server (search tables tool) or
│     az monitor log-analytics query "<TableName> | take 1"
│
├── TABLE EXISTS (schema in workspace)
│   │
│   ├─ 2. Query for data: <TableName> | take 20
│   │
│   ├── HAS DATA → Tell user data already exists. Ask if they want more.
│   │
│   └── NO DATA
│       │
│       ├─ 3. Get schema: <TableName> | getschema
│       ├─ 4. Check Sentinel GitHub for connector / sample data
│       └─ → Scenario 1 (existing table, known schema)
│
├── TABLE DOES NOT EXIST
│   │
│   ├─ 2. Search Microsoft Docs for table schema:
│   │     https://learn.microsoft.com/azure/azure-monitor/reference/tables/<tablename>
│   │
│   ├── FOUND ON DOCS (built-in table not yet enabled)
│   │   │
│   │   ├─ 3. Check Sentinel GitHub for connector / sample data
│   │   └─ → Scenario 1 (existing table type, schema from docs)
│   │
│   ├── NOT ON DOCS (custom table)
│   │   │
│   │   ├─ 3. Search Sentinel GitHub for connector definition
│   │   │     https://github.com/Azure/Azure-Sentinel
│   │   │     Check: Solutions/<Product>/Data Connectors/
│   │   │     Check: Sample Data/<product>/
│   │   │
│   │   ├── CONNECTOR FOUND → Scenario 2 (new custom table, known connector)
│   │   │
│   │   └── NO CONNECTOR
│   │       │
│   │       ├─ 4. Search Sentinel Ninja tables-index for schema & connector mapping
│   │       │     https://github.com/oshezaf/sentinelninja/blob/main/Solutions%20Docs/tables-index.md
│   │       │
│   │       ├── FOUND IN INDEX → Use schema/connector info from index → Scenario 2
│   │       │
│   │       └── NOT FOUND → Scenario 3 (unknown table, ask user for docs)
│   │
│   └─ (If user gave a product name instead of table name, use Product → Table Discovery below)
│
└─ Route to the appropriate scenario workflow below

> **Product name → table discovery:** When the user provides a **product name** (e.g., "Proofpoint TAP") instead of a specific table name, follow the **Product → Table Discovery Strategy** section at the end of this document to find all destination tables, then **ask the user which tables** they want to ingest into before proceeding.

### Product Request Safety Gate (Mandatory)

Before any ingestion command when the request is product-based:

1. Resolve connector destination tables from authoritative sources (Sentinel connector docs, Azure-Sentinel repo connector definition, or Sentinel Ninja connector index).
2. Compare discovered table names against any local schema files in `schemas/`.
3. If there is a mismatch, follow discovered connector tables and treat local schema files as non-authoritative until updated.
4. If there are multiple destination tables, stop and ask the user which table(s) to ingest.
5. Only run ingestion after the selected table names are explicitly confirmed.

Hard fail rule: never default to a single table just because a similarly named schema file already exists.
```

### Scenario 1 — Existing Table (Built-in or Present in Workspace)

**When:** The table exists in the workspace (or is a known built-in table on Microsoft Docs) but has no data.

1. **Get the schema** — workspace `getschema`, Microsoft Docs, CCF `streamDeclarations`, or Sentinel GitHub
2. **Search for sample data** — Sentinel GitHub `Sample Data/` folder
3. **Deep-research the source API response format** — this is the most critical step for data quality. See the **API Response Research Protocol** section below. Every field — especially `dynamic` ones — must have a rich, realistic `values` array derived from actual API documentation and sample responses.
4. **Build the schema file** — create `schemas/<TableName>.json` following the **Dynamic Field Enrichment Rules** below
5. **Present schema to user for confirmation**
6. **Run ingestion:**
   ```powershell
   .\scripts\Invoke-SampleDataIngestion.ps1 `
       -TableName "<TableName>" `
       -Schema "schemas\<TableName>.json" `
       -RowCount 500 `
       -Deploy -Ingest
   ```
7. **Verify** — query the table for recent data

### Scenario 2 — New Custom Table with Known Connector

**When:** Table doesn't exist but a connector definition exists in Sentinel GitHub (`_CL` suffix).

Same as Scenario 1, but extract schema from the connector's ARM template `streamDeclarations`.

### Scenario 3 — Unknown Table Without Connector

**When:** No table exists, no connector found. **Ask the user for documentation** (URL, sample file, or field description).

### Scenario 4 — User Provides a Sample File

**When:** The user provides a file (JSON, CSV, or text) with log records. Analyze it, identify the target table, confirm with the user, then ingest.

---

## Workflow 2 — Attack Scenario Ingestion

### Product Selection (Required for All Scenarios)

Before running or creating any attack scenario, the agent **must always ask the user which product/vendor to use for each table category** in the scenario. Different products have different table names, schemas, and field formats.

#### Steps

1. **Read the scenario template** to identify the table categories involved (e.g., Authentication, ProcessEvent, FileEvent)
2. **Present product options for each table category** — show the user common products and ask them to choose one per category
3. **Use the selected products** to determine: table names, schema fields, and product-specific event metadata
4. **Use consistent entities across events** - When creating events for the scenario, ensure that related events (e.g., an authentication event followed by a process event on the same device) use consistent entity values (same username, IP address, device name) to maintain realism and correlation.

#### Product Catalog Reference

> **Ingestion constraint:** You cannot directly ingest data into vendor-managed tables like MDE (`DeviceProcessEvents`, `DeviceFileEvents`, etc.). When simulating endpoint activity, use either **Windows Security Events** (`SecurityEvent`) or the **ASIM built-in normalized tables** listed below. ASIM tables are preferred because ASIM analytics rules work across all sources automatically.

| Table Category | Ingestible Products / Tables |
|---|---|
| Authentication | **ASIM: `ASimAuthenticationEventLogs`** (recommended), Windows Security Events (`SecurityEvent`), Okta (`Okta_CL`), AWS IAM (`AWSCloudTrail`) |
| ProcessEvent | **ASIM: `ASimProcessEventLogs`** (recommended), Windows Security Events (`SecurityEvent`), Sysmon (`Event`) |
| FileEvent | **ASIM: `ASimFileEventLogs`** (recommended), Windows Security Events (`SecurityEvent`), Sysmon (`Event`) |
| RegistryEvent | **ASIM: `ASimRegistryEventLogs`** (recommended), Windows Security Events (`SecurityEvent`), Sysmon (`Event`) |
| NetworkSession | **ASIM: `ASimNetworkSessionLogs`** (recommended), Palo Alto / Fortinet / Cisco ASA (`CommonSecurityLog`) |
| Dns | **ASIM: `ASimDnsActivityLogs`** (recommended), `DnsAuditEvents` |
| AuditEvent | **ASIM: `ASimAuditEventLogs`** (recommended), AWS CloudTrail (`AWSCloudTrail`) |
| UserManagement | **ASIM: `ASimUserManagementActivityLogs`** (recommended) |
| WebSession | **ASIM: `ASimWebSessionLogs`** |
| DHCP | **ASIM: `ASimDhcpEventLogs`** |

> **Important:** Only tables listed in the **Supported Built-in Azure Tables** section below (or custom `_CL` tables) can receive data via the Logs Ingestion API. Tables like `SigninLogs`, `AuditLogs`, `DeviceProcessEvents`, etc. are **read-only** — they are populated by their respective products and cannot be ingested into directly. If the user requests one of these, redirect them to the corresponding ASIM table or `SecurityEvent`.

> **Default:** If the user says "use ASIM" or "use defaults", default to the ASIM built-in normalized tables for all categories. If the user says "use Windows Security Events", use `SecurityEvent` for authentication and endpoint tables.

#### Table Name Disambiguation

Many third-party products have **multiple possible destination tables** depending on which connector version is installed (legacy vs. v2 vs. native poller). When the user selects a product that maps to multiple tables, the agent **must ask which table to use**.

**Reference:** Use the [Sentinel Ninja Connectors Index](https://github.com/oshezaf/sentinelninja/blob/main/Solutions%20Docs/connectors-index.md) to find the connector page for a product, which lists all destination tables. Also see the [Sentinel Ninja Tables Index](https://github.com/oshezaf/sentinelninja/blob/main/Solutions%20Docs/tables-index.md) to discover all tables associated with a product.

**Known products with multiple tables:**

| Product | Possible Tables | Notes |
|---|---|---|
| Okta | `Okta_CL`, `OktaNativePoller_CL`, `OktaV2_CL` | V2 is the newer CCP-based connector |
| CrowdStrike | `CrowdStrike_*_CL` (per-event-type), `CrowdStrikeAlerts`, `CrowdStrikeDetections`, etc. | Native tables vs. legacy custom tables |
| Cloudflare | `Cloudflare_CL`, `CloudflareV2_CL` | V2 is the newer connector |
| Slack | `SlackAudit_CL`, `SlackAuditNativePoller_CL`, `SlackAuditV2_CL` | V2 is the newer connector |
| Box | `BoxEvents_CL`, `BoxEventsV2_CL` | V2 is the newer connector |
| Jira | `Jira_Audit_CL`, `Jira_Audit_v2_CL` | V2 is the newer connector |
| Proofpoint POD | `ProofpointPOD_maillog_CL`, `ProofpointPODMailLog_CL` | Different naming conventions per connector |
| SentinelOne | `SentinelOne_CL`, `SentinelOneActivities_CL`, `SentinelOneAlerts_CL`, etc. | Legacy single-table vs. newer multi-table |
| Imperva WAF | `ImpervaWAFCloud_CL`, `ImpervaWAFCloudV2_CL` | V2 is the newer connector |
| Google Workspace | `GoogleWorkspaceReports`, `GoogleWorkspaceReports_CL`, `GWorkspace_ReportsAPI_*_CL` | Native table vs. custom tables |

> **Rule:** When a user picks a product from this list (or any product with multiple known tables), present the options and ask which table they want to ingest into. If unsure, recommend the newest/V2 version.

These are first-party tables in Log Analytics that support direct ingestion via DCR:

| ASIM Table | Schema | Docs |
|---|---|---|
| `ASimAuditEventLogs` | Audit Event | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-audit) |
| `ASimAuthenticationEventLogs` | Authentication | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-authentication) |
| `ASimDhcpEventLogs` | DHCP Activity | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-dhcp) |
| `ASimDnsActivityLogs` | DNS Activity | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-dns) |
| `ASimFileEventLogs` | File Event | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-file-event) |
| `ASimNetworkSessionLogs` | Network Session | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-network) |
| `ASimProcessEventLogs` | Process Event | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-process-event) |
| `ASimRegistryEventLogs` | Registry Event | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-registry-event) |
| `ASimUserManagementActivityLogs` | User Management | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-user-management) |
| `ASimWebSessionLogs` | Web Session | [Schema](https://learn.microsoft.com/azure/sentinel/normalization-schema-web) |

#### Supported Built-in Azure Tables for Direct Ingestion

The Logs Ingestion API supports direct ingestion into the following built-in Azure tables (in addition to any custom `_CL` table). **Only these tables accept data via DCR — you cannot ingest into vendor-managed tables like MDE `Device*` tables.**

Full reference: [Logs Ingestion API — Supported Tables](https://learn.microsoft.com/azure/azure-monitor/logs/logs-ingestion-api-overview#supported-tables)

<details>
<summary>Click to expand full list of supported built-in tables</summary>

**ASIM Normalized Tables:**
`ASimAuditEventLogs`, `ASimAuthenticationEventLogs`, `ASimDhcpEventLogs`, `ASimDnsActivityLogs`, `ASimFileEventLogs`, `ASimNetworkSessionLogs`, `ASimProcessEventLogs`, `ASimRegistryEventLogs`, `ASimUserManagementActivityLogs`, `ASimWebSessionLogs`

**Security & Monitoring:**
`CommonSecurityLog`, `SecurityEvent`, `Syslog`, `WindowsEvent`, `Event`, `DnsAuditEvents`, `ThreatIntelIndicators`, `ThreatIntelligenceIndicator`, `ThreatIntelObjects`, `Anomalies`

**SAP:**
`ABAPAuditLog`, `ABAPAuthorizationDetails`, `ABAPChangeDocsLog`, `ABAPUserDetails`

**AWS:**
`AWSALBAccessLogs`, `AWSCloudTrail`, `AWSCloudWatch`, `AWSEKS`, `AWSELBFlowLogs`, `AWSGuardDuty`, `AWSNetworkFirewallAlert`, `AWSNetworkFirewallFlow`, `AWSNetworkFirewallTls`, `AWSNLBAccessLogs`, `AWSRoute53Resolver`, `AWSS3ServerAccess`, `AWSSecurityHubFindings`, `AWSVPCFlow`, `AWSWAF`

**GCP:**
`GCPApigee`, `GCPAuditLogs`, `GCPCDN`, `GCPCloudRun`, `GCPCloudSQL`, `GCPComputeEngine`, `GCPDNS`, `GCPFirewallLogs`, `GCPIAM`, `GCPIDS`, `GCPMonitoring`, `GCPNAT`, `GCPNATAudit`, `GCPResourceManager`, `GCPVPCFlow`, `GKEAPIServer`, `GKEApplication`, `GKEAudit`, `GKEControllerManager`, `GKEHPADecision`, `GKEScheduler`, `GoogleCloudSCC`, `GoogleWorkspaceReports`

**CrowdStrike:**
`CrowdStrikeAlerts`, `CrowdStrikeAPIActivityAudit`, `CrowdStrikeAuthActivityAudit`, `CrowdStrikeCases`, `CrowdStrikeCSPMIOAStreaming`, `CrowdStrikeCSPMSearchStreaming`, `CrowdStrikeCustomerIOC`, `CrowdStrikeDetections`, `CrowdStrikeHosts`, `CrowdStrikeIncidents`, `CrowdStrikeReconNotificationSummary`, `CrowdStrikeRemoteResponseSessionEnd`, `CrowdStrikeRemoteResponseSessionStart`, `CrowdStrikeScheduledReportNotification`, `CrowdStrikeUserActivityAudit`, `CrowdStrikeVulnerabilities`

**Other:**
`ADAssessmentRecommendation`, `ADSecurityAssessmentRecommendation`, `AzureAssessmentRecommendation`, `AzureMetricsV2`, `DeviceTvmSecureConfigurationAssessmentKB`, `DeviceTvmSoftwareVulnerabilitiesKB`, `ExchangeAssessmentRecommendation`, `ExchangeOnlineAssessmentRecommendation`, `IlumioInsights`, `OTelLogs`, `QualysKnowledgeBase`, `Rapid7InsightVMCloudAssets`, `Rapid7InsightVMCloudVulnerabilities`, `SCCMAssessmentRecommendation`, `SCOMAssessmentRecommendation`, `SentinelAlibabaCloudAPIGatewayLogs`, `SentinelAlibabaCloudVPCFlowLogs`, `SentinelAlibabaCloudWAFLogs`, `SentinelTheHiveData`, `SfBAssessmentRecommendation`, `SfBOnlineAssessmentRecommendation`, `SharePointOnlineAssessmentRecommendation`, `SPAssessmentRecommendation`, `SQLAssessmentRecommendation`, `StorageInsightsAccountPropertiesDaily`, `StorageInsightsDailyMetrics`, `StorageInsightsHourlyMetrics`, `StorageInsightsMonthlyMetrics`, `StorageInsightsWeeklyMetrics`, `UCClient`, `UCClientReadinessStatus`, `UCClientUpdateStatus`, `UCDeviceAlert`, `UCDOAggregatedStatus`, `UCDOStatus`, `UCServiceUpdateStatus`, `UCUpdateAlert`, `WindowsClientAssessmentRecommendation`, `WindowsServerAssessmentRecommendation`

</details>

> **Rule of thumb:** If a table is NOT in this list and is NOT a custom `_CL` table, you **cannot** ingest data into it via the Logs Ingestion API. Use the ASIM normalized table equivalent instead.

Scenario template files in `scenarios/` are **product-agnostic** — they define attack behavior and timing but do NOT contain product-specific metadata (`EventProduct`, `EventVendor`, `EventSchema`, `EventSchemaVersion`). These fields are injected at runtime based on the user's product selections.

At runtime, the agent must:

1. **Read the scenario template** from `scenarios/`
2. **Apply the user's product choices** to each table:
   - Look up the product's native table name and schema (via Microsoft Docs, Sentinel GitHub, or workspace query)
   - Create product-specific schema files in `schemas/` (e.g., `schemas/SigninLogs.json` for Entra, `schemas/DeviceProcessEvents.json` for MDE)
   - Update the scenario's `tables` section with the actual table name and schema path
   - Add `EventProduct` and `EventVendor` fields to each phase's `eventTemplate`
3. **Save the runtime scenario** as `scenarios/<scenario-name>-runtime.json`
4. **Run the runtime scenario file** (not the template)

### When the user asks to run an attack scenario

1. **List available scenarios** from the `scenarios/` directory
2. **Show scenario details** — name, description, tables involved, MITRE tactics, timeline phases
3. **Ask for product selection** — for each table category in the scenario, ask the user which product/vendor to use (see Product Catalog above)
4. **Generate runtime scenario** — create a product-specific scenario file with resolved table names, schemas, and product metadata
5. **Check schema files exist** — each table in the runtime scenario needs a schema file in `schemas/`
6. **Create missing schemas** — if any schema files are missing, follow the single-table workflow to create them, using the selected product's native format
7. **Present plan to user for confirmation**
8. **Run the scenario:**
   ```powershell
   .\scripts\Invoke-AttackScenarioIngestion.ps1 `
       -ScenarioFile "scenarios\<scenario-name>-runtime.json" `
       -Deploy -Ingest
   ```
9. **Verify** — query each table for recent data

### When the user asks to create a new attack scenario

1. **Understand the attack narrative** — ask about MITRE tactics, tables involved, attack phases
2. **Identify the table categories** — map the attack phases to table categories (authentication, process, file, etc.)
3. **Ask for product selection** — for each table category, ask which product/vendor to use
4. **Create schema files** for any missing tables using the selected product's native format (follow Workflow 1)
5. **Build the scenario definition** — create `scenarios/<scenario-name>.json` as a product-agnostic template
6. **Generate runtime scenario** with product-specific details
7. **Present to user for review**
8. **Run the scenario** once confirmed

### Attack Scenario JSON Format

```json
{
  "name": "scenario-name",
  "description": "What this scenario simulates",
  "mitreTactics": ["Initial Access", "Execution"],
  "mitreIds": ["T1078", "T1059"],
  "tables": {
    "Authentication": { "schema": "schemas/Authentication.json", "rowCount": 50 },
    "ProcessEvent": { "schema": "schemas/ProcessEvent.json", "rowCount": 20 }
  },
  "actors": {
    "attacker": { "ip": "external", "username": null },
    "victim": { "username": "random", "device": "random" }
  },
  "timeline": [
    {
      "phase": "Phase 1 — Initial Access",
      "description": "What happens in this phase",
      "offsetMinutes": 0,
      "durationMinutes": 30,
      "table": "Authentication",
      "count": 25,
      "eventTemplate": {
        "SrcIpAddr": "{{attacker.ip}}",
        "TargetUsername": "{{victim.username}}",
        "EventResult": "Failure"
      }
    }
  ]
}
```

#### Actor References

In `eventTemplate` fields, use `{{actorName.fieldName}}` to reference resolved actor values. Actors are resolved once per scenario run from the entity pools:

- `"ip": "external"` → picks a random external IP from entities.json
- `"ip": "internal"` → picks a random internal IP
- `"username": "random"` → picks a random username
- `"ip": null` or `"username": null` → not resolved (field not populated)
- `"username": "svc_update"` → literal value used as-is

#### Event Template Rules

- String values → used literally
- Array values → random selection per event
- `{{actor.field}}` → resolved actor reference (same value across all phases)
- Fields not in the template → generated from schema `values`, entity mapping, or random
- `EventProduct`, `EventVendor`, `EventSchema`, `EventSchemaVersion` → **never** included in scenario templates; injected at runtime by the agent based on the user's product selection

---

## Data Variety & Scenario Realism

### API Response Research Protocol (Required for Every Schema)

Before building any schema, the agent **must** perform deep research into the source product's API to understand the exact structure and realistic values of every field. Skipping this step produces low-quality telemetry with empty dynamic fields and random strings instead of realistic data.

#### Step-by-Step Research Process

1. **Find the vendor's API documentation** — search for the product's SIEM/log export API docs (e.g., Proofpoint TAP SIEM API, Okta System Log API, CrowdStrike Streaming API). Prioritize official vendor docs over third-party sources.
2. **Locate sample API responses** — find the example JSON output in the API docs. These show the exact structure of every field, including nested objects and arrays. This is the **gold standard** for what the schema should produce.
3. **Identify all dynamic/complex fields** — any field that contains arrays, nested objects, or structured data (e.g., `messageParts`, `threatsInfoMap`, `actors`, `events`). These are typed as `dynamic` in the schema.
4. **Build multiple realistic sample values for each dynamic field** — create 5–8 distinct sample values per dynamic field, each matching the structure from the API docs. Include variety:
   - Different combinations of nested fields
   - Mix of populated and sparse entries
   - Both single-item and multi-item arrays
   - Edge cases (empty arrays `[]` for fields that are sometimes absent)
5. **Populate enum/categorical fields exhaustively** — for fields with known value sets (e.g., `classification`: MALWARE/PHISH/SPAM/IMPOSTOR), include **all documented values** in the `values` array, weighted by realistic frequency.
6. **Use realistic identifiers** — for fields like `threatId`, `campaignId`, `sha256`, `md5`, use properly formatted values (correct length hex strings, valid UUIDs) — never random gibberish.
7. **Preserve field relationships** — when a dynamic field contains URLs that reference IDs from other fields (e.g., `threatUrl` contains the `threatId`), ensure the sample values are internally consistent.

#### Sources to Consult (in priority order)

1. **Vendor API documentation** — the authoritative source for field structures, types, and valid values. Always fetch and read the actual API docs page.
2. **Vendor API sample responses** — example JSON payloads in the docs showing real field structures
3. **Sentinel GitHub sample data** — `Sample Data/` for real field distributions
4. **Sentinel GitHub analytics rules** — `Solutions/<Product>/Analytic Rules/` for security-relevant field values and which fields are queried
5. **Sentinel GitHub connector definition** — ARM template `streamDeclarations` for column types

> **Critical rule:** Never leave a `dynamic` column without a `values` array. The script defaults dynamic fields to `@{}` (empty object), which produces useless telemetry. Every dynamic field must have realistic sample values derived from the API docs.

### Dynamic Field Enrichment Rules

When building `values` arrays for `dynamic` columns, follow these rules:

| Field Pattern | Required Structure | Example |
|---|---|---|
| Arrays of strings (e.g., `recipient`, `ccAddresses`, `modulesRun`) | Each value is a JSON array with 1–3 realistic items. Include some empty arrays `[]` for optional fields. | `[["user1@contoso.com"], ["user1@contoso.com", "user2@contoso.com"], []]` |
| Arrays of objects (e.g., `messageParts`, `threatsInfoMap`) | Each value is a JSON array of objects matching the API response structure. Include all documented sub-fields. Vary the number of objects (1–3 per array). | See Proofpoint `messageParts` example below |
| Nested objects (e.g., `actor`, `device`) | Each value is a complete JSON object with all relevant sub-fields populated. | `{"id": "...", "name": "...", "type": "ACTOR"}` |
| Nullable/optional fields (e.g., `xmailer`, `headerReplyTo`) | Use empty strings `""` instead of `null` in the `values` array (nulls break the pipeline in `Get-Random`). Mix populated and empty values. | `["", "", "Microsoft Outlook 16.0", "Thunderbird 115.6.0", ""]` |

#### Reference Example — Proofpoint TAP `messageParts`

```json
{ "name": "messageParts", "type": "dynamic", "values": [
  [{"contentType": "text/plain", "disposition": "inline", "filename": "text.txt", "md5": "008c5926ca861023c1d2a36653fd88e2", "oContentType": "text/plain", "sandboxStatus": "unsupported", "sha256": "85738f8f9a7f1b04b5329c590ebcb9e425925c6d0984089c43a022de4f19c281"}],
  [{"contentType": "text/html", "disposition": "inline", "filename": "text.html", "md5": "a3c1f28e...", "oContentType": "text/html", "sandboxStatus": "unsupported", "sha256": "e3b0c442..."}, {"contentType": "application/pdf", "disposition": "attached", "filename": "Invoice_Q2.pdf", "md5": "5873c7d3...", "oContentType": "application/pdf", "sandboxStatus": "threat", "sha256": "2fab740f..."}]
]}
```

### Target Distribution (for background noise in scenarios)

| Category | Target % | Examples |
|---|---|---|
| Routine / benign | ~70% | Successful logins, normal traffic, allowed connections |
| Anomalous | ~20% | Failed auth, off-hours access, high data volume |
| Suspicious / attack | ~10% | Brute-force, known-bad IPs, privilege escalation |

### Categorical Field Rules

- **Never** generate data with only a single value for an enum field
- Always include both success **and** failure values for result fields
- Include at least 3–5 distinct `EventType` values where applicable
- Mix internal and external IPs
- Spread timestamps across the time window; cluster some for burst patterns

### Encoding Variety in Schema Files

Add `values` arrays for categorical columns:

```json
{
  "columns": [
    { "name": "EventResult", "type": "string", "values": ["Success", "Failure", "Partial", "NA"] },
    { "name": "EventSeverity", "type": "string", "values": ["Informational", "Low", "Medium", "High"] }
  ]
}
```

---

## Entity Mapping Heuristics

The ingestion scripts automatically map columns to entity pools based on column name patterns:

| Column Name Pattern | Entity Pool | Example |
|---|---|---|
| `*IpAddr*`, `*IP*`, `*SourceIP*` | `ipAddresses` | `10.0.1.50` |
| `*Username*`, `*UserId*`, `*AccountName*` | `users` (username) | `jsmith` |
| `*Hostname*`, `*ComputerName*`, `*DeviceName*` | `devices` (hostname) | `WS-PC01` |
| `*Url*`, `*Uri*` | `urls` | `https://portal.contoso.com/dashboard` |
| `*Domain*`, `*DomainName*` | `domains` | `contoso.com` |

---

## Script Reference

### Invoke-SampleDataIngestion.ps1

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-TableName` | Yes | — | Target table name. Custom tables end with `_CL`. |
| `-RowCount` | No | 500 | Number of sample rows to generate. |
| `-Schema` | No* | — | Path to JSON file with column definitions. |
| `-SampleDataFile` | No* | — | Path to JSON/CSV with sample rows. |
| `-Deploy` | No | — | Create/reuse DCE, DCR, and custom table. |
| `-Ingest` | No | — | Generate and send data via Log Ingestion API. |
| `-TimeWindowHours` | No | 24 | Timestamp spread. |

*At least one of `-Schema` or `-SampleDataFile` required.

### Invoke-AttackScenarioIngestion.ps1

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-ScenarioFile` | Yes | — | Path to attack scenario JSON definition. |
| `-Deploy` | No | — | Deploy infrastructure for all tables. |
| `-Ingest` | No | — | Generate correlated data and ingest. |
| `-TimeWindowHours` | No | 4 | Total scenario time window. |

### Schema JSON Format

```json
{
  "columns": [
    { "name": "TimeGenerated", "type": "datetime" },
    { "name": "SourceIP", "type": "string" },
    { "name": "Action", "type": "string", "values": ["Allow", "Deny", "Drop"] },
    { "name": "BytesSent", "type": "long" }
  ]
}
```

Supported types: `string`, `int`, `long`, `real`, `bool`, `boolean`, `datetime`, `dynamic`.

> **⚠️ `guid` is NOT supported by DCR stream declarations.** Use `string` for GUID/UUID fields.

---

## Pre-built Attack Scenarios

> All scenario templates are **product-agnostic**. The agent will ask the user which products to use for each table category and generate a runtime scenario file with product-specific details.

| Scenario File | MITRE Tactics | Tables |
|---|---|---|
| `brute-force-lateral-movement.json` | Initial Access, Credential Access, Lateral Movement, Execution, Discovery | Authentication, NetworkSession, ProcessEvent |
| `ransomware-deployment.json` | Initial Access, Execution, Impact, Persistence, Defense Evasion | Authentication, ProcessEvent, FileEvent, RegistryEvent |
| `data-exfiltration.json` | Collection, Exfiltration, C2, Discovery | AuditEvent, FileEvent, NetworkSession, Dns |
| `credential-theft-privesc.json` | Initial Access, Credential Access, Privilege Escalation, Persistence, Execution | Authentication, ProcessEvent, UserManagement |

---

## Common Issues

| Issue | Resolution |
|---|---|
| `403 Forbidden` on ingestion | Assign `Monitoring Metrics Publisher` role on the DCR |
| `InvalidStream` error | DCR hasn't propagated — retries automatically |
| Data not visible | Wait 5–10 minutes for ingestion delay |
| `InvalidStreamDeclaration` — `guid` | Use `string` for GUID/UUID fields in schema files. DCR stream declarations only support: `string`, `int`, `long`, `real`, `boolean`, `datetime`, `dynamic` |
| `InvalidStreamDeclaration` — `bool` | Use `boolean` (not `bool`) in schema files. The DCR API rejects `bool` |
| Built-in table has `guid`-typed columns | **Omit those columns** from the schema file entirely. Built-in tables like `SecurityEvent` have columns typed `guid` (e.g., `SourceComputerId`) that cannot be represented in DCR stream declarations. Simply leave them out of the schema — data will still ingest into the other columns |
| `InvalidTransformOutput` type mismatch | Usually means a column type in your schema doesn't match the built-in table's expected type. Check the [Azure Monitor table reference](https://learn.microsoft.com/azure/azure-monitor/reference/tables/) for the exact column types. Omit columns you can't match |
| Schema mismatch for built-in table | Match official Microsoft Docs schema exactly. For built-in tables, cross-reference column types at `https://learn.microsoft.com/azure/azure-monitor/reference/tables/<tablename>` |
| Missing schema for scenario table | Create the schema file first (Workflow 1) |
| Strict mode property access errors | The ingestion scripts use `Set-StrictMode -Version Latest`. When accessing optional JSON properties (like `.sampleDataFile` or `.values`), always check with `.PSObject.Properties['propertyName']` first |
| Dot-sourcing `Invoke-SampleDataIngestion.ps1` fails | Do **not** dot-source this script — it has top-level validation that throws if required parameters are missing. The scenario script handles ingestion inline |

### Schema Authoring Rules for Built-in Tables

When creating schema files for **built-in Azure tables** (e.g., `SecurityEvent`, `CommonSecurityLog`), follow these rules:

1. **Only use supported DCR types:** `string`, `int`, `long`, `real`, `boolean`, `datetime`, `dynamic`
2. **Omit columns with unsupported types:** If the built-in table has columns typed as `guid` (e.g., `SourceComputerId` in `SecurityEvent`), leave them out of the schema file entirely
3. **Use `boolean` not `bool`:** The DCR API rejects `bool` — always use `boolean`
4. **Cross-reference with Microsoft Docs:** Always verify column names and types against `https://learn.microsoft.com/azure/azure-monitor/reference/tables/<tablename>`
5. **Test deploy before ingest:** Run with `-Deploy` first to catch type mismatches, then `-Ingest` separately

### Runtime Scenario Learnings

- **Always run `-Deploy` and `-Ingest` separately for new scenarios** — if deployment fails halfway through (e.g., first table succeeds, second fails), the `-Deploy` flag will skip already-deployed tables on retry, but `-Ingest` won't run until all deployments succeed
- **The runtime scenario file includes `EventProduct`/`EventVendor` fields** in event templates, unlike the product-agnostic templates — this is intentional and correct
- **Actor entity pools resolve once per run** — the victim username, IP, device etc. are consistent across all phases within a single execution

---

## Product → Table Discovery Strategy

When the user asks to ingest data for a **product** (not a specific table name), use this strategy to discover which tables the connector sends data to:

### Step 1 — Find the connector in Sentinel Ninja Connectors Index

Search the connectors index for the product name:

`https://github.com/oshezaf/sentinelninja/blob/main/Solutions%20Docs/connectors-index.md`

This index lists all Sentinel connectors with links to detailed connector pages.

### Step 2 — Read the connector page to find destination tables

Each connector page lists the tables it sends data to. For example, the Proofpoint TAP connector page:

`https://github.com/oshezaf/sentinelninja/blob/main/Solutions%20Docs/connectors/proofpointtapv2.md`

lists all the tables (e.g., `ProofPointTAPMessagesDeliveredV2_CL`, `ProofPointTAPMessagesBlockedV2_CL`, `ProofPointTAPClicksPermittedV2_CL`, `ProofPointTAPClicksBlockedV2_CL`).

### Step 3 — Ask the user which tables to ingest

When a product has **multiple destination tables**, the agent **must present all the tables to the user and ask which ones they want to ingest into**. Do NOT assume the user wants all tables or only one table. Let them choose.

### Step 4 — Find the CCF configuration for schema and field values

The connector page typically links to the **CCF (Codeless Connector Framework) configuration** on the Azure-Sentinel GitHub repo. For example:

`https://github.com/Azure/Azure-Sentinel/blob/master/Solutions/ProofPointTap/Data%20Connectors/ProofpointTAP_CCP/ProofpointTAP_pollingconfig.json`

This file contains:
- **`streamDeclarations`** — the column names and types for each table (useful for building the schema file)
- **`apiEndpoint`** in each `RestApiPoller` — the upstream API being queried (useful for finding field value documentation)

### Step 5 — Research source API documentation for field values

Use the API endpoint from the CCF configuration to find the **vendor's API documentation**. A web search for the API endpoint or product API docs will typically lead to the official reference. For example:

- CCF config shows endpoint: `https://tap-api-v2.proofpoint.com/v2/siem/all`
- Web search → `https://help.proofpoint.com/Threat_Insight_Dashboard/API_Documentation/SIEM_API`

The API documentation tells you:
- What each field means
- The possible values for enum/categorical fields (e.g., threat classifications, action types, verdict values)
- The data types and formats

Use this information to populate the `values` arrays in the schema file for realistic data generation.

### Step 6 - Update the _meta.json file in the schemas/ folder
 
If a new table file is generated because it did not exist before, you need to update the file _meta.json in the schemas/ folder. This is only the case for official sentinel content solution packages, not custom tables that the user has added himself. The flow is as follows:
1. Check the table at https://github.com/MicrosoftDocs/azure-docs/blob/main/articles/sentinel/includes/sentinel-tables-connectors.md to find the table that was just generated and the Solution that has the table in its definition. We are only interested in the ones that are DCR enabled (which the user can actually write to)
2. Do a fuzzy search in https://github.com/Azure/Azure-Sentinel/tree/master/Solutions to find the solution that has this table, we will need the offer id which is usually in SolutionMetadata.json and the package information usually under packages/ in the solution folder
3. Update the _meta.json file, this file should normally already contain all the solution that are DCR enabled
  1. If not present for some reason, you add a new entry in the solution root array node. The schema has a name of the solution, the solutionFolder (which is slug from step 2), packageId and version (from packages) and contentId (contentId is the offer Id). The OfficialTables is the tables that the solution has (based on link in 1), you always fill these in. The hasSchema and tablesInRepo are with regard of the current repository. So, if not implemented and you leave the hasSchema to "none", if some tables are present you set it to "partial" and "all" if all tables are present to sample. The tablesInRepo are then actual files present, you input the names of the tables without file extension.
  2. If present, you just update the hasSchema (all, partial, none) and tablesInRepo

### Fallback — Sentinel GitHub and Microsoft Docs

If the Sentinel Ninja index doesn't have the product, fall back to:

1. **Solutions folder:** `https://github.com/Azure/Azure-Sentinel/tree/master/Solutions/<ProductName>`
2. **DataConnectors folder:** `https://github.com/Azure/Azure-Sentinel/tree/master/DataConnectors/<ProductName>`
3. **Sample Data folder:** `https://github.com/Azure/Azure-Sentinel/tree/master/Sample%20Data`
4. **Microsoft Docs:** `https://learn.microsoft.com/azure/azure-monitor/reference/tables/<tablename>`
