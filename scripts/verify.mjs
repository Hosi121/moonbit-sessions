import { spawnSync } from 'node:child_process';
import { cpSync, mkdtempSync, rmSync, writeFileSync, readdirSync, readFileSync } from 'node:fs';
import { resolve, join } from 'node:path';
import { tmpdir } from 'node:os';
import { nativeEnv } from './native-env.mjs';

const root = resolve(import.meta.dirname, '..');
process.chdir(root);
const env = nativeEnv();
function run(command, args, options = {}) {
  const result = spawnSync(command, args, { cwd: root, env, stdio: 'inherit', ...options });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`${command} failed (${result.signal ?? result.status})`);
}
function moon(...args) { run(process.execPath, ['scripts/moon.mjs', ...args]); }
function audit(dir) {
  for (const entry of readdirSync(dir, { withFileTypes: true })) {
    const path = join(dir, entry.name);
    if (entry.isDirectory()) audit(path);
    else if (path.endsWith('.mbt') && /\bAny\b|\bJSValue\b|unsafeCast/.test(readFileSync(path, 'utf8'))) {
      throw new Error(`Untyped boundary in ${path}`);
    }
  }
}

const mode = process.argv[2];
if (mode === 'check') {
  moon('check', '--target', 'native');
  moon('info', '--target', 'native');
  for (const dir of ['sql/src', 'mysql/src', 'postgres/src', 'ws_session/src']) audit(dir);
} else if (mode === 'test') {
  moon('test', '--target', 'native', 'sql/src');
  moon('build', '--target', 'native', '--release', 'examples/websocket/src');
  run(process.execPath, ['--test', '--test-timeout=15000', 'tests/websocket.test.mjs']);
} else if (mode === 'mysql') {
  const value = process.env.SERVICEKIT_TEST_DATABASE_URL;
  if (!value) throw new Error('Set SERVICEKIT_TEST_DATABASE_URL to a disposable MySQL database; this test creates and drops servicekit_contract.');
  const url = new URL(value);
  if (url.protocol !== 'mysql:' || !url.hostname || url.pathname.length < 2) throw new Error('Invalid MySQL test configuration');
  moon('build', '--target', 'native', '--release', 'examples/mysql/src');
  run('_build/native/release/build/hosi121/mysql_example/mysql_example.exe', [], {
    timeout: 30000,
    env: { ...env, SERVICEKIT_MYSQL_HOST: url.hostname, SERVICEKIT_MYSQL_PORT: url.port || '3306',
      SERVICEKIT_MYSQL_USER: decodeURIComponent(url.username), SERVICEKIT_MYSQL_PASSWORD: decodeURIComponent(url.password),
      SERVICEKIT_MYSQL_DATABASE: decodeURIComponent(url.pathname.slice(1)) },
  });
} else if (mode === 'postgres') {
  const value = process.env.SERVICEKIT_TEST_POSTGRES_URL;
  if (!value) throw new Error('Set SERVICEKIT_TEST_POSTGRES_URL to a disposable PostgreSQL database.');
  const url = new URL(value);
  if (url.protocol !== 'postgres:' || !url.hostname || url.pathname.length < 2) throw new Error('Invalid PostgreSQL test configuration');
  moon('build', '--target', 'native', '--release', 'examples/postgres/src');
  run('_build/native/release/build/hosi121/postgres_example/postgres_example.exe', [], {
    timeout: 30000,
    env: { ...env, SERVICEKIT_POSTGRES_HOST: url.hostname, SERVICEKIT_POSTGRES_PORT: url.port || '5432',
      SERVICEKIT_POSTGRES_USER: decodeURIComponent(url.username), SERVICEKIT_POSTGRES_PASSWORD: decodeURIComponent(url.password),
      SERVICEKIT_POSTGRES_DATABASE: decodeURIComponent(url.pathname.slice(1)) },
  });
} else if (mode === 'consumer') {
  // Each application builds with only its own dependency, outside this checkout.
  for (const [library, example] of [['mysql', 'mysql'], ['postgres', 'postgres'], ['ws_session', 'websocket']]) {
    const dir = mkdtempSync(join(tmpdir(), 'servicekit-consumer-'));
    try {
      cpSync(library, join(dir, 'library'), { recursive: true });
      cpSync(`examples/${example}`, join(dir, 'consumer'), { recursive: true });
      const members = ['library', 'consumer'];
      if (library !== 'ws_session') {
        cpSync('sql', join(dir, 'sql'), { recursive: true });
        cpSync('examples/conformance', join(dir, 'conformance'), { recursive: true });
        members.push('sql', 'conformance');
      }
      writeFileSync(join(dir, 'moon.work'), `members = ${JSON.stringify(members)}\n`);
      run(process.execPath, ['scripts/moon.mjs', '-C', dir, 'build', '--target', 'native', '--release']);
      if (library !== 'mysql') {
        const binary = join(dir, `_build/native/release/build/hosi121/${library === 'postgres' ? 'postgres' : 'ws_session'}_example/${library === 'postgres' ? 'postgres' : 'ws_session'}_example.exe`);
        const linked = spawnSync('ldd', [binary], { env, encoding: 'utf8' });
        if (linked.status !== 0 || /libmariadb|libmysqlclient/.test(linked.stdout)) throw new Error('Non-MySQL consumer must not link MySQL');
      }
    } finally { rmSync(dir, { recursive: true, force: true }); }
  }
} else throw new Error('Expected check, test, mysql, postgres, or consumer');
