// Runs a Lua file with the project's .lua files mounted at /proj, so require() works.
// Usage: node run.mjs <projectDir> <luaFileRelativeToProject>
import { LuaFactory } from 'wasmoon';
import { readFileSync, readdirSync, statSync } from 'fs';
import path from 'path';

const [, , root, entry] = process.argv;
const factory = new LuaFactory();
const mounts = [];

function mount(dir, virtualDir) {
  for (const name of readdirSync(dir)) {
    if (name === 'node_modules' || name.startsWith('.')) continue;
    const full = path.join(dir, name);
    const virtual = `${virtualDir}/${name}`;
    if (statSync(full).isDirectory()) mount(full, virtual);
    else if (name.endsWith('.lua')) mounts.push(factory.mountFile(virtual, readFileSync(full)));
  }
}

mount(root, '/proj');
await Promise.all(mounts);

const lua = await factory.createEngine();
try {
  await lua.doString("package.path = '/proj/?.lua;' .. package.path; PROJECT_ROOT = '/proj/'");
  await lua.doFile(`/proj/${entry}`);
} catch (error) {
  console.error(String(error));
  process.exitCode = 1;
} finally {
  lua.global.close();
}
