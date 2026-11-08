import { unified } from 'unified';
import remarkParse from 'remark-parse';
import remarkGfm from 'remark-gfm';
import { visit } from 'unist-util-visit';

const parser = unified().use(remarkParse).use(remarkGfm);
const prefix = image => image ? 'notchnotes-image://asset/' : 'notchnotes-wiki://note/';
export function referenceURL(value, image = true) { return prefix(image) + encodeURIComponent(value); }

function rewrite(source, edits) {
  for (const { start, end, value } of edits.sort((a, b) => b.start - a.start)) {
    source = source.slice(0, start) + value + source.slice(end);
  }
  return source;
}

// Work only in Markdown text nodes: fenced code and inline code remain literal.
export function toEditorMarkdown(source) {
  const edits = [];
  visit(parser.parse(source), 'text', node => {
    const start = node.position.start.offset;
    const raw = source.slice(start, node.position.end.offset);
    for (const match of raw.matchAll(/(!?)\[\[([^\]\n]+)\]\]/g)) {
      const slashes = raw.slice(0, match.index).match(/\\+$/)?.[0].length ?? 0;
      if (slashes % 2) continue;
      const image = match[1] === '!';
      const label = match[2].split('|')[0].replace(/[\[\]\\]/g, '\\$&');
      edits.push({ start: start + match.index, end: start + match.index + match[0].length,
        value: `${image ? '!' : ''}[${label}](${referenceURL(match[2], image)})` });
    }
  });
  return rewrite(source, edits);
}

export function toStorageMarkdown(source) {
  const edits = [];
  visit(parser.parse(source), node => {
    const image = node.type === 'image';
    if (!image && node.type !== 'link') return;
    if (!node.url?.startsWith(prefix(image))) return;
    let reference;
    try { reference = decodeURIComponent(node.url.slice(prefix(image).length)); } catch { return; }
    if (!reference || /[\]\n\r]/.test(reference)) return;
    edits.push({ start: node.position.start.offset, end: node.position.end.offset,
      value: `${image ? '!' : ''}[[${reference}]]` });
  });
  return rewrite(source, edits);
}
