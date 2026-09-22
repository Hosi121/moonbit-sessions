import { existsSync } from 'node:fs';
import { resolve } from 'node:path';
export function nativeEnv(base = process.env) {
  const root = resolve('.tools/native/usr');
  if (!existsSync(root)) return { ...base };
  const library = `${root}/lib/x86_64-linux-gnu`;
  const append = (value, previous) => [value, previous].filter(Boolean).join(':');
  return { ...base,
    CPATH: append(`${root}/include:${root}/include/x86_64-linux-gnu`, base.CPATH),
    LIBRARY_PATH: append(library, base.LIBRARY_PATH),
    LD_LIBRARY_PATH: append(library, base.LD_LIBRARY_PATH),
    MYSQL_PLUGIN_DIR: base.MYSQL_PLUGIN_DIR ?? `${library}/libmariadb3/plugin`,
  };
}
