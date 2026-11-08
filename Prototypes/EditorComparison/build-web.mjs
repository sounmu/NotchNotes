import { build } from 'esbuild';
import { mkdir, writeFile, readFile, readdir, rm } from 'node:fs/promises';

const outdir = 'Sources/EditorComparison/Web';
await rm(outdir, { recursive: true, force: true });
await mkdir(outdir, { recursive: true });
const result = await build({
  entryPoints: ['web/editor.js'], bundle: true, minify: true,
  format: 'iife', target: 'safari17', outdir, metafile: true,
  loader: { '.woff2': 'file', '.woff': 'file', '.ttf': 'file' },
  legalComments: 'linked',
});
// Crepe's theme imports Google fonts. Keep the prototype entirely local;
// use the system font and ship the bundled KaTeX fonts where needed.
const css = await readFile(`${outdir}/editor.css`, 'utf8');
await writeFile(`${outdir}/editor.css`, css.replace(/@import\s+url\([^)]*\);?/g, ''));
await writeFile(`${outdir}/index.html`, `<!doctype html>
<html><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<meta http-equiv="Content-Security-Policy" content="default-src 'self'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self' data:; connect-src 'none'">
<link rel="stylesheet" href="editor.css"></head>
<body><div id="editor"></div><script src="editor.js"></script></body></html>`);
await writeFile('web-build-meta.json', JSON.stringify(result.metafile, null, 2));
const packages = new Set(Object.keys(result.metafile.inputs).flatMap(path => {
  const match = path.match(/^node_modules\/(@[^/]+\/[^/]+|[^/]+)/);
  return match ? [match[1]] : [];
}));
const notices = [];
for (const name of [...packages].sort()) {
  const root = `node_modules/${name}`;
  const metadata = JSON.parse(await readFile(`${root}/package.json`, 'utf8'));
  const files = (await readdir(root)).filter(file => /^(license|licence|copying|notice)(\.|$)/i.test(file));
  notices.push(`\n--- ${name}@${metadata.version} (${metadata.license}) ---\n`);
  for (const file of files) notices.push(await readFile(`${root}/${file}`, 'utf8'));
}
await writeFile(`${outdir}/THIRD_PARTY_NOTICES.txt`, notices.join('\n'));
