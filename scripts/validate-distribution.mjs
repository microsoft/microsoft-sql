// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

import { access, readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const errors = [];
const allowDevelopmentMcp = process.argv.includes("--allow-development-mcp");

const expectedSkills = {
  "microsoft-azuresqldb-container": [
    "azuresql-db-auth",
    "azuresql-db-ci",
    "azuresql-db-connections",
    "azuresql-db-container",
    "azuresql-db-dab",
    "azuresql-db-faq",
    "azuresql-db-feedback",
    "azuresql-db-from-sql-server",
    "azuresql-db-functions",
    "azuresql-db-import",
    "azuresql-db-local-to-cloud",
    "azuresql-db-rag",
    "azuresql-db-scaffold",
    "azuresql-db-schema-migration",
    "azuresql-db-seed",
    "azuresql-db-sidecar",
    "azuresql-db-testing",
  ],
  "microsoft-sql": [
    "azure-functions-sql-bindings",
    "azure-sql",
    "azuresql-db-auth",
    "azuresql-db-ci",
    "azuresql-db-connections",
    "azuresql-db-container",
    "azuresql-db-dab",
    "azuresql-db-faq",
    "azuresql-db-feedback",
    "azuresql-db-from-sql-server",
    "azuresql-db-functions",
    "azuresql-db-import",
    "azuresql-db-local-to-cloud",
    "azuresql-db-rag",
    "azuresql-db-scaffold",
    "azuresql-db-schema-migration",
    "azuresql-db-seed",
    "azuresql-db-sidecar",
    "azuresql-db-testing",
    "build-app-on-azure-sql",
    "bulk-load-and-bulk-copy",
    "connect-from-dotnet",
    "connect-from-python",
    "connect-from-typescript-and-node",
    "connect-to-azure-sql",
    "dab-mcp-endpoint",
    "dab-rest-and-graphql",
    "deploy-app-to-azure",
    "deploy-dab-to-azure",
    "design-azure-sql-schema",
    "dev-container-templates",
    "ef-core-azure-sql",
    "embeddings-and-external-models",
    "entra-id-auth",
    "github-actions-for-sql",
    "langchain-and-llamaindex-on-azure-sql",
    "prevent-sql-injection",
    "prisma-azure-sql",
    "provision-azure-sql-db",
    "provision-hyperscale",
    "rag-local-with-container",
    "rag-on-azure-sql",
    "read-execution-plan",
    "restore-and-recover",
    "rls-multi-tenant",
    "schema-migrations-safely",
    "skill-feedback",
    "sql-database-projects",
    "sqlalchemy-azure-sql",
    "sqlpackage-import-export",
    "t-sql-correctness",
    "t-sql-json-and-openjson",
    "t-sql-upserts-merge",
    "vector-search-azure-sql",
  ],
  "microsoft-sql-admin": [
    "active-connections",
    "always-encrypted-columns",
    "authentication-diagnostics",
    "backup-history-azuresql",
    "backup-strategy-sqlserver",
    "blocking-root-cause-analysis",
    "check-live-blocking",
    "code-analysis",
    "connectivity-troubleshoot",
    "create-xe-session",
    "database-config-azuresql",
    "database-settings-review",
    "deadlock-analysis",
    "deadlock-analysis-azuresql",
    "geo-dr-assessment-health-check",
    "ha-assessment-health-check",
    "health-audit-sqlserver",
    "improve-query-performance",
    "investigate-geo-dr-issues",
    "investigate-ha-issues",
    "investigate-sql-cpu-pressure",
    "investigate-sql-data-io-pressure",
    "investigate-sql-log-io-pressure",
    "investigate-sql-memory-issues",
    "investigate-statistics-issues",
    "ledger-tables",
    "missing-index-analysis",
    "partitioned-tables",
    "plan-analysis",
    "plan-cache-analysis",
    "plan-cache-qds-bridge",
    "query-hint-tuning",
    "query-rewrite",
    "query-store-investigation",
    "query-store-volatile-historical-slow-queries-comparison",
    "resource-usage-sqlserver",
    "schema-design-guidance",
    "slow-query-investigation",
    "sql-admin-analyze-readiness-at-scale",
    "sql-admin-evaluate-azure-migration-assessment",
    "sql-admin-get-migration-assessment",
    "sql-agent-job-failure-investigator",
    "sql-tools-mcp-setup",
    "table-access-analysis",
    "table-health-check",
    "top-queries-noqds",
    "wait-category-analysis",
  ],
  "microsoft-sql-fdh": ["databasehub-cli"],
  "microsoft-sql-migration": [
    "analyze-readiness-at-scale",
    "evaluate-azure-migration-assessment",
    "evaluate-offline-migration-readiness",
    "generate-migration-prerequisite-plan",
    "get-migration-assessment",
    "recommend-migration-path",
    "recommend-sku-sizing",
    "run-migration-assessment",
    "sql-backup-restore-to-azure-sql-vm-migration",
    "sql-bacpac-to-azure-sql-db-migration",
    "sql-server-to-sql-mi-lrs-migration",
    "validate-post-migration-data",
  ],
  "microsoft-sql-vscode": [
    "azure-functions-sql-bindings",
    "bulk-load-and-bulk-copy",
    "create-xe-session",
    "connect-from-dotnet",
    "connect-from-python",
    "connect-from-typescript-and-node",
    "connect-to-azure-sql",
    "dab-mcp-endpoint",
    "deploy-app-to-azure",
    "deploy-dab-to-azure",
    "design-azure-sql-schema",
    "dev-container-templates",
    "check-live-blocking",
    "connectivity-troubleshoot",
    "resource-usage-sqlserver",
    "slow-query-investigation",
    "ef-core-azure-sql",
    "embeddings-and-external-models",
    "entra-id-auth",
    "github-actions-for-sql",
    "langchain-and-llamaindex-on-azure-sql",
    "prevent-sql-injection",
    "prisma-azure-sql",
    "provision-azure-sql-db",
    "provision-hyperscale",
    "rag-on-azure-sql",
    "read-execution-plan",
    "restore-and-recover",
    "rls-multi-tenant",
    "schema-migrations-safely",
    "skill-feedback",
    "sql-database-projects",
    "sqlalchemy-azure-sql",
    "sqlpackage-import-export",
    "t-sql-correctness",
    "t-sql-json-and-openjson",
    "t-sql-upserts-merge",
    "vector-search-azure-sql",
    "deadlock-analysis-azuresql",
    "authentication-diagnostics",
    "investigate-sql-cpu-pressure",
    "investigate-sql-data-io-pressure",
    "investigate-sql-log-io-pressure",
    "investigate-sql-memory-issues",
  ],
};

const expectedPlugins = Object.keys(expectedSkills).sort();
const expectedVersions = {
  "microsoft-azuresqldb-container": "1.0.0",
  "microsoft-sql": "1.0.0",
  "microsoft-sql-admin": "1.0.0",
  "microsoft-sql-fdh": "1.0.0",
  "microsoft-sql-migration": "1.0.0",
  "microsoft-sql-vscode": "1.0.0",
};
const marketplaceFiles = [
  ".agents/plugins/marketplace.json",
  ".claude-plugin/marketplace.json",
  ".cursor-plugin/marketplace.json",
  ".github/plugin/marketplace.json",
];
const expectedMarketplaceVersion = "1.0.0";
const manifestFiles = [
  "plugin.json",
  ".claude-plugin/plugin.json",
  ".codex-plugin/plugin.json",
  ".cursor-plugin/plugin.json",
];
const feedbackPlugins = [
  "microsoft-sql",
  "microsoft-sql-vscode",
];
const issueFormIds = [
  "additional",
  "agent",
  "confirm",
  "install-method",
  "plugin",
  "problem-type",
  "repro",
  "skill",
  "skill-said",
  "version",
  "what-happened",
];
const forbiddenSidecars = new Set([
  "loader-test-fixture.md",
  "skill-contract.yml",
  "skill.spec.jsonc",
  "suppression.json",
]);
const requiredRootFiles = [
  "CODE_OF_CONDUCT.md",
  "CONTRIBUTING.md",
  "LICENSE",
  "NOTICE.txt",
  "PRIVACY.md",
  "README.md",
  "SECURITY.md",
];
const sourceHeaderPrefixes = new Map([
  [".c", "//"],
  [".cpp", "//"],
  [".cs", "//"],
  [".go", "//"],
  [".h", "//"],
  [".java", "//"],
  [".js", "//"],
  [".jsx", "//"],
  [".mjs", "//"],
  [".ps1", "#"],
  [".py", "#"],
  [".rs", "//"],
  [".sh", "#"],
  [".sql", "--"],
  [".ts", "//"],
  [".tsx", "//"],
]);
const forbiddenBinaryExtensions = new Set([
  ".a",
  ".bin",
  ".dll",
  ".dylib",
  ".exe",
  ".jar",
  ".lib",
  ".nupkg",
  ".pdb",
  ".so",
  ".vsix",
  ".zip",
]);
const textExtensions = new Set([
  ...sourceHeaderPrefixes.keys(),
  ".json",
  ".md",
  ".txt",
  ".yaml",
  ".yml",
]);
const obsoleteRepositoryName = ["microsoft", ["azure", "sql", "skills"].join("-")].join("/");
const obsoleteRepositoryPattern = new RegExp(
  `${obsoleteRepositoryName.replace("/", String.raw`\/`)}(?![-\\w])`,
  "u",
);
const forbiddenInternalContent = [
  [new RegExp(["partner", "confidential"].join("-"), "iu"), "restricted partner material"],
  [
    new RegExp(["internal", "use", "only"].join(String.raw`\s+`), "iu"),
    "restricted-use marker",
  ],
  [
    new RegExp(["microsoft", "internal"].join("[- ]"), "iu"),
    "restricted Microsoft material",
  ],
  [/\bFY\d{2}\s+EMEA\s+EPS\b/iu, "internal fiscal-year program material"],
  [
    new RegExp(["SQL", "in", "a", "Day"].join(String.raw`\s+`), "iu"),
    "internal event material",
  ],
  [
    new RegExp(["Cloud", "Accelerate", "Factory"].join(String.raw`\s+`), "iu"),
    "internal delivery-program material",
  ],
];

function relative(file) {
  return path.relative(root, file).replaceAll("\\", "/");
}

function fail(message) {
  errors.push(message);
}

function equalList(label, actual, expected) {
  const actualSorted = [...actual].sort();
  const expectedSorted = [...expected].sort();
  if (JSON.stringify(actualSorted) !== JSON.stringify(expectedSorted)) {
    fail(
      `${label}: expected [${expectedSorted.join(", ")}], found [${actualSorted.join(", ")}]`,
    );
  }
}

async function readJson(file) {
  try {
    return JSON.parse(await readFile(file, "utf8"));
  } catch (error) {
    fail(`${relative(file)}: invalid JSON (${error.message})`);
    return null;
  }
}

async function exists(file) {
  try {
    await access(file);
    return true;
  } catch {
    return false;
  }
}

async function validateCoordinatedKnowledgeBase(skillDirectory) {
  const skillFile = path.join(skillDirectory, "SKILL.md");
  const skillText = await readFile(skillFile, "utf8");
  const coordinated = /Current coordinated knowledge-base line:\s*\*\*(v\d+\.\d+)\*\*/u.exec(skillText);
  if (!coordinated) {
    if (/If the versions disagree/iu.test(skillText)) {
      fail(`${relative(skillFile)}: version-stop policy has no coordinated knowledge-base line`);
    }
    return;
  }

  const expected = coordinated[1];
  const declarations = [];
  const requireVersions = async (file, pattern, label) => {
    let text;
    try {
      text = await readFile(file, "utf8");
    } catch (error) {
      fail(`${relative(file)}: cannot read coordinated knowledge-base declaration (${error.message})`);
      return;
    }
    const match = pattern.exec(text);
    if (!match) {
      fail(`${relative(file)}: missing coordinated knowledge-base declaration (${label})`);
      return;
    }
    for (const version of match.slice(1)) declarations.push({ file, label, version });
  };

  await requireVersions(
    skillFile,
    /input\/output schemas, and knowledge base (v\d+\.\d+)\./u,
    "checked-against statement",
  );
  await requireVersions(
    skillFile,
    /Knowledge base (v\d+\.\d+) \(bundled[^\n]*rules (v\d+\.\d+)/u,
    "startup announcement",
  );
  await requireVersions(
    skillFile,
    /"knowledgeBaseVersion": "(v\d+\.\d+)",[\s\S]*?"decisionRulesVersion": "(v\d+\.\d+)"/u,
    "structured output example",
  );
  await requireVersions(
    skillFile,
    /> KB \*\*(v\d+\.\d+)\*\*/u,
    "recommendation example",
  );

  const references = path.join(skillDirectory, "references");
  await requireVersions(
    path.join(references, "knowledge-base.md"),
    /^> \*\*Version\.\*\* (v\d+\.\d+)/mu,
    "knowledge-base header",
  );
  await requireVersions(
    path.join(references, "knowledge-base.md"),
    /^Current version: \*\*(v\d+\.\d+)\*\*/mu,
    "knowledge-base current version",
  );
  await requireVersions(
    path.join(references, "decision-rules.md"),
    /^Source of truth:.*\*\*(v\d+\.\d+)\*\*/mu,
    "decision-rules source",
  );
  await requireVersions(
    path.join(references, "sample-recommendation.md"),
    /> KB \*\*(v\d+\.\d+)\*\*[^\n]*rules \*\*(v\d+\.\d+)\*\*/u,
    "sample recommendation",
  );
  await requireVersions(
    path.join(references, "sample-recommendation.md"),
    /"knowledgeBaseVersion": "(v\d+\.\d+)",[\s\S]*?"decisionRulesVersion": "(v\d+\.\d+)"/u,
    "sample structured output",
  );

  for (const { file, label, version } of declarations) {
    if (version !== expected) {
      fail(`${relative(file)}: ${label} declares ${version}; coordinated version is ${expected}`);
    }
  }
}

async function validatePrerequisitePolicy(skillDirectory) {
  const refs = path.join(skillDirectory, "references");
  const skill = await readFile(path.join(skillDirectory, "SKILL.md"), "utf8");
  const declared = /schema\/KB line `([^`]+)`\/`([^`]+)`/u.exec(skill);
  if (!declared) {
    fail(`${relative(skillDirectory)}: missing prerequisite schema/KB declaration`);
    return;
  }
  const [, schemaVersion, knowledgeBaseVersion] = declared;
  const check = (file, label, actual, expected) => {
    if (actual !== expected) fail(`${relative(skillDirectory)}/${file}: ${label} is ${actual}; expected ${expected}`);
  };
  const catalog = await readJson(path.join(refs, "path-catalog.json"));
  const questions = await readJson(path.join(refs, "questions.json"));
  const input = await readJson(path.join(refs, "input.schema.json"));
  const output = await readJson(path.join(refs, "output.schema.json"));
  check("references/path-catalog.json", "schema version", catalog?.schemaVersion, schemaVersion);
  check("references/path-catalog.json", "knowledge-base version", catalog?.knowledgeBaseVersion, knowledgeBaseVersion);
  check("references/questions.json", "schema version", questions?.schemaVersion, schemaVersion);
  check("references/input.schema.json", "schema version", input?.properties?.schemaVersion?.const, schemaVersion);
  const metadata = output?.properties?.metadata?.properties;
  check("references/output.schema.json", "schema version", metadata?.schemaVersion?.const, schemaVersion);
  check("references/output.schema.json", "knowledge-base version", metadata?.prerequisiteKnowledgeBaseVersion?.const, knowledgeBaseVersion);
  check("references/output.schema.json", "path catalog version", metadata?.pathCatalogVersion?.const, catalog?.schemaVersion);
  for (const name of ["input-contract.md", "output-contract.md"]) {
    const text = await readFile(path.join(refs, name), "utf8");
    check(`references/${name}`, "schema version", /\*\*Schema version:\*\* `([^`]+)`/u.exec(text)?.[1], schemaVersion);
    check(`references/${name}`, "knowledge-base version", /\*\*Prerequisite knowledge-base line:\*\* `([^`]+)`/u.exec(text)?.[1], knowledgeBaseVersion);
  }
  const kb = await readFile(path.join(refs, "knowledge-base.md"), "utf8");
  check("references/knowledge-base.md", "knowledge-base version", /\*\*Version:\*\* (v\d+\.\d+)/u.exec(kb)?.[1], knowledgeBaseVersion);
  const announcement = /Prerequisite knowledge base (v\d+\.\d+) \(bundled\) · schema ([\d.]+)/u.exec(skill);
  check("SKILL.md", "startup knowledge-base version", announcement?.[1], knowledgeBaseVersion);
  check("SKILL.md", "startup schema version", announcement?.[2], schemaVersion);
  // Advisor versions and mappingsVersion describe separate policies; do not compare them to these lines.
}

async function validateCompanionMcp(directory, pluginName, readme) {
  const configFiles = ["mcp.json", ".mcp.json", "mcp-installation.json"];
  if (pluginName !== "microsoft-sql-admin") {
    for (const name of configFiles) {
      if (await exists(path.join(directory, name))) fail(`${pluginName}/${name}: unexpected companion server`);
    }
    return;
  }
  const portable = await readJson(path.join(directory, "mcp.json"));
  const legacy = await readJson(path.join(directory, ".mcp.json"));
  const installation = await readJson(path.join(directory, "mcp-installation.json"));
  equalList(`${pluginName} MCP roles`, Object.keys(portable?.mcpServers ?? {}), ["sql-tools"]);
  if (JSON.stringify(portable?.mcpServers) !== JSON.stringify(legacy?.mcpServers)) {
    fail(`${pluginName}: MCP client configurations disagree`);
  }
  const entry = portable?.mcpServers?.["sql-tools"];
  const server = installation?.servers?.[0];
  const pkg = server?.package;
  if (installation?.servers?.length !== 1 || server?.role !== "sql-tools" || server?.serverId !== "sql-tools-mcp" || server?.kind !== "nuget") {
    fail(`${pluginName}: unexpected MCP installation metadata`);
  }
  if (pkg?.id !== "Microsoft.SqlServer.SQLtools.MCPserver" || !/^\d+\.\d+\.\d+(?:-[\w.-]+)?$/u.test(pkg?.version ?? "")) {
    fail(`${pluginName}: MCP package must have the expected ID and an exact version`);
  }
  const expectedArgs = [`${pkg?.id}@${pkg?.version}`, "--yes"];
  if (pkg?.development) {
    if (!allowDevelopmentMcp) fail(`${pluginName}: development MCP feed must not be published`);
    const feed = pkg.source?.replace(/^development feed /u, "");
    expectedArgs.push("--add-source", feed);
  } else if (pkg?.source !== "the client host's NuGet sources") {
    fail(`${pluginName}: unexpected published MCP package source`);
  }
  if (entry?.type !== "stdio" || entry?.command !== "dnx" || JSON.stringify(entry?.args) !== JSON.stringify(expectedArgs)) {
    fail(`${pluginName}: MCP launch arguments disagree with the pinned package`);
  }
  const expectedEnv = {
    SQLTOOLS__CONNECTIONPROVIDER: "EnvVar",
    SQLTOOLS__INCLUDEPREVIEWFEATURES: "Disabled",
    SQLTOOLS__SKILLCONTENTPROVIDER: "External",
  };
  for (const [label, actual] of [["launch", entry?.env], ["metadata", server?.configuration]]) {
    if (Object.keys(actual ?? {}).length !== 3 || Object.entries(expectedEnv).some(([key, value]) => actual?.[key] !== value)) {
      fail(`${pluginName}: ${label} must select EnvVar, preview Disabled, and External skills without credentials`);
    }
  }
  equalList(`${pluginName} required environment`, server?.requiredEnv ?? [], ["CONNECTION_STRING"]);
  if (!readme.includes(`${pkg?.id}@${pkg?.version}`) || !readme.includes(`https://www.nuget.org/packages/${pkg?.id}/${pkg?.version}/License`)) {
    fail(`${pluginName}: README package pin or license link disagrees with MCP metadata`);
  }
}

async function walk(directory) {
  const files = [];
  for (const entry of await readdir(directory, { withFileTypes: true })) {
    if (entry.name === ".git" || entry.name === "node_modules") {
      continue;
    }
    const fullPath = path.join(directory, entry.name);
    if (entry.isDirectory()) {
      files.push(...(await walk(fullPath)));
    } else if (entry.isFile()) {
      files.push(fullPath);
    }
  }
  return files;
}

const allFiles = await walk(root);

for (const fileName of requiredRootFiles) {
  if (!(await exists(path.join(root, fileName)))) {
    fail(`${fileName}: required release file is missing`);
  }
}
if (await exists(path.join(root, "LICENSE.txt"))) {
  fail("LICENSE.txt: use the repository-mandated LICENSE filename");
}
if (await exists(path.join(root, "assets", "plugin-logo.svg"))) {
  fail("assets/plugin-logo.svg: Microsoft product icons must not be published");
}

for (const file of allFiles.filter((candidate) => path.extname(candidate) === ".json")) {
  await readJson(file);
}

const pluginRoot = path.join(root, "plugins");
const pluginDirectories = (await readdir(pluginRoot, { withFileTypes: true }))
  .filter((entry) => entry.isDirectory())
  .map((entry) => entry.name);
equalList("plugin directories", pluginDirectories, expectedPlugins);

for (const pluginName of expectedPlugins) {
  const directory = path.join(pluginRoot, pluginName);
  const skillsDirectory = path.join(directory, "skills");
  const skillDirectories = (await readdir(skillsDirectory, { withFileTypes: true }))
    .filter((entry) => entry.isDirectory())
    .map((entry) => entry.name);
  equalList(`${pluginName} skills`, skillDirectories, expectedSkills[pluginName]);

  for (const skillName of skillDirectories) {
    const skillDirectory = path.join(skillsDirectory, skillName);
    const skillFile = path.join(skillDirectory, "SKILL.md");
    if (!(await exists(skillFile))) {
      fail(`${relative(skillFile)}: missing`);
      continue;
    }
    await validateCoordinatedKnowledgeBase(skillDirectory);
    if (skillName === "generate-migration-prerequisite-plan") await validatePrerequisitePolicy(skillDirectory);
  }

  for (const manifestName of manifestFiles) {
    const manifestPath = path.join(directory, manifestName);
    if (!(await exists(manifestPath))) {
      fail(`${relative(manifestPath)}: missing`);
      continue;
    }
    const manifest = await readJson(manifestPath);
    if (!manifest) {
      continue;
    }
    if (manifest.name !== pluginName) {
      fail(`${relative(manifestPath)}: name must be ${pluginName}`);
    }
    if (manifest.version !== expectedVersions[pluginName]) {
      fail(
        `${relative(manifestPath)}: version must be ${expectedVersions[pluginName]}`,
      );
    }
    if (manifest.repository !== "https://github.com/microsoft/microsoft-sql") {
      fail(`${relative(manifestPath)}: repository must point to microsoft/microsoft-sql`);
    }
  }

  const pluginReadme = path.join(directory, "README.md");
  if (!(await exists(pluginReadme))) {
    fail(`${relative(pluginReadme)}: missing`);
  } else {
    const text = await readFile(pluginReadme, "utf8");
    if (!text.includes(`Version ${expectedVersions[pluginName]}`)) fail(`${relative(pluginReadme)}: stale plugin version`);
    const rows = [...text.matchAll(/^\| `([^`]+)` \|/gmu)].map((match) => match[1]);
    equalList(`${relative(pluginReadme)} skill inventory`, rows, skillDirectories);
    await validateCompanionMcp(directory, pluginName, text);
  }
}

for (const marketplaceName of marketplaceFiles) {
  const marketplacePath = path.join(root, marketplaceName);
  const marketplace = await readJson(marketplacePath);
  if (!marketplace) {
    continue;
  }

  const feedbackBaseline = path.join(
    pluginRoot,
    "microsoft-sql",
    "skills",
    "skill-feedback",
  );
  for (const pluginName of feedbackPlugins.slice(1)) {
    const feedbackDirectory = path.join(
      pluginRoot,
      pluginName,
      "skills",
      "skill-feedback",
    );
    for (const feedbackFile of ["SKILL.md", "references/issue-fields.md"]) {
      let expected = await readFile(path.join(feedbackBaseline, feedbackFile), "utf8");
      // The VS Code package omits container skills. Permit only its declared
      // feedback handoff substitution; every other byte must still match.
      if (pluginName === "microsoft-sql-vscode" && feedbackFile === "SKILL.md") {
        expected = expected.replaceAll("`azuresql-db-feedback`", "the Azure SQL Database container product feedback channel");
      }
      const actual = await readFile(path.join(feedbackDirectory, feedbackFile), "utf8");
      if (actual !== expected) {
        fail(`${pluginName}/skills/skill-feedback/${feedbackFile}: copies have drifted`);
      }
    }
  }
  if (marketplace.name !== "microsoft-sql") {
    fail(`${marketplaceName}: marketplace name must be microsoft-sql`);
  }
  const marketplaceVersion = marketplace.version ?? marketplace.metadata?.version;
  if (marketplaceVersion && marketplaceVersion !== expectedMarketplaceVersion) {
    fail(
      `${marketplaceName}: marketplace version must be ${expectedMarketplaceVersion}`,
    );
  }
  const plugins = marketplace.plugins ?? [];
  equalList(
    `${marketplaceName} plugins`,
    plugins.map((plugin) => plugin.name),
    expectedPlugins,
  );
  for (const plugin of plugins) {
    if (!expectedPlugins.includes(plugin.name)) {
      continue;
    }
    const source = typeof plugin.source === "string" ? plugin.source : plugin.source?.path;
    if (source !== `./plugins/${plugin.name}`) {
      fail(`${marketplaceName}: ${plugin.name} source is ${String(source)}`);
    }
    if (plugin.version && plugin.version !== expectedVersions[plugin.name]) {
      fail(`${marketplaceName}: ${plugin.name} has version ${plugin.version}`);
    }
    if (
      "repository" in plugin &&
      plugin.repository !== "https://github.com/microsoft/microsoft-sql"
    ) {
      fail(`${marketplaceName}: ${plugin.name} repository is stale`);
    }
  }
  if (
    marketplace.owner?.url &&
    marketplace.owner.url !== "https://github.com/microsoft/microsoft-sql"
  ) {
    fail(`${marketplaceName}: owner URL is stale`);
  }
}

for (const file of allFiles) {
  const extension = path.extname(file).toLowerCase();
  if (forbiddenBinaryExtensions.has(extension)) {
    fail(`${relative(file)}: pre-built binary or archive must not be published`);
  }
  const buffer = await readFile(file);
  if (buffer.includes(0)) {
    fail(`${relative(file)}: binary content must not be published`);
  }
  if (forbiddenSidecars.has(path.basename(file))) {
    fail(`${relative(file)}: source-only sidecar must not be published`);
  }
  if (relative(file).split(/[\\/]/).includes("live-tests")) {
    fail(`${relative(file)}: live-test setup is an eval fixture and must not be published`);
  }
  if (!textExtensions.has(extension)) {
    continue;
  }
  const contents = buffer.toString("utf8");
  if (path.basename(file) === "SKILL.md" && /bundled `skill-contract\.yml`/u.test(contents)) {
    fail(`${relative(file)}: refers to a bundled source-only skill contract`);
  }
  if (obsoleteRepositoryPattern.test(contents)) {
    fail(`${relative(file)}: contains the obsolete ${obsoleteRepositoryName} repository`);
  }
  if (/msdata\.visualstudio\.com/iu.test(contents)) {
    fail(`${relative(file)}: contains an internal Azure DevOps URL`);
  }
  for (const [pattern, description] of forbiddenInternalContent) {
    if (pattern.test(contents)) {
      fail(`${relative(file)}: contains ${description}`);
    }
  }
}

for (const file of allFiles) {
  const extension = path.extname(file).toLowerCase();
  const prefix = sourceHeaderPrefixes.get(extension);
  if (!prefix) {
    continue;
  }
  const lines = (await readFile(file, "utf8")).replace(/\r\n/g, "\n").split("\n");
  const start = extension === ".sh" && lines[0].startsWith("#!") ? 1 : 0;
  if (
    lines[start] !== `${prefix} Copyright (c) Microsoft Corporation.` ||
    lines[start + 1] !== `${prefix} Licensed under the MIT license.`
  ) {
    fail(`${relative(file)}: missing Microsoft MIT source header`);
  }
}

const readmePath = path.join(root, "README.md");
const readme = await readFile(readmePath, "utf8");
const requiredReadmeReferences = [
  "CODE_OF_CONDUCT.md",
  "CONTRIBUTING.md",
  "LICENSE",
  "NOTICE.txt",
  "PRIVACY.md",
  "SECURITY.md",
  "Microsoft's Trademark & Brand Guidelines",
];
for (const reference of requiredReadmeReferences) {
  if (!readme.includes(reference)) {
    fail(`README.md: missing required release reference ${reference}`);
  }
}
if (/[?&]logo=/iu.test(readme)) {
  fail("README.md: remote brand or product icons must not be embedded");
}
for (const pluginName of expectedPlugins) {
  if (!readme.includes(`${pluginName}@microsoft-sql`)) {
    fail(`README.md: missing install coordinate ${pluginName}@microsoft-sql`);
  }
  if (!readme.includes(`plugins/${pluginName}/`)) {
    fail(`README.md: missing link to plugins/${pluginName}/`);
  }
}

const license = (await readFile(path.join(root, "LICENSE"), "utf8")).replace(/\r\n/g, "\n");
if (!license.startsWith("Microsoft SQL agent skills\n\nMIT License\n")) {
  fail("LICENSE: project name must appear above the MIT license");
}
const contributing = await readFile(path.join(root, "CONTRIBUTING.md"), "utf8");
if (
  !contributing.includes("Contributor License Agreement") ||
  !contributing.includes("https://cla.opensource.microsoft.com")
) {
  fail("CONTRIBUTING.md: missing Microsoft CLA requirements");
}
const privacy = await readFile(path.join(root, "PRIVACY.md"), "utf8");
if (
  !privacy.includes("turn off the telemetry") ||
  !privacy.includes("https://go.microsoft.com/fwlink/?LinkID=824704")
) {
  fail("PRIVACY.md: missing required data collection notice or opt-out guidance");
}

for (const match of readme.matchAll(/!?\[[^\]]*\]\(([^)]+)\)/g)) {
  const target = match[1].split("#", 1)[0];
  if (
    !target ||
    target.startsWith("#") ||
    target.startsWith("../") ||
    /^[a-z][a-z0-9+.-]*:/iu.test(target)
  ) {
    continue;
  }
  if (!(await exists(path.resolve(root, decodeURIComponent(target))))) {
    fail(`README.md: local link does not exist: ${target}`);
  }
}

const issueForm = await readFile(
  path.join(root, ".github", "ISSUE_TEMPLATE", "skill_feedback.yml"),
  "utf8",
);
const issueFormOptions = new Set(
  issueForm
    .split(/\r?\n/u)
    .map((line) => line.trim())
    .filter((line) => line.startsWith("- "))
    .map((line) => line.slice(2)),
);
equalList(
  "skill_feedback.yml field ids",
  [...issueForm.matchAll(/^\s{4}id:\s*(.+)\s*$/gmu)].map((match) => match[1]),
  issueFormIds,
);
for (const pluginName of expectedPlugins) {
  if (!issueFormOptions.has(pluginName)) {
    fail(`skill_feedback.yml: missing plugin option ${pluginName}`);
  }
}
const uniqueSkills = [...new Set(Object.values(expectedSkills).flat())].sort();
for (const skillName of uniqueSkills) {
  if (!issueFormOptions.has(skillName)) {
    fail(`skill_feedback.yml: missing skill option ${skillName}`);
  }
}

if (errors.length > 0) {
  console.error(`Distribution validation failed with ${errors.length} error(s):`);
  for (const error of errors) {
    console.error(`- ${error}`);
  }
  process.exitCode = 1;
} else {
  console.log(
    `Validated ${expectedPlugins.length} plugins, ${uniqueSkills.length} unique skills, ` +
      `${marketplaceFiles.length} marketplaces, and ${allFiles.length} files.`,
  );
}
