import { spawnSync } from 'node:child_process';
import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
const local = resolve(process.env.MOON_HOME ?? '.tools/moon');
const installed = existsSync(`${local}/bin/moon`);
const result = spawnSync(installed ? `${local}/bin/moon` : 'moon', process.argv.slice(2), {
  stdio: 'inherit',
  env: installed ? { ...process.env, MOON_HOME: local, PATH: `${local}/bin:${process.env.PATH}` } : process.env,
});
if (result.error) console.error(result.error.message);
process.exit(result.status ?? 1);
