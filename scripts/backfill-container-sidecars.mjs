#!/usr/bin/env node
// One-time backfill of skill.spec.jsonc for the 17 carried-over container skills.
//
// These skills shipped before the sidecar contract existed, so they are the ONE
// sanctioned exception to "the scaffolder is the only thing that writes a
// sidecar". Every other skill in this catalog is born from the scaffolder.
//
// Kept as a script rather than done by hand so the result is reproducible and
// the authored content is reviewable in one place instead of across 17 files.
//
//   node scripts/backfill-container-sidecars.mjs [--check]
//
// Sources:
//   domain, value        data/catalog.json
//   triggering.implicit  the pilot's eval/trigger-evals.md prompt set, which was
//                        run for real rather than imagined
//   correction, posture  authored here, from behaviour verified against a live
//                        engine during the pilot. Message numbers are real.

import { readFileSync, writeFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const DOMAIN = 'azure-sql-database-container';
// skills/ is flat: the Agent Plugins specification discovers only immediate
// children and forbids recursion, so the domain lives in the sidecar rather
// than in the path.
const ROOT = 'skills';
const CATALOG = 'catalog/catalog.json';

// The container is Private Preview until November 2026, so every skill in this
// family passes the value bar on "not in training data" automatically. The
// correction is what it teaches on top of that.
const AUTHORED = {
  'azuresql-db-container': {
    posture: ['read', 'write', 'execute', 'provision'],
    target: 'container',
    correction:
      'Asked for a local SQL database, an agent reaches for mcr.microsoft.com/mssql/server. That is SQL Server, not Azure SQL Database: the container runs the PaaS engine, where SERVERPROPERTY(\'EngineEdition\') returns 5 and Edition is \'SQL Azure\', and it does not auto-create databases, so a plan that connects straight after docker run has nothing to connect to.',
    implicit: ['spin up a local mssql container I can query'],
    assert: ['engine reports EngineEdition 5', 'user database created explicitly, not assumed'],
  },
  'azuresql-db-sidecar': {
    posture: ['read', 'write', 'execute', 'provision'],
    target: 'container',
    correction:
      'In a compose stack an agent points the app at localhost and treats the database as ready the moment the container starts. Neither holds: the app must reach the engine by service name, a healthcheck is required so dependents wait for the engine rather than the process, and the user database needs a one-shot init service because the engine creates nothing on its own.',
    implicit: ['add a SQL database to my docker-compose'],
    assert: ['app reaches the database by service name', 'healthcheck present', 'database provisioned by an init step'],
  },
  'azuresql-db-scaffold': {
    posture: ['read', 'write', 'execute', 'provision'],
    target: 'container',
    correction:
      'Scaffolding a new app, an agent defaults to SQLite or PostgreSQL, or to the SQL Server image if it hears "SQL". For a project targeting Azure SQL Database the local engine should be the same engine, and the scaffold has to create the user database rather than assume the ORM will.',
    implicit: ['add a local SQL database to my app'],
    assert: ['uses the Azure SQL Database container image', 'creates the user database', 'connection string targets the user database, not master'],
  },
  'azuresql-db-schema-migration': {
    posture: ['read', 'write', 'execute'],
    target: 'container',
    correction:
      'Migration tools get pointed at the server default, which is master, and the run appears to succeed while putting the schema in the wrong place. The user database must be provisioned first and named in the connection string.',
    implicit: ['run my Prisma migrations against the local database'],
    assert: ['user database provisioned before migrating', 'connection string targets the user database'],
  },
  'azuresql-db-import': {
    posture: ['read', 'write', 'execute', 'provision'],
    target: 'container',
    correction:
      'Handed a .bacpac, an agent reaches for RESTORE. The engine rejects RESTORE with Msg 40510, because it is the Azure SQL Database engine rather than SQL Server. Import is SqlPackage against a database that has already been created on master.',
    implicit: ['I have a bacpac from prod, load it locally'],
    assert: ['uses SqlPackage rather than RESTORE', 'target database created on master first'],
  },
  'azuresql-db-from-sql-server': {
    posture: ['read', 'write', 'inspect'],
    target: 'container',
    correction:
      'An agent treats the SQL Server image and this engine as interchangeable and carries the whole configuration across. They are not: SQL Agent, FILESTREAM, full Service Broker, cross-server distributed transactions and Windows authentication do not exist here, and connection strings pointed at master need re-pointing at a provisioned user database.',
    implicit: ['I am using mcr.microsoft.com/mssql/server in my docker-compose'],
    assert: ['image rewritten to the Azure SQL Database container', 'SQL Server-only features flagged rather than silently carried over'],
  },
  'azuresql-db-local-to-cloud': {
    posture: ['read', 'write', 'execute', 'provision'],
    target: 'both',
    correction:
      'Asked whether local code will work in Azure, an agent starts rewriting the data layer. It should not: the local container and Azure SQL Database are the same engine, so the code does not change and only the connection string does, including the switch from SQL auth locally to Microsoft Entra in the cloud.',
    implicit: ['will this code work unchanged in Azure?'],
    assert: ['application code unchanged between targets', 'only the connection string differs'],
  },
  'azuresql-db-ci': {
    posture: ['read', 'write', 'execute', 'provision'],
    target: 'container',
    correction:
      'An agent adds the SQL Server image as a CI service and queries it immediately. This image comes from a private registry that needs credentials as secrets, the health check has to run sqlcmd inside the container because the runner has no client tools, and the user database must exist before the tests do.',
    implicit: ['my workflow tests against SQL, set up CI for it'],
    assert: ['registry credentials handled as secrets', 'health check runs inside the container', 'user database provisioned before tests'],
  },
  'azuresql-db-testing': {
    posture: ['read', 'write', 'execute'],
    target: 'container',
    correction:
      'Testcontainers has an MsSql preset, so an agent uses it and gets SQL Server. Testing against the Azure SQL Database engine means configuring a generic container with this image, its EULA and password requirements, and a readiness wait.',
    implicit: ['run my integration tests against a real database that starts and stops per test'],
    assert: ['does not use the Testcontainers MsSql preset', 'waits for readiness before running tests'],
  },
  'azuresql-db-seed': {
    posture: ['read', 'write', 'execute'],
    target: 'container',
    correction:
      'To load a CSV an agent writes BULK INSERT or OPENROWSET against a local path. The engine rejects that with Msg 12713, because it reads from Azure Blob Storage rather than the local filesystem. Local files go in through bcp or a driver.',
    implicit: ['fill my local database with realistic sample data across related tables'],
    assert: ['no local-file BULK INSERT or OPENROWSET', 'respects foreign key order when seeding related tables'],
  },
  'azuresql-db-connections': {
    posture: ['read', 'write'],
    target: 'both',
    correction:
      'Retry gets treated as a production hardening step to add later. On this engine transient faults are expected behaviour rather than an exception, so retry with backoff and a bounded pool belong in the data layer from the first connection.',
    implicit: ['my app keeps dropping the SQL connection under load, add retry and pooling'],
    assert: ['retry with backoff present', 'pool bounded explicitly'],
  },
  'azuresql-db-auth': {
    posture: ['read', 'write', 'admin'],
    target: 'both',
    correction:
      'Asked for a least-privilege user, an agent writes CREATE USER ... WITH PASSWORD, which fails here with Msg 15007, and then tries SET CONTAINMENT = PARTIAL, which fails with Msg 12844. Contained users are not available: create a server login and map a database user to it.',
    implicit: ['my app connects as sa, set up a least-privilege database user instead'],
    assert: ['uses CREATE LOGIN plus CREATE USER FOR LOGIN', 'application does not connect as sa'],
  },
  'azuresql-db-dab': {
    posture: ['read', 'write', 'execute'],
    target: 'container',
    correction:
      'Asked for an API over existing tables, an agent hand-writes controllers and an ORM layer. Data API Builder generates REST and GraphQL from configuration with no application code, which is both less work and less to maintain.',
    implicit: ['give me a REST and GraphQL API over these tables without writing code'],
    assert: ['uses Data API Builder configuration rather than hand-written endpoints'],
  },
  'azuresql-db-functions': {
    posture: ['read', 'write', 'execute'],
    target: 'container',
    correction:
      'The Azure SQL trigger binding has a prerequisite no model volunteers: change tracking must be enabled on the database and the table, or the trigger simply never fires and nothing reports an error. Change Event Streaming is cloud-only and cannot stand in for it locally.',
    implicit: ['build a serverless HTTP API over my SQL tables with Azure Functions'],
    assert: ['change tracking enabled before using a SQL trigger', 'does not propose Change Event Streaming against the container'],
  },
  'azuresql-db-rag': {
    posture: ['read', 'write', 'execute'],
    target: 'container',
    correction:
      'For embeddings an agent reaches for pgvector, FAISS, Chroma or Pinecone and adds a second datastore. This engine has a native VECTOR type and VECTOR_DISTANCE, so the vectors live beside the data they belong to. Inserting one requires CAST(CAST(? AS NVARCHAR(MAX)) AS VECTOR(n)) with a literal dimension, which is not guessable.',
    implicit: ['store embeddings and do similarity search locally in SQL'],
    assert: ['uses the native VECTOR type rather than an external vector store', 'vector insert uses the documented cast form'],
  },
  'azuresql-db-faq': {
    posture: ['read', 'inspect'],
    target: 'container',
    correction:
      'Asked what the container supports, an agent answers from general SQL Server knowledge and is confidently wrong. BACKUP and RESTORE are rejected with Msg 40510, USE against a user database fails with Msg 40508, and the current limitation list is a live document rather than something to recall.',
    implicit: ['can I take a backup of this container?'],
    assert: ['answers from the documented limitation list', 'links the live known-limitations page rather than reciting from memory'],
  },
  'azuresql-db-feedback': {
    posture: ['read'],
    target: 'none',
    correction:
      'Told that something did not work, an agent says "file an issue" and leaves the user to it. A skill problem and a product problem use different templates, the report needs context the agent already has, and secrets in a pasted connection string would become world-readable, so the report is built, redacted, and never submitted without explicit confirmation.',
    implicit: ['the skill told my agent the wrong thing, how do I report it'],
    assert: [],
  },
};

// Negative controls. Without these a broad description scores well on triggering
// and routes badly in practice, which is the failure the eval exists to catch.
const NEGATIVE = [
  'set up a local PostgreSQL database with docker compose',
  'provision an Azure SQL Database in my subscription',
  'connect to SQL Server on my company network',
];

// maturity, per skill, from the live probe lane's run of 2026-09-04 against the
// container on build 12.0.2000.8, EngineEdition 5, Edition 'SQL Azure':
// 101 of 101 probes passed, 17 of 17 skills ran, 0 skipped.
//
// This used to be the literal 'preview' for all 17, written when the sidecar
// contract was invented and derived from nothing. It is now derived from what
// ran. The ladder: draft means nothing has run that could contradict the skill,
// preview means probes ran against a real engine and passed, ga means preview
// plus a value measurement. No value measurement exists for any of these 17, so
// none of them can reach ga today.
//
// The four that stay at draft each failed a different part of the preview test,
// and none of them failed a probe. They are held down because of what their
// probes did not ask, not because of what they answered:
//
//   azuresql-db-local-to-cloud  declares target 'both' and ran only on the
//                               container. No sidecar declares target 'cloud',
//                               so nothing in the lane waits for a logical
//                               server and the cloud half was never executed.
//   azuresql-db-dab             all five probes run on the host. They measure
//                               the Data API builder CLI on the machine that
//                               ran them. No statement reached a database.
//   azuresql-db-sidecar         two probes parse a Compose file on the host and
//                               the third checks a binary is executable in the
//                               image. Nothing was asked of the engine.
//   azuresql-db-feedback        one probe, a live HTTPS redirect check. Real,
//                               and the only claim here anything can settle,
//                               but it is a network check and it covers almost
//                               none of the skill.
//
// These values must stay equal to the same field in
// microsoft/azure-sql-database-container, which is where the probes live.
const MATURITY = {
  'azuresql-db-auth': 'preview',
  'azuresql-db-ci': 'preview',
  'azuresql-db-connections': 'preview',
  'azuresql-db-container': 'preview',
  'azuresql-db-dab': 'draft',
  'azuresql-db-faq': 'preview',
  'azuresql-db-feedback': 'draft',
  'azuresql-db-from-sql-server': 'preview',
  'azuresql-db-functions': 'preview',
  'azuresql-db-import': 'preview',
  'azuresql-db-local-to-cloud': 'draft',
  'azuresql-db-rag': 'preview',
  'azuresql-db-scaffold': 'preview',
  'azuresql-db-schema-migration': 'preview',
  'azuresql-db-seed': 'preview',
  'azuresql-db-sidecar': 'draft',
  'azuresql-db-testing': 'preview',
};

// ---------------------------------------------------------------------------
// The value question, answered by argument rather than by measurement
// ---------------------------------------------------------------------------
//
// The ladder's top rung asks whether a skill changes an ANSWER, and the
// instrument for that is a two-arm run: one task, asked once with the skill and
// once without. For this family that instrument measures nothing. The container
// is a gated private preview, no model has training data on the product, and the
// arm without the skill fails for the least interesting reason available: it has
// never heard of the thing. Carlos Robles accepted value for the collection on
// 2026-09-04 on a written argument instead, one per skill.
//
// THESE ARE DECLARATIONS AND NOT MEASUREMENTS. Nothing may report them as one.
//
// The boundary is per skill and it is in two places on purpose, the prose and
// the two arrays, because a boundary that is only implied is a boundary that
// widens. `covers` is built from that skill's own probes in
// microsoft/azure-sql-database-container: the refusal numbers this engine really
// answers with, the absent init directory, the engine never creating a database
// on connect, the vector surface. `does_not_cover` names the generic material
// wrapped around those kernels, the retry loops, the Compose YAML, the workflow
// service containers, the ORM scaffolding, and admits that whether these skills
// improve an answer there is unmeasured and stays unmeasured.
//
// These must stay equal to the same field in
// microsoft/azure-sql-database-container, which is where the probes live, for the
// same reason MATURITY must.
const DECLARATIONS = {
  "azuresql-db-auth": {
    "rationale": "This skill's kernel is an identity recipe that is the inverse of the published Azure SQL Database guidance, and the inversion is only visible from the engine's refusals. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach general least-privilege advice, role grants, and where a secret should be stored outside the repository, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "the contained database user, CREATE USER WITH PASSWORD, being refused on this engine with Msg 15007, which inverts the cloud norm",
      "ALTER DATABASE SET CONTAINMENT = PARTIAL being refused with Msg 12844, so the contained route cannot be enabled either",
      "CREATE USER FROM EXTERNAL PROVIDER being refused with Msg 37525 on this build",
      "the server login plus mapped database user being the identity recipe that actually works here",
      "the connection being encrypted on this engine, which the skill asserts rather than assumes"
    ],
    "does_not_cover": [
      "general least-privilege reasoning and why sa is a poor application identity, which any model argues correctly",
      "where a password or connection secret belongs outside the repository, and secret-store choice"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-ci": {
    "rationale": "This skill's kernel is which engine the CI service container is actually running and what readiness means for it. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach GitHub Actions workflow syntax, the services block, job matrices and the shape of a retry loop, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "the service container being the Azure SQL Database engine, EngineEdition 5 with Edition 'SQL Azure', and not the SQL Server image every published example uses",
      "USE being refused in a user-database session with Msg 40508, so the database is selected in the connection string",
      "sqlcmd living at /opt/mssql-tools18/bin/sqlcmd inside the image, which is the path every readiness command in the body depends on",
      "the provisioning session on master being a different session from the one the statement filter is enforced in"
    ],
    "does_not_cover": [
      "GitHub Actions workflow syntax, the services block and job matrices, all abundant in training data",
      "retry with backoff as a pattern, as distinct from what the readiness gate has to poll"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-connections": {
    "rationale": "This skill's kernel is which transient error numbers and platform views this engine really carries, as opposed to a remembered list. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach connection pooling and retry with backoff, which every driver documents and every model already writes, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "USE being refused with Msg 40508 locally exactly as in the cloud, so the database is named in the connection string",
      "which transient error numbers this engine actually carries in sys.messages, checked rather than recalled",
      "which platform dynamic management views this engine exposes, so a local diagnostic is not written against one that is absent",
      "the transport this engine reports, which decides what a local connection diagnostic can conclude"
    ],
    "does_not_cover": [
      "connection pooling and retry with backoff as patterns, which are ordinary driver material",
      "the general argument that a blanket catch-all retry is worse than no retry at all"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-container": {
    "rationale": "This skill's kernel is the whole set of ways this image behaves like the platform rather than like the boxed engine. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach Docker run and Compose syntax, port publishing, volume mounts and the shape of a readiness loop, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "the engine never creating a database when a connection names one, so it is created on a master connection first",
      "USE being refused in a user-database session with Msg 40508",
      "BACKUP and RESTORE being refused with Msg 40510",
      "sp_configure being absent rather than blocked, so the engine answers Msg 2812 and there is nothing to be permitted to call",
      "there being no msdb and therefore no SQL Server Agent on this engine",
      "/docker-entrypoint-initdb.d being absent from the image, so a seed placed there runs silently never",
      "the native VECTOR(n) type and VECTOR_DISTANCE being present on this build",
      "a container reporting Up while the engine inside it never started, which is what a password failing the complexity policy produces"
    ],
    "does_not_cover": [
      "Docker run and Compose syntax, port publishing and volume mounts",
      "retry with backoff as a pattern, as distinct from the fact that Up is not serving"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-dab": {
    "rationale": "This skill's kernel is what the Data API builder does and does not need from THIS engine, and one endpoint nobody asked for. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach Data API builder CLI usage, its configuration file shape, its REST and GraphQL path defaults, and API design generally, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted. Its maturity stays draft regardless, and not because of this argument. All five of its probes run the CLI on the host and no statement reaches a database, so the probe rung underneath value is unmet.",
    "covers": [
      "the engine not auto-creating a database, so the tool starts and fails to reach one that was never provisioned",
      "this engine needing no change tracking and no feature enablement for this tool, unlike the event-driven path an agent reaches for",
      "the Model Context Protocol endpoint being published from the same configuration and enabled by default, and NOT being a standalone Microsoft SQL MCP server"
    ],
    "does_not_cover": [
      "Data API builder CLI usage and its configuration file shape, which are public and documented",
      "REST and GraphQL API design, and the hand-written controller layer the skill argues against"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-faq": {
    "rationale": "This skill's kernel is a way to sort a capability question, and every bucket boundary is an engine refusal that only this engine produces. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach general Azure SQL Database and SQL Server feature knowledge, which is exactly what the buckets sort, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "BACKUP and RESTORE being refused with Msg 40510, which is the boundary of the managed-service bucket",
      "USE being refused with Msg 40508",
      "the contained user refused with Msg 15007 and CONTAINMENT PARTIAL refused with Msg 12844",
      "BULK INSERT from a local path refused with Msg 12713, because this engine reads bulk data from Azure Blob Storage only"
    ],
    "does_not_cover": [
      "general Azure SQL Database and SQL Server feature knowledge, which is what the buckets sort rather than what they add",
      "how to phrase a hedged answer when a question does not resolve"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-feedback": {
    "rationale": "This skill's kernel is project-specific routing: which of two issue templates a report belongs in and where it is filed. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach redacting a pasted connection string, asking before submitting, and how to write a good bug report, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted. Its maturity stays draft regardless, and not because of this argument. Its single probe is an HTTPS redirect check that covers almost none of the skill, so the probe rung underneath value is unmet.",
    "covers": [
      "the two distinct issue templates this product uses and the test that decides between them, which exists only in this project",
      "the aka.ms destination a report is filed to, which is project-specific and in no training data",
      "which facts the agent already holds and the user does not, for this product specifically: the image tag, the host and the runtime"
    ],
    "does_not_cover": [
      "redacting secrets from a pasted connection string, and the practice of confirming before submitting anything",
      "how to write a clear bug report, which is ordinary material"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-from-sql-server": {
    "rationale": "This skill's kernel is the five specific places a working SQL Server setup stops working, each one an engine refusal with its own number. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach editing a Compose file to change an image, an environment block or a port mapping, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "the two images being different engines, EngineEdition 2, 3, 4 or 8 against 5 with Edition 'SQL Azure'",
      "USE being refused with Msg 40508 and BACKUP with Msg 40510",
      "sp_configure being absent and answering Msg 2812, which is a different failure from a refusal",
      "ALTER DATABASE SET RECOVERY refusing one option with Msg 40517, as distinct from Msg 40510 refusing a whole statement",
      "cross-database queries being refused on this engine",
      "/docker-entrypoint-initdb.d being absent, so a carried-over seed silently stops running"
    ],
    "does_not_cover": [
      "editing a Compose file to swap an image, environment block or port mapping",
      "the general practice of testing against the engine you deploy to"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-functions": {
    "rationale": "This skill's kernel is that the mechanism an agent reaches for does not exist locally, and the one that does fails silently when misconfigured. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach Azure Functions project scaffolding, host configuration and the handler code itself, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "the cloud streaming path being unavailable against a local engine, so the SQL trigger binding is the only local mechanism",
      "change tracking having to be enabled twice, once for the database and again for each table",
      "a table with no primary key not being trackable at all, so a correctly wired function simply never fires",
      "the compatibility level and OPENJSON behaviour this build actually reports, rather than a remembered one"
    ],
    "does_not_cover": [
      "Azure Functions project scaffolding, host configuration and handler code",
      "the general idea of event-driven processing over a database"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-import": {
    "rationale": "This skill's kernel is that the route an agent reaches for does not exist here, and that two actions of the replacement tool differ in whether they create the target. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach SqlPackage command-line syntax and the bacpac and dacpac formats, which are publicly documented, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "there being no restore path on this engine, with BACKUP and RESTORE refused with Msg 40510",
      "/Action:Import not creating its target, so the database must exist and be empty first, where /Action:Publish does create it",
      "SqlPackage not being present inside the image, so it runs from the host against the published port",
      "USE being refused with Msg 40508 during provisioning"
    ],
    "does_not_cover": [
      "SqlPackage command-line syntax and the bacpac and dacpac formats",
      "general data-migration sequencing advice"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-local-to-cloud": {
    "rationale": "This skill's kernel is that the local engine and the cloud service are the same engine, which is the claim that makes the whole rewrite unnecessary. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach configuring a connection string per environment, deploying to Azure, and managed identity as a concept, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted. Its maturity stays draft regardless, and not because of this argument. It declares target both and ran only against the container, so the cloud half of its own claim has never executed and the probe rung underneath value is unmet.",
    "covers": [
      "the local container being the same engine as the cloud service, EngineEdition 5 with Edition 'SQL Azure', so one data layer serves both",
      "USE refused with Msg 40508 and BACKUP refused with Msg 40510 locally exactly as in the cloud",
      "cross-database queries being refused locally as they are in the cloud, so a local pass is evidence about the cloud",
      "IDENTITY behaving here as it does in the cloud, which is one of the places a rewrite is usually justified"
    ],
    "does_not_cover": [
      "configuring a connection string per environment and deploying an application to Azure",
      "managed identity and Microsoft Entra ID authentication as concepts, which are ordinary Azure material"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-rag": {
    "rationale": "This skill's kernel is a set of vector specifics that fail with error numbers naming the wrong thing, so each costs an afternoon to rediscover. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach chunking, embedding model choice, prompt construction and retrieval-augmented generation architecture, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "the vector dimension being part of the type and required as a literal in the SQL text, with a bind parameter refused as a syntax error",
      "the dimension floor this build enforces and the number it answers with, Msg 42266",
      "the dimension ceiling and the truncation behaviour this build actually has",
      "the vector index being refused against a table under row level security, with Msg 37579",
      "exact and approximate vector search both building and running on this build, and the database scoped configuration they depend on"
    ],
    "does_not_cover": [
      "chunking strategy, embedding model choice and prompt construction",
      "retrieval-augmented generation architecture generally, which is abundant in training data"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-scaffold": {
    "rationale": "This skill's kernel is four assumptions a copied skeleton carries in, each of which is false on this engine. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach project scaffolding, Compose skeletons and directory layout, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "the image being the Azure SQL Database engine at EngineEdition 5, not mcr.microsoft.com/mssql/server",
      "the engine not auto-creating a database on connect, so the first migration run fails against an engine that is working perfectly",
      "USE being refused with Msg 40508",
      "the seed file not being run by the image, because the init-directory convention does not exist here",
      "the native vector column type being available to a scaffold on this build"
    ],
    "does_not_cover": [
      "project scaffolding, Compose skeletons and directory layout",
      "choice of application framework or ORM"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-schema-migration": {
    "rationale": "This skill's kernel is that two things every other engine has taught a migration tool are false here. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach Entity Framework Core migrations, SqlPackage usage and migration safety practice such as expand and contract, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "the engine not auto-creating a database, so a migration run fails on its first connection against a healthy engine and reads as a credentials fault",
      "USE being refused with Msg 40508, so the tool cannot switch database context and the database is named in the connection string",
      "the target-server and trust-server-certificate flags SqlPackage needs against the container's self-signed certificate",
      "the native vector column type being usable from a migration on this build"
    ],
    "does_not_cover": [
      "Entity Framework Core migrations and SqlPackage usage, which are publicly documented",
      "migration safety practice such as expand and contract, which is ordinary material"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-seed": {
    "rationale": "This skill's kernel is that the tool an agent reaches for cannot read a local file at all, and the failure names a path rather than the rule. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach reading and generating CSV data, and driver-side batch insert code, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "BULK INSERT from a local path being refused with Msg 12713, because this engine reads bulk data from Azure Blob Storage only",
      "OPENROWSET BULK from a local path being refused the same way, so it is not the workaround it looks like",
      "bcp being present in the image and streaming from the client side, which is the change of tool the situation actually needs",
      "parent-before-child ordering, whose failure is Msg 547 and names a constraint rather than an ordering rule"
    ],
    "does_not_cover": [
      "reading and generating CSV data, and driver-side batch insert code",
      "the general practice of seeding tables in dependency order"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-sidecar": {
    "rationale": "This skill's kernel is what a healthcheck for THIS image has to invoke, and which image it is invoking it in. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach Compose file syntax, service naming, and reaching a container by service name rather than localhost, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted. Its maturity stays draft regardless, and not because of this argument. Two of its probes parse a Compose file on the host and the third checks that a binary is executable in the image, so nothing has been asked of the engine and the probe rung underneath value is unmet.",
    "covers": [
      "the image being the Azure SQL Database engine and not mcr.microsoft.com/mssql/server",
      "sqlcmd living at /opt/mssql-tools18/bin/sqlcmd in this image, which is what a healthcheck must invoke and what a copied one gets wrong",
      "depends_on waiting only for the container, so a condition on a real engine healthcheck is required rather than optional"
    ],
    "does_not_cover": [
      "Compose file syntax and service naming, including that a container is reached by service name rather than localhost, all ordinary Compose knowledge",
      "the general practice of gating a dependent service on a healthcheck"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  },
  "azuresql-db-testing": {
    "rationale": "This skill's kernel is that the preset every example uses pulls the wrong product, and there is no preset for the right one. The Azure SQL Database container is a gated private preview and the image is not publicly available, so no model has training data on the product, and the arm of a two-arm value run that ran without this skill would fail for the least interesting reason available: it has never heard of the thing. Running that measurement across all seventeen container skills would spend around a thousand model requests to re-establish what the product's release status already establishes. Carlos Robles accepted value for this collection on 2026-09-04 on this written argument instead. THIS IS A DECLARATION AND NOT A MEASUREMENT, and nothing may report it as one. The argument reaches only the container-specific corrections listed in covers, which are the ones no training data contains. It does not reach test framework choice, fixture lifecycle and assertion style, which is ordinary material an ordinary model already handles, and whether this skill improves an answer there is unmeasured and stays unmeasured. The argument ends when the Azure SQL Database container reaches Public Preview: training data begins to contain the product, the premise that nothing could know it stops being true, and this skill has to be measured or demoted.",
    "covers": [
      "there being no Testcontainers preset for this image, so it is started from the generic container API with the image, ACCEPT_EULA and a complex password set by hand",
      "the container being ready before the engine is, so the fixture has to poll the engine with a real query rather than sleep",
      "the engine not creating a test database on connect, so the fixture creates it on a master connection first",
      "USE being refused with Msg 40508",
      "the native vector type being present, so a fixture can exercise it on this build"
    ],
    "does_not_cover": [
      "test framework choice, fixture lifecycle and assertion style",
      "the general argument for integration tests against a real database"
    ],
    "decided_by": "Carlos Robles",
    "decided_on": "2026-09-04",
    "expires_when": "the-container-reaches-public-preview"
  }
};

// The product's own release stage, which is the premise the declarations rest on
// and the reason none of these 17 is `ga`.
//
// A skill marked `ga` for a product that is not generally available reads as a
// claim about the PRODUCT, and outside this project that is the only way it can
// read. Worse, the argument that would earn the rung is itself an argument from
// the product being pre-release, so promoting on those grounds inverts it. The
// declarations raise the ceiling to `ga` and every one of the 17 sits below it
// deliberately, which is the ladder's own rule about an author declaring under
// the evidence.
//
// This is a gate rather than a comment because a comment would not have stopped
// anybody. Move it when the product moves, and note that the same event retires
// every declaration above.
const PRODUCT_RELEASE_STAGE = 'private-preview';
const EXPIRY_TOKEN = 'the-container-reaches-public-preview';
const DECLARATION_FIELDS = ['rationale', 'covers', 'does_not_cover', 'decided_by', 'decided_on', 'expires_when'];

// Checked here rather than trusted, because the schema this catalog ships is not
// run over these files by anything in this script, and a validator nobody invokes
// verifies nothing.
function declarationProblems(id, d) {
  const out = [];
  if (!d) return [`${id} has no value_declaration in DECLARATIONS, so nothing records why it is not measured`];
  for (const f of DECLARATION_FIELDS) if (d[f] === undefined) out.push(`${id} value_declaration is missing ${f}`);
  if (typeof d.rationale === 'string' && d.rationale.trim().length < 400) {
    out.push(`${id} value_declaration rationale is under 400 characters, so it records a conclusion and not the reasoning`);
  }
  for (const f of ['covers', 'does_not_cover']) {
    if (!Array.isArray(d[f]) || d[f].length === 0) {
      out.push(`${id} value_declaration ${f} is empty, so the argument states no boundary and reads as covering the whole skill`);
    }
  }
  if (d.expires_when !== EXPIRY_TOKEN) {
    out.push(`${id} value_declaration expires_when is ${JSON.stringify(d.expires_when ?? null)}, not ${JSON.stringify(EXPIRY_TOKEN)}. `
      + 'The expiry is a fixed token so it can be found by a program rather than by somebody rereading a paragraph.');
  }
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(String(d.decided_on))) {
    out.push(`${id} value_declaration decided_on is not an ISO date`);
  }
  if (typeof d.decided_by !== 'string' || !d.decided_by.trim()) {
    out.push(`${id} value_declaration names nobody in decided_by, so there is no one to ask about it later`);
  }
  return out;
}

const check = process.argv.includes('--check');
const catalog = JSON.parse(readFileSync(CATALOG, 'utf8'));
const byId = Object.fromEntries(catalog.skills.map((s) => [s.id, s]));

let written = 0;
const problems = [];

for (const [id, a] of Object.entries(AUTHORED)) {
  const entry = byId[id];
  if (!entry) { problems.push(`${id} is not in ${CATALOG}`); continue; }
  if (entry.domain !== DOMAIN) { problems.push(`${id} is in domain ${entry.domain}`); continue; }
  if (!MATURITY[id]) { problems.push(`${id} has no maturity in MATURITY, so nothing sets it`); continue; }

  problems.push(...declarationProblems(id, DECLARATIONS[id]));
  if (MATURITY[id] === 'ga' && PRODUCT_RELEASE_STAGE === 'private-preview') {
    problems.push(
      `${id} is marked ga while the product is ${PRODUCT_RELEASE_STAGE}. A skill marked generally `
      + 'available for a product that is not generally available reads as a claim about the product, '
      + 'and the value argument that would earn the rung is itself an argument from the product being '
      + 'pre-release. The ceiling may be ga; the declared value must sit below it until the product moves.',
    );
  }

  const spec = {
    $schema: '../../catalog/skill.spec.schema.json',
    id,
    domain: entry.domain,
    value: entry.value,
    correction: a.correction,
    posture: a.posture,
    maturity: MATURITY[id],
    value_declaration: DECLARATIONS[id],
    applies_to: a.target === 'both'
      ? ['azure-sql-db', 'azure-sql-db-container']
      : ['azure-sql-db-container'],
    validation: { target: a.target, assert: a.assert },
    triggering: {
      explicit: [`Use the ${id} skill`],
      implicit: a.implicit,
      negative: NEGATIVE,
    },
  };
  if (spec.validation.assert.length === 0) delete spec.validation.assert;

  const path = join(ROOT, id, 'skill.spec.jsonc');
  const body = JSON.stringify(spec, null, 2) + '\n';
  if (check) {
    if (!existsSync(path) || readFileSync(path, 'utf8') !== body) problems.push(`${path} is out of date`);
  } else {
    writeFileSync(path, body);
    written++;
  }
}

const missing = catalog.skills.filter((s) => s.domain === DOMAIN && !AUTHORED[s.id]);
for (const s of missing) problems.push(`${s.id} is in the catalog but has no authored sidecar here`);

if (problems.length) {
  console.error(`${problems.length} problem(s):`);
  for (const p of problems) console.error(`  x ${p}`);
  process.exit(1);
}
console.log(check ? `all ${Object.keys(AUTHORED).length} container sidecars are current`
                  : `wrote ${written} sidecars into ${ROOT}`);
