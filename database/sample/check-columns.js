#!/usr/bin/env node
// Static check of the sample SQL against the schema (no database needed):
//   node database/sample/check-columns.js
// Parses CREATE TABLE in 01_schema.sql and every INSERT in 20_seed_reference.sql, 25_sample_masters.sql (if any)
// and 30_sample_data.sql, then verifies:
//   - every table and column exists; generated columns are never inserted
//   - ENUM columns only get allowed literals
//   - NOT NULL columns without a default are always given, and never as a literal NULL
//   - primary keys are unique (literal values)
//   - foreign keys point at a row inserted EARLIER (or in an earlier file) — literal values only
const fs = require('fs');
const path = require('path');

const DB = path.join(__dirname, '..');

function parseSchema() {
  const sql = fs.readFileSync(path.join(DB, '01_schema.sql'), 'utf8');
  const tables = {};
  const re = /CREATE TABLE (\w+) \(([\s\S]*?)\n\) ENGINE/g;
  let m;
  while ((m = re.exec(sql))) {
    const t = { name: m[1], cols: {}, pk: [], fks: [] };
    for (let line of m[2].split('\n')) {
      line = line.replace(/--.*$/, '').trim().replace(/,$/, '');
      if (!line) continue;
      let k;
      if ((k = /^PRIMARY KEY \(([^)]+)\)/.exec(line))) t.pk = k[1].split(',').map((s) => s.trim().replace(/`/g, ''));
      else if ((k = /FOREIGN KEY \(([^)]+)\) REFERENCES (\w+) \(([^)]+)\)/.exec(line))) t.fks.push({ cols: k[1].split(',').map((s) => s.trim()), ref: k[2], refCols: k[3].split(',').map((s) => s.trim()) });
      else if (/^(KEY|UNIQUE KEY|CONSTRAINT|CHECK)/.test(line)) { /* index / check */ } else if ((k = /^`?(\w+)`?\s+(\w+)(\(([^)]*)\))?(.*)$/.exec(line))) {
        const [, name, type, , args, rest] = k;
        const col = { type: type.toUpperCase(), notNull: /NOT NULL/.test(rest), hasDefault: /DEFAULT|AUTO_INCREMENT/.test(rest), generated: /GENERATED ALWAYS/.test(rest) };
        if (/CHAR$/.test(col.type)) col.len = Number(args);
        if (col.type === 'ENUM') col.enum = [...args.matchAll(/'([^']*)'/g)].map((x) => x[1]);
        t.cols[name] = col;
      }
    }
    tables[t.name] = t;
  }
  for (const a of sql.matchAll(/ALTER TABLE (\w+) ADD CONSTRAINT \w+ FOREIGN KEY \(([^)]+)\) REFERENCES (\w+) \(([^)]+)\)/g)) {
    tables[a[1]].fks.push({ cols: a[2].split(',').map((s) => s.trim()), ref: a[3], refCols: a[4].split(',').map((s) => s.trim()) });
  }
  return tables;
}

// Split a VALUES list into tuples of raw value texts (handles quotes, '' escapes, backslashes and nested parentheses).
function tuples(s) {
  const out = []; let i = 0;
  while (i < s.length) {
    while (i < s.length && s[i] !== '(') i++;
    if (i >= s.length) break;
    i++; let depth = 0; let cur = ''; const vals = [];
    for (; i < s.length; i++) {
      const c = s[i];
      if (c === "'") {
        cur += c; i++;
        for (; i < s.length; i++) {
          cur += s[i];
          if (s[i] === '\\') { i++; cur += s[i]; continue; }
          if (s[i] === "'") { if (s[i + 1] === "'") { cur += "'"; i++; continue; } break; }
        }
        continue;
      }
      if (c === '(') depth++;
      if (c === ')') { if (depth === 0) { vals.push(cur.trim()); i++; break; } depth--; }
      if (c === ',' && depth === 0) { vals.push(cur.trim()); cur = ''; continue; }
      cur += c;
    }
    out.push(vals);
  }
  return out;
}
const literal = (v) => (/^'.*'$/s.test(v) ? v.slice(1, -1).replace(/''/g, "'").replace(/\\\\/g, '\\') : /^-?\d+(\.\d+)?$/.test(v) ? v : v === 'NULL' ? null : undefined); // undefined = expression

function check({ quiet = false } = {}) {
  const schema = parseSchema();
  const errors = []; const rows = {}; let inserts = 0; let values = 0;
  const files = ['20_seed_reference.sql', '25_sample_masters.sql', '30_sample_data.sql'].filter((f) => fs.existsSync(path.join(DB, f)));
  for (const f of files) {
    const sql = fs.readFileSync(path.join(DB, f), 'utf8').replace(/^\s*--.*$/gm, '');
    for (const st of sql.split(/;\s*\n/)) {
      const m = /INSERT INTO (\w+) \(([^)]+)\) VALUES([\s\S]*?)(ON DUPLICATE KEY UPDATE[\s\S]*)?$/.exec(st.trim());
      if (!m) continue;
      inserts++;
      const [, table, colText, body, upsert] = m;
      const t = schema[table];
      if (!t) { errors.push(`${f}: unknown table ${table}`); continue; }
      const cols = colText.split(',').map((c) => c.trim().replace(/`/g, ''));
      for (const c of cols) {
        if (!t.cols[c]) errors.push(`${f}: ${table}.${c} does not exist`);
        else if (t.cols[c].generated) errors.push(`${f}: ${table}.${c} is a generated column`);
      }
      for (const [c, col] of Object.entries(t.cols)) if (col.notNull && !col.hasDefault && !col.generated && !cols.includes(c)) errors.push(`${f}: ${table}.${c} is NOT NULL without default but not inserted`);
      for (const vals of tuples(body)) {
        values++;
        if (vals.length !== cols.length) { errors.push(`${f}: ${table} tuple has ${vals.length} values for ${cols.length} columns: ${vals.slice(0, 2).join(',')}`); continue; }
        const row = {};
        cols.forEach((c, i) => { row[c] = literal(vals[i]); });
        for (const c of cols) {
          const col = t.cols[c]; if (!col) continue;
          if (vals[cols.indexOf(c)] === 'NULL' && col.notNull) errors.push(`${f}: ${table}.${c} NULL into NOT NULL column`);
          if (col.enum && row[c] != null && row[c] !== undefined && !col.enum.includes(row[c])) errors.push(`${f}: ${table}.${c} '${row[c]}' not in ENUM(${col.enum.join('|')})`);
          if (col.len && typeof row[c] === 'string' && [...row[c]].length > col.len) errors.push(`${f}: ${table}.${c} value longer than ${col.len}: ${row[c].slice(0, 40)}`);
        }
        // PK uniqueness
        if (t.pk.length && t.pk.every((c) => row[c] !== undefined && row[c] !== null)) {
          const key = t.pk.map((c) => row[c]).join('|');
          rows[table] ??= { keys: new Set(), list: [] };
          if (rows[table].keys.has(key) && !upsert) errors.push(`${f}: duplicate primary key ${table}(${key})`);
          rows[table].keys.add(key);
        }
        (rows[table] ??= { keys: new Set(), list: [] }).list.push(row);
        // FKs: referenced row must already exist
        for (const fk of t.fks) {
          const v = fk.cols.map((c) => row[c]);
          if (v.some((x) => x === null || x === undefined)) continue;
          const target = rows[fk.ref];
          const found = target && target.list.some((r) => fk.refCols.every((rc, i) => String(r[rc]) === String(v[i])));
          if (!found) errors.push(`${f}: ${table}(${fk.cols.join(',')})=${v.join('|')} → ${fk.ref} not inserted before`);
        }
      }
    }
  }
  if (!quiet) {
    console.log(`check-columns: ${files.join(', ')} — ${inserts} INSERT statements, ${values} rows checked against ${Object.keys(schema).length} tables`);
    if (errors.length) { console.log(`  ${errors.length} problem(s):`); for (const e of errors) console.log(`  ✗ ${e}`); } else console.log('  ✓ tables, columns, generated columns, ENUM values, NOT NULL, lengths, primary keys and foreign-key order all OK');
  }
  return { ok: errors.length === 0, errors };
}

module.exports = { check };
if (require.main === module) process.exitCode = check().ok ? 0 : 1;
