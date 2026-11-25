// Makes tests/data/mention.expected from tests/data/mention-cases.txt by running the official extension's own
// functions (webview/index.js: oTt, tTt, HEn, uW, JH, eEt; WV@5183225, @5184104-5185300, @5208957-5210900 in 2.1.328), so the mention
// rules in src/app/agentmention.s are checked against the bundle, not against a reading of it.
//   node tools/mention-cases.js BUNDLE/webview/index.js < tests/data/mention-cases.txt > tests/data/mention.expected
// A case line is "text PATH<TAB>L0<TAB>L1" (the mention rhun writes for a path and lines; L0 0: none) or
// "chips PROMPT" (the chips of a sent prompt; \n in PROMPT is a line feed, \t a tab).
const fs = require('fs');
const s = fs.readFileSync(process.argv[2], 'utf8');
function slice(from, to) {
    const a = s.indexOf(from), b = s.indexOf(to, a);
    if (a < 0 || b < 0) throw new Error('not found: ' + from);
    return s.slice(a, b);
}
const src = slice('var eTt=', 'function sTt(') + slice('function HEn(', 'function WEn(') +
    slice('function JH(', 'function S8e(') + slice('function YR(', 'Le();Le();var L6n');
const api = new Function(src + '; return {oTt, tTt, HEn, uW, JH};')();
const unesc = (t) => t.replace(/\\n/g, '\n').replace(/\\t/g, '\t').replace(/\\\\/g, '\\');
const esc = (t) => t.replace(/\\/g, '\\\\').replace(/\n/g, '\\n').replace(/\t/g, '\\t');
const out = [];
for (const line of fs.readFileSync(0, 'utf8').split('\n')) {
    if (line.startsWith('text ')) {
        const [p, a, b] = line.slice(5).split('\t');
        const l0 = +a, l1 = +b;
        // rhun's suffix: finding 42, "#L2-3" is the form that attaches just those lines
        const suffix = l0 ? (l1 && l1 !== l0 ? `#L${l0}-${l1}` : `#L${l0}`) : '';
        const r = api.oTt(unesc(p), suffix);
        out.push(r === null ? 'refused' : esc(r));
    } else if (line.startsWith('chips ')) {
        const e = unesc(line.slice(6));
        const parts = [];
        for (const o of e.matchAll(api.tTt)) {
            const r = o[0], t = o[1], at = o.index + (r.length - t.length), c = api.uW(t.slice(1));
            const term = c.startsWith('terminal:'), browser = c.startsWith('browser:');
            if (!term && !browser && !api.HEn(c) || c.endsWith(' (agent)')) continue;
            if (browser) continue;                      // phase 7: never a chip in rhun
            const q = t.startsWith('@"') && t.length >= 3 && t.endsWith('"') ? 1 : 0;
            let target = c, a = 0, b = 0;
            if (!term) {
                const h = api.JH(c);
                if (h) { target = h.filePath; a = h.startLine || 0; b = h.endLine || 0; }
            }
            const bs = Buffer.byteLength(e.slice(0, at)), be = bs + Buffer.byteLength(t);
            parts.push(`${term ? 2 : 1}:${q}:${bs}-${be}:${esc(target)}:${a}:${b}`);
        }
        out.push(parts.length ? parts.join(' ') : '-');
    }
}
process.stdout.write(out.join('\n') + '\n');
