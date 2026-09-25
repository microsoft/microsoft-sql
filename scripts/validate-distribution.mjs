// Copyright (c) Microsoft Corporation.
// Licensed under the MIT license.

import { access, readdir, readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const errors = [];

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
    "capture-with-extended-events",
    "connect-from-dotnet",
    "connect-from-python",
    "connect-from-typescript-and-node",
    "connect-to-azure-sql",
    "dab-rest-and-graphql",
    "deploy-app-to-azure",
    "design-azure-sql-schema",
    "dev-container-templates",
    "diagnose-blocking-and-deadlocks",
    "diagnose-connection-errors",
    "diagnose-resource-pressure",
    "diagnose-slow-query",
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
    "capture-with-extended-events",
    "connect-from-dotnet",
    "connect-from-python",
    "connect-from-typescript-and-node",
    "connect-to-azure-sql",
    "deploy-app-to-azure",
    "design-azure-sql-schema",
    "dev-container-templates",
    "diagnose-blocking-and-deadlocks",
    "diagnose-connection-errors",
    "diagnose-resource-pressure",
    "diagnose-slow-query",
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
  ],
};

const expectedPlugins = Object.keys(expectedSkills).sort();
const expectedVersions = {
  "microsoft-azuresqldb-container": "1.0.0",
  "microsoft-sql": "1.0.0",
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
  "skill-contract.yml",
  "skill.spec.jsonc",
  "suppression.json",
]);
const requiredRootFiles = [
  "CODE_OF_CONDUCT.md",
  "CONTRIBUTING.md",
  "LICENSE.txt",
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
if (await exists(path.join(root, "LICENSE"))) {
  fail("LICENSE: use the required LICENSE.txt release filename");
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
    const skillFile = path.join(skillsDirectory, skillName, "SKILL.md");
    if (!(await exists(skillFile))) {
      fail(`${relative(skillFile)}: missing`);
    }
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
      const expected = await readFile(path.join(feedbackBaseline, feedbackFile), "utf8");
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
  if (!textExtensions.has(extension)) {
    continue;
  }
  const contents = buffer.toString("utf8");
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
  "LICENSE.txt",
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

const license = (await readFile(path.join(root, "LICENSE.txt"), "utf8")).replace(/\r\n/g, "\n");
if (!license.startsWith("Microsoft SQL agent skills\n\nMIT License\n")) {
  fail("LICENSE.txt: project name must appear above the MIT license");
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
