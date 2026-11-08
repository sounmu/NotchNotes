import test from 'node:test';
import assert from 'node:assert/strict';
import { toEditorMarkdown, toStorageMarkdown } from '../src/markdown-codec.js';

test('local images and wiki links round-trip Unicode identities', () => {
  const source = 'before ![[한글 image|123-abc]] and [[노트 이름|456]] after';
  const rendered = toEditorMarkdown(source);
  assert.match(rendered, /notchnotes-image:/);
  assert.match(rendered, /notchnotes-wiki:/);
  assert.equal(toStorageMarkdown(rendered), source);
});
test('code and escaped examples stay literal', () => {
  for (const source of ['`![[literal]]`', '```md\n![[literal]]\n[[link]]\n```', '\\![[literal]]', '\\[[literal]]']) {
    assert.equal(toEditorMarkdown(source), source);
  }
});
test('ordinary Markdown images and links are preserved', () => {
  const source = '![alt](https://example.com/image.png) [link](https://example.com)';
  assert.equal(toStorageMarkdown(toEditorMarkdown(source)), source);
});
