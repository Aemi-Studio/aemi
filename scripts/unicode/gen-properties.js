// Generates Sources/AemiUnicode/Generated/UnicodePropertyTables.swift from node's own RegExp: the binary properties and Script_Extensions that
// Go's unicode package does not have, and the aliases (short property names, four-letter script codes). Using node as the source means the
// tables carry exactly the Unicode version of the oracle ECMAScript patterns are checked against.
//   node scripts/unicode/gen-properties.js > Sources/AemiUnicode/Generated/UnicodePropertyTables.swift
// No recursion: every walk is a loop.
'use strict';
const fs = require('node:fs');
const path = require('node:path');

const binary = `ASCII ASCII_Hex_Digit Alphabetic Any Assigned Bidi_Control Bidi_Mirrored Case_Ignorable Cased Changes_When_Casefolded
Changes_When_Casemapped Changes_When_Lowercased Changes_When_NFKC_Casefolded Changes_When_Titlecased Changes_When_Uppercased Dash
Default_Ignorable_Code_Point Deprecated Diacritic Emoji Emoji_Component Emoji_Modifier Emoji_Modifier_Base Emoji_Presentation
Extended_Pictographic Extender Grapheme_Base Grapheme_Extend Hex_Digit IDS_Binary_Operator IDS_Trinary_Operator ID_Continue ID_Start
Ideographic Join_Control Logical_Order_Exception Lowercase Math Noncharacter_Code_Point Pattern_Syntax Pattern_White_Space Quotation_Mark
Radical Regional_Indicator Sentence_Terminal Soft_Dotted Terminal_Punctuation Unified_Ideograph Uppercase Variation_Selector White_Space
XID_Continue XID_Start`.split(/\s+/);

// Candidate aliases (PropertyAliases.txt); each is kept only if node accepts it and it denotes the same set as its canonical name.
const aliasCandidates = {
  Alpha: 'Alphabetic', AHex: 'ASCII_Hex_Digit', Bidi_C: 'Bidi_Control', Bidi_M: 'Bidi_Mirrored', CI: 'Case_Ignorable',
  CWCF: 'Changes_When_Casefolded', CWCM: 'Changes_When_Casemapped', CWKCF: 'Changes_When_NFKC_Casefolded', CWL: 'Changes_When_Lowercased',
  CWT: 'Changes_When_Titlecased', CWU: 'Changes_When_Uppercased', DI: 'Default_Ignorable_Code_Point', Dep: 'Deprecated', Dia: 'Diacritic',
  EBase: 'Emoji_Modifier_Base', EComp: 'Emoji_Component', EMod: 'Emoji_Modifier', EPres: 'Emoji_Presentation', ExtPict: 'Extended_Pictographic',
  Ext: 'Extender', Gr_Base: 'Grapheme_Base', Gr_Ext: 'Grapheme_Extend', Hex: 'Hex_Digit', IDC: 'ID_Continue', IDS: 'ID_Start',
  IDSB: 'IDS_Binary_Operator', IDST: 'IDS_Trinary_Operator', Ideo: 'Ideographic', Join_C: 'Join_Control', LOE: 'Logical_Order_Exception',
  Lower: 'Lowercase', NChar: 'Noncharacter_Code_Point', Pat_Syn: 'Pattern_Syntax', Pat_WS: 'Pattern_White_Space', QMark: 'Quotation_Mark',
  RI: 'Regional_Indicator', SD: 'Soft_Dotted', STerm: 'Sentence_Terminal', Term: 'Terminal_Punctuation', UIdeo: 'Unified_Ideograph',
  Upper: 'Uppercase', VS: 'Variation_Selector', WSpace: 'White_Space', space: 'White_Space', XIDC: 'XID_Continue', XIDS: 'XID_Start',
};

function ranges(re) {
  const out = [];
  let start = -1;
  for (let cp = 0; cp <= 0x10FFFF; cp++) {
    const hit = re.test(String.fromCodePoint(cp));
    if (hit && start < 0) start = cp;
    if (!hit && start >= 0) { out.push(start, cp - 1); start = -1; }
  }
  if (start >= 0) out.push(start, 0x10FFFF);
  return out;
}

const tablesPath = path.join(__dirname, '..', '..', 'Sources', 'AemiUnicode', 'Generated', 'UnicodeDataTables.swift');
const scripts = /scriptNames = """\n([\s\S]*?)"""/.exec(fs.readFileSync(tablesPath, 'utf8'))[1].trim().split(/\s+/);

const key = (r) => r.join(',');
const binaryData = [];
const binaryOffsets = [0];
const byKey = new Map();
for (const name of binary) {
  const r = ranges(new RegExp(`^\\p{${name}}$`, 'u'));
  byKey.set(name, key(r));
  binaryData.push(...r);
  binaryOffsets.push(binaryData.length / 2);
}
const aliases = [];
for (const [alias, canonical] of Object.entries(aliasCandidates)) {
  let re;
  try { re = new RegExp(`^\\p{${alias}}$`, 'u'); } catch { continue; }
  if (key(ranges(re)) === byKey.get(canonical)) aliases.push(`${alias}=${canonical}`);
}

const scxData = [];
const scxOffsets = [0];
const scxByKey = new Map();
for (const name of scripts) {
  const r = ranges(new RegExp(`^\\p{scx=${name}}$`, 'u'));
  scxByKey.set(key(r), name);
  scxData.push(...r);
  scxOffsets.push(scxData.length / 2);
}
// Four-letter script codes: every title-case candidate that node accepts and that names the same set as a script.
const codes = [];
const upper = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
const lower = upper.toLowerCase();
for (const a of upper) for (const b of lower) for (const c of lower) for (const d of lower) {
  const code = a + b + c + d;
  let re;
  try { re = new RegExp(`^\\p{scx=${code}}$`, 'u'); } catch { continue; }
  const found = scxByKey.get(key(ranges(re)));
  if (found) codes.push(`${code}=${found}`);
}

const wrap = (words) => {
  const lines = [];
  let line = '';
  for (const w of words) {
    if ((line + ' ' + w).length > 110) { lines.push(line); line = w; } else line = line ? line + ' ' + w : w;
  }
  if (line) lines.push(line);
  return lines.map((l) => '        ' + l).join('\n');
};
// swift-format wants a literal of seven digits or more grouped by thousands.
const literal = (n) => (n >= 1000000 ? String(n).replace(/\B(?=(\d{3})+$)/g, '_') : String(n));
const numbers = (xs) => {
  const lines = [];
  for (let i = 0; i < xs.length; i += 12) lines.push('        ' + xs.slice(i, i + 12).map(literal).join(', '));
  return lines.join(',\n');
};

process.stdout.write(`// Generated by scripts/unicode/gen-properties.js from node ${process.version} (Unicode ${process.versions.unicode}). Do not edit; regenerate with
//   node scripts/unicode/gen-properties.js > Sources/AemiUnicode/Generated/UnicodePropertyTables.swift
// Binary properties, Script_Extensions and their aliases, which Go's unicode package (the source of UnicodeDataTables) lacks.

enum UnicodePropertyTables {
    static let unicodeVersion = "${process.versions.unicode}"

    /// The binary properties, in the order of \`binaryOffsets\`.
    static let binaryNames = """
${wrap(binary)}
        """

    /// Range index at which each binary property starts in \`binaryData\`, and the end.
    static let binaryOffsets: [Int] = [
${numbers(binaryOffsets)}
    ]

    /// Inclusive \`lo, hi\` pairs, property after property.
    static let binaryData: [UInt32] = [
${numbers(binaryData)}
    ]

    /// \`alias=Canonical\` for the short names of binary properties.
    static let binaryAliases = """
${wrap(aliases)}
        """

    /// Range index at which the Script_Extensions of each script (in the order of \`UnicodeDataTables.scriptNames\`) starts, and the end.
    static let scriptExtensionOffsets: [Int] = [
${numbers(scxOffsets)}
    ]

    /// Inclusive \`lo, hi\` pairs, script after script.
    static let scriptExtensionData: [UInt32] = [
${numbers(scxData)}
    ]

    /// \`Code=Script\` for the four-letter script codes.
    static let scriptCodes = """
${wrap(codes)}
        """
}
`);
process.stderr.write(`${binary.length} binary properties, ${aliases.length} aliases, ${scripts.length} scripts, ${codes.length} codes, ${(binaryData.length + scxData.length) / 2} ranges\n`);
