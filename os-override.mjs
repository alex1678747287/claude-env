// os-override.mjs - ESM wrapper for os-override.js
// Loaded via NODE_OPTIONS="--import /path/to/os-override.mjs"
// Required because --require does not work with ESM entry points (Node.js 20+)

import { createRequire } from 'module';
import { fileURLToPath } from 'url';
import { dirname, join } from 'path';

const __dirname = dirname(fileURLToPath(import.meta.url));
const require = createRequire(import.meta.url);

// Load the CJS module which does all the actual patching
require(join(__dirname, 'os-override.js'));
