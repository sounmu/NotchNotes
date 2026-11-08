import { Crepe } from '@milkdown/crepe';
import { editorViewCtx } from '@milkdown/kit/core';
import { $prose, replaceAll } from '@milkdown/kit/utils';
import { Plugin, TextSelection } from '@milkdown/kit/prose/state';
import { toggleMark, lift, wrapIn } from '@milkdown/kit/prose/commands';
import { liftListItem, wrapInList } from '@milkdown/kit/prose/schema-list';
import { undo, redo } from '@milkdown/kit/prose/history';
import { toEditorMarkdown, toStorageMarkdown } from './markdown-codec.js';
import '@milkdown/crepe/theme/common/style.css';
import '@milkdown/crepe/theme/frame-dark.css';
import './style.css';

let crepe, identity, rawSource = '', lastSerialized = '', revision = 0, suppress = true;
let cachedSource = '', dirty = false, scheduled = false;
let serializedDoc;
const documents = new Map();
const send = (kind, data = {}) => window.webkit.messageHandlers.editor.postMessage({ kind, ...data });
const view = () => crepe.editor.action(ctx => ctx.get(editorViewCtx));
const serialize = () => toStorageMarkdown(crepe.getMarkdown());

function formatting(state) {
  const { from, to, empty, $from } = state.selection;
  const active = [], mixed = [];
  for (const [name, markName] of [['bold', 'strong'], ['italic', 'emphasis'], ['strikethrough', 'strike_through'], ['inlineCode', 'inlineCode']]) {
    const type = state.schema.marks[markName];
    if (!type) continue;
    if (empty) {
      if (type.isInSet(state.storedMarks ?? $from.marks())) active.push(name);
    } else {
      let on = 0, off = 0;
      state.doc.nodesBetween(from, to, node => {
        if (node.isText) { if (type.isInSet(node.marks)) on++; else off++; }
      });
      if (on) (off ? mixed : active).push(name);
    }
  }
  return { active, mixed };
}

function snapshot() {
  const state = view().state;
  if (state.doc !== serializedDoc) {
    const current = serialize();
    if (current !== lastSerialized) { cachedSource = current; dirty = true; lastSerialized = current; }
    serializedDoc = state.doc;
  }
  return { ...identity, revision: ++revision, markdown: dirty ? cachedSource : rawSource,
    selection: { anchor: state.selection.anchor, head: state.selection.head }, ...formatting(state) };
}

function publish() {
  if (!crepe || suppress || !identity) return;
  send('snapshot', snapshot());
}

// Publish from the installed view state, after appended transactions. No 200ms
// listener delay; note identity travels with each snapshot across the bridge.
const bridge = $prose(() => new Plugin({ view: () => ({ update: (current, previous) => {
  if (suppress || (current.state.doc.eq(previous.doc) && current.state.selection.eq(previous.selection)
      && current.state.storedMarks === previous.storedMarks)) return;
  if (!scheduled) {
    scheduled = true;
    queueMicrotask(() => { scheduled = false; publish(); });
  }
} }) }));

async function upload(file) {
  const data = await new Promise((resolve, reject) => {
    const reader = new FileReader(); reader.onload = () => resolve(String(reader.result).split(',')[1]);
    reader.onerror = reject; reader.readAsDataURL(file);
  });
  return window.webkit.messageHandlers.imageUpload.postMessage({ data, name: file.name });
}

window.notchEditor = {
  async setDocument(next) {
    let outgoing = null;
    if (crepe && identity) {
      outgoing = snapshot();
      documents.set(identity.id, { state: view().state, source: outgoing.markdown, scrollY: window.scrollY });
    }
    suppress = true;
    identity = { id: next.id, generation: next.generation };
    revision = 0; rawSource = next.markdown; cachedSource = rawSource; dirty = false;
    if (!crepe) {
      crepe = new Crepe({ root: document.getElementById('editor'), defaultValue: toEditorMarkdown(next.markdown),
        features: { [Crepe.Feature.AI]: false },
        featureConfigs: { [Crepe.Feature.ImageBlock]: { onUpload: upload },
          [Crepe.Feature.Placeholder]: { text: 'Start typing…' } } });
      crepe.editor.use(bridge);
      await crepe.create();
    } else {
      const cached = documents.get(next.id);
      if (cached && cached.source === next.markdown) view().updateState(cached.state);
      else crepe.editor.action(replaceAll(toEditorMarkdown(next.markdown), true));
    }
    lastSerialized = serialize();
    serializedDoc = view().state.doc;
    const cached = documents.get(next.id);
    if (!cached || cached.source !== next.markdown) {
      const state = view().state;
      const selection = next.selection;
      if (selection) {
        const limit = state.doc.content.size;
        const anchor = Math.max(0, Math.min(selection.anchor, limit));
        const head = Math.max(0, Math.min(selection.head, limit));
        view().dispatch(state.tr.setSelection(TextSelection.between(state.doc.resolve(anchor), state.doc.resolve(head))));
      }
    }
    window.scrollTo(0, cached?.source === next.markdown ? cached.scrollY : 0);
    suppress = false;
    // No rAF readiness dependency: the notch window may be hidden during load.
    return { outgoing, current: snapshot() };
  },
  flush() { return crepe ? snapshot() : null; },
  focus() { if (crepe) view().focus(); },
  forget(ids) { for (const id of documents.keys()) if (!ids.includes(id)) documents.delete(id); },
  command(name, value, expectedID) {
    if (!crepe || (expectedID && identity.id !== expectedID)) return false;
    const editor = view(); editor.focus();
    const { schema, selection } = editor.state;
    const marks = { bold: 'strong', italic: 'emphasis', strikethrough: 'strike_through', inlineCode: 'inlineCode' };
    let handled = false;
    if (marks[name]) handled = toggleMark(schema.marks[marks[name]])(editor.state, editor.dispatch);
    else if (name === 'undo' || name === 'redo') handled = (name === 'undo' ? undo : redo)(editor.state, editor.dispatch);
    else if (name === 'link') {
      const type = schema.marks.link;
      let tr = editor.state.tr;
      if (selection.empty) tr = tr.insertText('link text').setSelection(TextSelection.create(tr.doc, selection.from, selection.from + 9));
      tr.addMark(tr.selection.from, tr.selection.to, type.create({ href: value ?? 'https://' }));
      editor.dispatch(tr); handled = true;
    } else if (name === 'quote') {
      let inside = false;
      for (let depth = selection.$from.depth; depth > 0; depth--) if (selection.$from.node(depth).type === schema.nodes.blockquote) inside = true;
      handled = (inside ? lift : wrapIn(schema.nodes.blockquote))(editor.state, editor.dispatch);
    } else if (['unorderedList', 'orderedList', 'todoList'].includes(name)) {
      const type = name === 'orderedList' ? schema.nodes.ordered_list : schema.nodes.bullet_list;
      let listDepth = 0;
      for (let d = selection.$from.depth; d > 0; d--) if (['bullet_list', 'ordered_list'].includes(selection.$from.node(d).type.name)) { listDepth = d; break; }
      if (listDepth) {
        const list = selection.$from.node(listDepth);
        const item = selection.$from.node(listDepth + 1);
        const same = list.type === type && (name === 'todoList' ? item.attrs.checked != null : item.attrs.checked == null);
        if (same) handled = liftListItem(schema.nodes.list_item)(editor.state, editor.dispatch);
        else {
          const start = selection.$from.before(listDepth);
          let tr = editor.state.tr.setNodeMarkup(start, type);
          list.forEach((child, offset) => {
            tr = tr.setNodeMarkup(start + 1 + offset, undefined, { ...child.attrs,
              listType: name === 'orderedList' ? 'ordered' : 'bullet', checked: name === 'todoList' ? false : null });
          });
          editor.dispatch(tr); handled = true;
        }
      } else {
        handled = wrapInList(type)(editor.state, editor.dispatch);
        if (handled && name === 'todoList') {
          const { $from } = editor.state.selection;
          let depth = $from.depth;
          while (depth > 0 && $from.node(depth).type !== type) depth--;
          const list = $from.node(depth), start = $from.before(depth);
          let tr = editor.state.tr;
          list.forEach((child, offset) => { tr = tr.setNodeMarkup(start + 1 + offset, undefined, { ...child.attrs, checked: false }); });
          editor.dispatch(tr);
        }
      }
    } else if (name === 'insertImage') {
      const type = schema.nodes['image-block'] ?? schema.nodes.image;
      editor.dispatch(editor.state.tr.replaceSelectionWith(type.create({ src: value })));
      handled = true;
    }
    publish(); return handled;
  },
  // Native integration tests use the installed editor, real transactions and DOM events.
  testAction(action, value) {
    const editor = view();
    if (action === 'insert') editor.dispatch(editor.state.tr.insertText(value));
    if (action === 'select') editor.dispatch(editor.state.tr.setSelection(TextSelection.create(editor.state.doc, value.anchor, value.head)));
    if (action === 'checkbox') document.querySelector('.label.unchecked, .label.checked')?.closest('.label-wrapper')
      ?.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
    publish(); return snapshot();
  },
};
window.addEventListener('error', event => send('error', { message: event.message }));
window.addEventListener('unhandledrejection', event => send('error', { message: String(event.reason) }));
window.addEventListener('blur', publish);
document.addEventListener('compositionend', () => queueMicrotask(publish));
send('loaded');
