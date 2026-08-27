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
const ROOT = join('skills', DOMAIN);
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
      'Asked for a least-privilege user, an agent writes CREATE USER ... WITH PASSWORD, which fails here with Msg 15007, and then tries SET CONTAINMENT = PARTIAL, which fails with Msg 12824. Contained users are not available: create a server login and map a database user to it.',
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

const check = process.argv.includes('--check');
const catalog = JSON.parse(readFileSync(CATALOG, 'utf8'));
const byId = Object.fromEntries(catalog.skills.map((s) => [s.id, s]));

let written = 0;
const problems = [];

for (const [id, a] of Object.entries(AUTHORED)) {
  const entry = byId[id];
  if (!entry) { problems.push(`${id} is not in ${CATALOG}`); continue; }
  if (entry.domain !== DOMAIN) { problems.push(`${id} is in domain ${entry.domain}`); continue; }

  const spec = {
    $schema: '../../../catalog/skill.spec.schema.json',
    id,
    domain: entry.domain,
    value: entry.value,
    correction: a.correction,
    posture: a.posture,
    maturity: 'preview',
    applies_to: a.target === 'both'
      ? ['azure-sql-db', 'azure-sql-db-container']
      : ['azure-sql-db-container'],
    // The date the pilot last verified these against a live engine. It moves
    // when a battery is re-run, not when the file is touched.
    last_verified: '2026-08-20',
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
