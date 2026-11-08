import { build } from 'esbuild';
import { mkdir, writeFile, readFile, readdir, rm } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
process.chdir(fileURLToPath(new URL('.', import.meta.url)));
const outdir = '../Sources/NotchNotes/Resources/Crepe';
await rm(outdir, { recursive: true, force: true });
await mkdir(outdir, { recursive: true });
const result = await build({ entryPoints: ['src/editor.js'], bundle: true, minify: true,
  format: 'iife', target: 'safari17', outdir, metafile: true,
  loader: { '.woff2': 'file', '.woff': 'file', '.ttf': 'file' }, legalComments: 'linked' });
const css = await readFile(`${outdir}/editor.css`, 'utf8');
await writeFile(`${outdir}/editor.css`, css.replace(/@import\s+url\([^)]*\);?/g, ''));
await writeFile(`${outdir}/index.html`, `<!doctype html>
<html><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob: notchnotes-image: https:; font-src 'self' data:; connect-src 'none'">
<link rel="stylesheet" href="editor.css"></head>
<body><div id="editor"></div><script src="editor.js"></script></body></html>`);
const packages = new Set(Object.keys(result.metafile.inputs).flatMap(path => {
  const match = path.match(/^node_modules\/(@[^/]+\/[^/]+|[^/]+)/);
  return match ? [match[1]] : [];
}));
const notices = ['Bundled editor: Milkdown Crepe 7.23.0. Generated with npm ci && npm run build in WebEditor.'];
for (const name of [...packages].sort()) {
  const root = `node_modules/${name}`;
  const metadata = JSON.parse(await readFile(`${root}/package.json`, 'utf8'));
  notices.push(`\n--- ${name}@${metadata.version} (${metadata.license}) ---\n`);
  for (const file of (await readdir(root)).filter(file => /^(license|licence|copying|notice)(\.|$)/i.test(file))) {
    notices.push(await readFile(`${root}/${file}`, 'utf8'));
  }
}
await writeFile(`${outdir}/THIRD_PARTY_NOTICES.txt`, notices.join('\n'));
