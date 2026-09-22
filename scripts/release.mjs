import { spawnSync } from 'node:child_process';
import { cpSync, existsSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve, join } from 'node:path';
import { tmpdir } from 'node:os';
import { nativeEnv } from './native-env.mjs';

const root = resolve(import.meta.dirname, '..');
process.chdir(root);
const env = nativeEnv();
const modules = ['sql_session', 'moondb_session', 'postgres_session', 'mysql', 'ws_session'];
const mode = process.argv[2] ?? 'check';
if (!['check', 'publish'].includes(mode)) throw new Error('Expected check or publish');

function run(command, args, capture = false) {
  const result = spawnSync(command, args, { cwd: root, env, encoding: 'utf8', stdio: capture ? 'pipe' : 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.signal ?? result.status})${capture ? `: ${result.stderr}` : ''}`);
  return result.stdout;
}
function moon(...args) { return run(process.execPath, ['scripts/moon.mjs', ...args]); }
function metadata(dir) {
  const source = readFileSync(join(dir, 'moon.mod'), 'utf8');
  const field = key => source.match(new RegExp(`^${key} = "([^"]+)"`, 'm'))?.[1];
  const name = field('name');
  const version = field('version');
  if (name !== `Hosi121/${dir}` || !/^\d+\.\d+\.\d+$/.test(version ?? '') || field('license') !== 'Apache-2.0') {
    throw new Error(`Invalid release metadata: ${dir}`);
  }
  for (const file of ['LICENSE', 'NOTICE', 'README.md', '.moonignore']) {
    if (!existsSync(join(dir, file))) throw new Error(`Missing ${dir}/${file}`);
  }
  return { dir, name, version, archive: `${name.replace('/', '-')}-${version}.zip` };
}

if (mode === 'publish' && run('git', ['status', '--porcelain'], true).trim()) {
  throw new Error('Commit the reviewed source before publishing immutable registry versions.');
}
moon('info', '--target', 'native');
const releases = modules.map(metadata);
const stage = mkdtempSync(join(tmpdir(), 'moonbit-sessions-package-'));
try {
  for (const entry of releases) {
    // Unlike publish --dry-run, package works without registry login on this CLI.
    moon('-C', entry.dir, 'package');
    const archive = join(root, '_build', 'publish', entry.archive);
    const paths = run('unzip', ['-Z', '-1', archive], true).trim().split('\n');
    for (const path of paths) {
      const parts = path.split('/');
      if (parts.some(part => part === '..' || part.startsWith('.')) || path.startsWith('/') ||
          !/^(moon\.mod|README\.md|LICENSE|NOTICE|src\/(?:[\w-]+\/)*(?:moon\.pkg|[\w.-]+\.(?:mbt|mbti|c|h)))$/.test(path)) {
        throw new Error(`Unexpected distribution file: ${entry.archive}: ${path}`);
      }
    }
    for (const required of ['moon.mod', 'LICENSE', 'NOTICE', 'README.md', 'src/moon.pkg', 'src/pkg.generated.mbti']) {
      if (!paths.includes(required)) throw new Error(`Incomplete package: ${entry.archive}: ${required}`);
    }
    if (entry.dir === 'mysql' && !paths.includes('src/worker.c')) throw new Error('MySQL package is missing its C worker');
    run('unzip', ['-q', archive, '-d', join(stage, entry.dir)]);
    entry.sha256 = createHash('sha256').update(readFileSync(archive)).digest('hex');
    entry.files = paths;
  }

  // These consumers only see unpacked archives, never the source module dirs.
  for (const [library, example] of [['mysql', 'mysql'], ['postgres_session', 'postgres'], ['moondb_session', 'moondb'], ['ws_session', 'websocket']]) {
    const consumer = mkdtempSync(join(tmpdir(), 'moonbit-sessions-install-'));
    try {
      const members = ['library', 'consumer'];
      cpSync(join(stage, library), join(consumer, 'library'), { recursive: true });
      cpSync(join(root, 'examples', example), join(consumer, 'consumer'), { recursive: true });
      if (library !== 'ws_session') {
        cpSync(join(stage, 'sql_session'), join(consumer, 'sql_session'), { recursive: true });
        cpSync(join(root, 'examples', 'conformance'), join(consumer, 'conformance'), { recursive: true });
        members.push('sql_session', 'conformance');
      }
      writeFileSync(join(consumer, 'moon.work'), `members = ${JSON.stringify(members)}\n`);
      moon('-C', consumer, 'build', '--target', 'native', '--release');
      if (library !== 'mysql') {
        const module = example === 'websocket' ? 'ws_session' : example;
        const binary = join(consumer, `_build/native/release/build/Hosi121/${module}_example/${module}_example.exe`);
        if (/libmariadb|libmysqlclient/.test(run('ldd', [binary], true))) throw new Error(`${library} linked MySQL`);
      }
      if (library === 'moondb_session') {
        moon('-C', consumer, 'test', '--target', 'native', 'sql_session/src', 'library/src');
      }
    } finally { rmSync(consumer, { recursive: true, force: true }); }
  }
  writeFileSync(join(root, '_build/publish/manifest.json'), JSON.stringify({ modules: releases }, null, 2) + '\n');
  console.log(`Verified ${releases.length} distributable archives and four isolated consumers.`);

  if (mode === 'publish') {
    // Dependencies go first. Authentication stays in the CLI's own credential store.
    moon('whoami');
    for (const entry of releases) {
      moon('-C', entry.dir, 'publish');
      moon('update');
    }
    console.log('Published all modules. Verify a fresh registry consumer before announcing availability.');
  }
} finally { rmSync(stage, { recursive: true, force: true }); }
