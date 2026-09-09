/**
 * Client bundle secret scan.
 *
 * Fails the build if a server-only credential could reach the browser.
 *
 * The check is deliberately about VALUES and ACCESS PATTERNS, not about the
 * mere appearance of a variable name. The dashboard legitimately prints
 * "METRICS_INGEST_SECRET" inside an error message telling the user which
 * variable to configure; that string is documentation, not a leak. A naive
 * grep for the name flags it and trains everyone to ignore the scanner.
 *
 * What actually constitutes a leak:
 *   1. `process.env.<SERVER_ONLY_VAR>` surviving into a client chunk — Next
 *      inlines env values at build time, so this means the value is embedded.
 *   2. A literal that looks like a real credential (AWS key id, JWT, PEM).
 *
 * Run after `next build`:  node scripts/check-client-bundle.mjs
 */

import { readdirSync, readFileSync, statSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const CHUNK_DIR = '.next/static/chunks';

/** Variables that must never have their value inlined into client code. */
const SERVER_ONLY_VARS = [
  'R2_ACCESS_KEY_ID',
  'R2_SECRET_ACCESS_KEY',
  'R2_ACCOUNT_ID',
  'R2_BUCKET_NAME',
  'SUPABASE_SERVICE_ROLE_KEY',
  'METRICS_INGEST_SECRET',
];

/** Shapes that are credentials regardless of what they are called. */
const VALUE_PATTERNS = [
  { name: 'AWS/R2 access key id', re: /\b(?:AKIA|ASIA)[0-9A-Z]{16}\b/ },
  { name: 'PEM private key', re: /BEGIN[ A-Z]*PRIVATE KEY/ },
  // A Supabase service-role JWT specifically: the role claim is the tell.
  // The anon key is also a JWT and is expected in the bundle, so match the
  // decoded role rather than the JWT shape alone.
  { name: 'service_role JWT', re: /"role"\s*:\s*"service_role"/ },
  { name: 'service_role reference', re: /service_role/ },
];

function walk(dir, out = []) {
  if (!existsSync(dir)) return out;
  for (const entry of readdirSync(dir)) {
    const path = join(dir, entry);
    if (statSync(path).isDirectory()) walk(path, out);
    else if (entry.endsWith('.js')) out.push(path);
  }
  return out;
}

const files = walk(CHUNK_DIR);

if (files.length === 0) {
  console.error(`No client chunks found in ${CHUNK_DIR}. Run \`npm run build\` first.`);
  process.exit(1);
}

const findings = [];

for (const file of files) {
  const source = readFileSync(file, 'utf8');

  for (const varName of SERVER_ONLY_VARS) {
    // The leak is an ACCESS, not a mention. `process.env.X` in a client chunk
    // means the build inlined X's value.
    const accessRe = new RegExp(
      `process\\s*\\.\\s*env\\s*\\.\\s*${varName}\\b|process\\s*\\.\\s*env\\s*\\[\\s*["'\`]${varName}["'\`]\\s*\\]`,
    );
    if (accessRe.test(source)) {
      findings.push({ file, issue: `server-only env access: process.env.${varName}` });
    }
  }

  for (const { name, re } of VALUE_PATTERNS) {
    const match = source.match(re);
    if (match) {
      findings.push({ file, issue: `${name}: ${match[0].slice(0, 40)}` });
    }
  }
}

if (findings.length > 0) {
  console.error('CLIENT BUNDLE LEAK DETECTED\n');
  for (const f of findings) {
    console.error(`  ${f.file}`);
    console.error(`    ${f.issue}\n`);
  }
  console.error('Server-only credentials must never reach the browser.');
  console.error('Check that the module is imported only from a route handler or a');
  console.error("server component, and that it carries the `server-only` import.");
  process.exit(1);
}

console.log(`Client bundle scan clean (${files.length} chunks checked).`);
console.log('No server-only env access and no credential-shaped literals.');
