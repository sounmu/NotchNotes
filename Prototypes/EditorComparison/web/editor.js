import { Crepe } from '@milkdown/crepe';
import { replaceAll } from '@milkdown/kit/utils';
import { editorViewCtx } from '@milkdown/kit/core';
import { undo, redo, closeHistory } from '@milkdown/kit/prose/history';
import '@milkdown/crepe/theme/common/style.css';
import '@milkdown/crepe/theme/frame-dark.css';
import './style.css';

const send = (kind, data = {}) => window.webkit.messageHandlers.lab.postMessage({ kind, ...data });
const painted = () => new Promise((resolve, reject) => {
  const deadline = setTimeout(() => reject(new Error(`Frame wait timed out (visibility=${document.visibilityState})`)), 3000);
  requestAnimationFrame(() => requestAnimationFrame(() => {
    clearTimeout(deadline);
    resolve();
  }));
});
let crepe;
let documentID = '';
let replacing = false;
const diagnostics = { changes: 0, accepted: 0 };
window.addEventListener('error', event => send('error', { message: event.message }));
window.addEventListener('unhandledrejection', event => send('error', { message: String(event.reason) }));

window.lab = {
  async load(id, markdown) {
    replacing = true;
    documentID = id;
    if (!crepe) {
      crepe = new Crepe({ root: document.getElementById('editor'), defaultValue: markdown });
      crepe.on(listener => listener.markdownUpdated((_ctx, markdown) => {
        diagnostics.changes++;
        const current = crepe.getMarkdown();
        diagnostics.matches = markdown === current;
        // replaceAll(..., true) reuses plugins. A debounced transaction from
        // the outgoing note may still arrive after its EditorState is replaced.
        // Only serialize the document that is actually installed in this view.
        // Compare serialized content: plugins can append non-Markdown node
        // attributes after the transaction captured by the listener.
        if (!replacing && markdown === current) {
          diagnostics.accepted++;
          send('change', { id: documentID, markdown: current });
        }
      }));
      await crepe.create();
    } else {
      crepe.editor.action(replaceAll(markdown, true));
    }
    replacing = false;
    await painted();
    send('ready', { id, markdown: crepe.getMarkdown() });
  },
  markdown() { return crepe.getMarkdown(); },
  diagnostics() { return diagnostics; },
  async type(text) {
    const start = performance.now();
    crepe.editor.action(ctx => {
      const view = ctx.get(editorViewCtx);
      view.dispatch(view.state.tr.insertText(text));
      view.focus();
    });
    await painted();
    return performance.now() - start;
  },
  async smoke() {
    const view = crepe.editor.action(ctx => ctx.get(editorViewCtx));
    const before = crepe.getMarkdown();
    const checkbox = document.querySelector('.label.unchecked')?.closest('.label-wrapper');
    if (!checkbox) throw new Error('No rendered task checkbox found');
    // DOM event path, not a direct Markdown mutation or command.
    checkbox.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
    await painted();
    const checked = crepe.getMarkdown();
    checkbox.dispatchEvent(new PointerEvent('pointerdown', { bubbles: true, cancelable: true }));
    await painted();
    const unchecked = crepe.getMarkdown();
    view.dispatch(closeHistory(view.state.tr).insertText('테스트😀'));
    const typed = crepe.getMarkdown();
    undo(view.state, view.dispatch);
    const undone = crepe.getMarkdown();
    redo(view.state, view.dispatch);
    const redone = crepe.getMarkdown();
    return { checkboxFound: true, checked: checked !== before && checked.includes('[x]'),
      unchecked: unchecked === before, undo: undone === before, redo: redone === typed,
      unicode: typed.includes('테스트😀'), before, after: redone };
  },
};
send('loaded');
