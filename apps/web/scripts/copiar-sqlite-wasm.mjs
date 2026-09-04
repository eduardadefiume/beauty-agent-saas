// O leitor de SQLite roda no navegador do dono, e o wasm dele precisa ser
// servido pelo site. Copiar de node_modules na hora do build é melhor que
// versionar 650 KB de binário no repositório, e melhor que buscar de uma CDN:
// abrir o backup não pode depender de um terceiro estar no ar.
import { copyFileSync, mkdirSync } from 'node:fs';
import { createRequire } from 'node:module';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const require = createRequire(import.meta.url);
const daqui = dirname(fileURLToPath(import.meta.url));
const destino = join(daqui, '..', 'public');

mkdirSync(destino, { recursive: true });
const origem = join(dirname(require.resolve('sql.js')), 'sql-wasm.wasm');
copyFileSync(origem, join(destino, 'sql-wasm.wasm'));
console.log('sql-wasm.wasm copiado para public/');
