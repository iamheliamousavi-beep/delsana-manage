/* postimport.js — pure parsing + matching for the post-office PDF import.
   No DOM, no Supabase, no pdf.js inside: the caller passes pdf.js
   getTextContent() items; tests.html runs this file from file:// too.
   Exposed as window.PostImport (classic script, loaded before screens.js). */
(function (root) {
  'use strict';

  /* ---------------------------------------------------------- constants */
  var BARCODE_LEN = 24;   /* the postal barcode is always 24 digits */
  var Y_TOL = 3;          /* line-grouping tolerance in PDF units */
  var NAME_EXACT = 3;     /* PDF name == last word(s) of the customer */
  var NAME_FULL = 2.5;    /* any whole word of the customer, or the full name */
  var NAME_NEAR = 2;      /* edit distance <= 1 against the surname */
  var NAME_SUB = 1;       /* substring either way (min length 3) */
  var CITY_IN = 2;        /* city appears inside the address */
  var CITY_NEAR = 1;      /* edit distance <= 1 on an address word */
  var GREEN_MIN = 4.5;    /* best total for a green verdict */
  var GAP_MIN = 1;        /* green also needs this gap to the runner-up */
  var YELLOW_MIN = 2;     /* >= this is at least yellow */
  var FIFO_BONUS = 0.2;   /* display sort only — never changes a verdict */
  var TOP_N = 5;          /* candidates returned per row */
  var SUSPECT_DIGITS = 20;/* digit-run shorter than this is never a barcode */

  /* known header labels, space-free (canon form) */
  var LABELS = [
    'بارکد', 'مقصد', 'نامگ', 'نامف', 'وزن', 'تاریخثبت',
    'عنوانمرسوله', 'خدماتویژه', 'مالیات', 'بیمه', 'کرایهپستی',
    'هزینهکل', 'ردیف'
  ];

  /* ---------------------------------------------------------- text utils */
  /* NFKC folds the Arabic presentation forms these PDFs emit; then the
     Persian-letter unification, digit folding and junk removal of 5.14. */
  function normalizeText(s) {
    if (s === null || s === undefined) return '';
    var t = String(s);
    try { t = t.normalize('NFKC'); } catch (e) { /* very old browsers */ }
    t = t
      .replace(/[يىۍێ]/g, 'ی')            /* ي ى ۍ ێ -> ی */
      .replace(/ك/g, 'ک')                          /* ك -> ک */
      .replace(/[ھەةۀ]/g, 'ه')             /* ھ ە ة ۀ -> ه */
      .replace(/ـ/g, '')                            /* tatweel */
      .replace(/[\u0610-\u061A\u064B-\u065F\u0670\u06D6-\u06ED]/g, '')  /* diacritics only */
      .replace(/[‌‍​-‏⁦-⁩؜﻿]/g, '') /* ZWNJ/ZWJ/marks */
      .replace(/[۰-۹]/g, function (d) {      /* Persian digits */
        return String(d.charCodeAt(0) - 0x06f0);
      })
      .replace(/[٠-٩]/g, function (d) {      /* Arabic-Indic digits */
        return String(d.charCodeAt(0) - 0x0660);
      })
      .replace(/\s+/g, ' ')
      .trim();
    return t;
  }

  /* Comparison form: spaces gone + the lam-alef swap canonicalised on BOTH
     sides (سالاری typed vs ساالری extracted both become سالری). */
  function canon(s) {
    return normalizeText(s).replace(/\s+/g, '').replace(/لا/g, 'ال');
  }

  function rev(s) { return String(s || '').split('').reverse().join(''); }

  function words(s) {
    var t = normalizeText(s);
    return t ? t.split(' ') : [];
  }

  /* Levenshtein distance, for the <= 1 fallbacks. */
  function editDistance(a, b) {
    a = String(a || ''); b = String(b || '');
    if (a === b) return 0;
    if (!a.length) return b.length;
    if (!b.length) return a.length;
    var prev = [], cur = [], i, j;
    for (j = 0; j <= b.length; j++) prev[j] = j;
    for (i = 1; i <= a.length; i++) {
      cur[0] = i;
      for (j = 1; j <= b.length; j++) {
        cur[j] = Math.min(prev[j] + 1, cur[j - 1] + 1,
                          prev[j - 1] + (a.charAt(i - 1) === b.charAt(j - 1) ? 0 : 1));
      }
      for (j = 0; j <= b.length; j++) prev[j] = cur[j];
    }
    return prev[b.length];
  }

  function digitsOf(s) { return normalizeText(s).replace(/[^0-9]/g, ''); }

  /* ------------------------------------------------------------ barcode */
  /* A cell is "digit-only" when its normalised text is nothing but digits
     (Persian/Arabic digits folded, stray marks gone). Runs of consecutive
     digit cells are the barcode/date/weight/row-number groups; only an
     exact 24-digit run is trusted (a weight+money run reaches 30 digits). */
  function digitCellText(cell) {
    var t = normalizeText(cell.str).replace(/\s+/g, '');
    if (t && /^[0-9]+$/.test(t)) return t;
    var r = normalizeText(rev(cell.str)).replace(/\s+/g, '');
    if (r && /^[0-9]+$/.test(r)) return r;
    return null;
  }

  /* Runs are only trusted inside the بارکد column when the header told us
     where it is: a 23-digit broken code must never fuse with the row number
     in the ردیف column into a false 24-digit run. Headerless pages keep the
     pure geometric run rule. */
  function inBarCodeColumn(cell, columns, bcCol) {
    if (!columns) return true;
    if (bcCol && digitsOf(cell.str).length === BARCODE_LEN) return true;
    var col = assignToColumn(cell.x, columns);
    return !!(col && col.label === 'بارکد');
  }

  function barcodeFromRuns(cellsAsc, columns, bcCol) {
    var i = 0;
    while (i < cellsAsc.length) {
      var t = digitCellText(cellsAsc[i]);
      if (t === null || !inBarCodeColumn(cellsAsc[i], columns, bcCol)) { i++; continue; }
      var run = [t], j = i + 1;
      while (j < cellsAsc.length) {
        var t2 = digitCellText(cellsAsc[j]);
        if (t2 === null || !inBarCodeColumn(cellsAsc[j], columns, bcCol)) break;
        run.push(t2); j++;
      }
      var joined = run.join('');
      if (joined.length === BARCODE_LEN) return joined;
      i = j > i ? j : i + 1;
    }
    return null;
  }

  /* Fallback: any single cell that holds exactly 24 consecutive digits. */
  function barcodeFromCell(cell) {
    var d = digitsOf(cell.str);
    if (d.length === BARCODE_LEN) return d;
    var d2 = digitsOf(rev(cell.str));
    if (d2.length === BARCODE_LEN) return d2;
    return null;
  }

  /* Longest run of consecutive digit cells on the line (for the
     "looks like a broken barcode" report). */
  function longestDigitRun(cellsAsc) {
    var best = 0, cur = 0, joined = '', bestJoined = '';
    cellsAsc.forEach(function (c) {
      var t = digitCellText(c);
      if (t === null) { cur = 0; joined = ''; return; }
      cur++; joined += t;
      if (cur > best) { best = cur; bestJoined = joined; }
    });
    return { count: best, digits: bestJoined };
  }

  /* ---------------------------------------------------------- line build */
  function groupLines(items) {
    var lines = [];
    (items || []).forEach(function (it) {
      if (!it || !it.str || !String(it.str).trim()) return;
      var x = it.transform ? it.transform[4] : it.x;
      var y = it.transform ? it.transform[5] : it.y;
      if (typeof x !== 'number' || typeof y !== 'number') return;
      var line = null;
      for (var i = 0; i < lines.length; i++) {
        if (Math.abs(lines[i].y - y) <= Y_TOL) { line = lines[i]; break; }
      }
      if (!line) { line = { y: y, cells: [] }; lines.push(line); }
      line.cells.push({ str: String(it.str), x: x, y: y });
    });
    lines.forEach(function (line) {
      line.cells.sort(function (a, b) { return a.x - b.x; });   /* asc */
    });
    lines.sort(function (a, b) { return b.y - a.y; });          /* top first */
    return lines;
  }

  /* Which way do the cells of this table run? The header line is scored in
     both orientations against the known labels; the logical order with the
     higher score wins, ties keep x-ascending (the common generator). */
  function scoreHeader(cells) {
    var s = cells.map(function (c) { return canon(c.str); }).join('');
    var n = 0;
    for (var i = 0; i < LABELS.length; i++) {
      if (s.indexOf(LABELS[i]) !== -1) n++;
    }
    return n;
  }

  function orientationOf(headerLine) {
    var asc = headerLine.cells;
    var desc = headerLine.cells.slice().reverse();
    return scoreHeader(desc) > scoreHeader(asc) ? 'desc' : 'asc';
  }

  function findHeaderLine(lines) {
    var best = null, bestScore = 0;
    lines.forEach(function (line) {
      var s = line.cells.map(function (c) { return canon(c.str); }).join('');
      if (s.indexOf('بارکد') === -1) return;
      var sc = scoreHeader(line.cells);
      if (sc > bestScore) { best = line; bestScore = sc; }
    });
    return best;
  }

  /* Header cells -> columns. Some generators split a label over two cells
     (نام + گ, تاریخ + ثبت); merge the pieces while the accumulated text is
     still a proper prefix of a known label. */
  function buildColumns(headerLine, orientation) {
    var cells = orientation === 'desc'
      ? headerLine.cells.slice().reverse()
      : headerLine.cells.slice();
    var cols = [], i = 0;
    while (i < cells.length) {
      var acc = canon(cells[i].str);
      var x0 = cells[i].x, x1 = cells[i].x, j = i + 1;
      while (j < cells.length && acc &&
             LABELS.indexOf(acc) === -1 &&
             LABELS.some(function (L) { return L.indexOf(acc) === 0 && L.length > acc.length; })) {
        var next = canon(cells[j].str);
        if (!next) { j++; continue; }
        acc += next;
        x1 = cells[j].x;
        j++;
      }
      if (acc) cols.push({ label: acc, xc: (x0 + x1) / 2 });
      i = j > i ? j : i + 1;
    }
    return cols;
  }

  function assignToColumn(x, columns) {
    var best = null, bestD = Infinity;
    for (var i = 0; i < columns.length; i++) {
      var d = Math.abs(columns[i].xc - x);
      if (d < bestD) { bestD = d; best = columns[i]; }
    }
    return best;
  }

  function lineCellsOriented(line, orientation) {
    return orientation === 'desc'
      ? line.cells.slice().reverse()
      : line.cells.slice();
  }

  /* -------------------------------------------------------------- parse */
  /* input: one page's items, or an array of pages' items.
     returns { rows: [{barcode, recipient, city, date, weight, raw, warnings}],
               skipped: [{raw, reason}] } */
  function parseItems(itemsOrPages) {
    var pages = (itemsOrPages && itemsOrPages.length &&
                 Array.isArray(itemsOrPages[0]))
      ? itemsOrPages
      : [itemsOrPages];
    var rows = [], skipped = [];

    pages.forEach(function (items) {
      var lines = groupLines(items);
      var header = findHeaderLine(lines);
      var orientation = header ? orientationOf(header) : 'asc';
      var columns = header ? buildColumns(header, orientation) : null;

      lines.forEach(function (line) {
        if (header && line === header) return;
        var oriented = lineCellsOriented(line, orientation);
        var raw = line.cells.map(function (c) { return c.str; }).join(' ');

        /* the جمع کل totals row is never a parcel (its label may be split
           across two cells, so join the whole line before testing) */
        var lineJoined = oriented.map(function (c) { return canon(c.str); }).join('');
        if (lineJoined.indexOf('جمعکل') !== -1) return;

        /* column map: a cell holding exactly 24 digits always belongs to the
           بارکد column, even when its x sits nearer a neighbour column */
        var map = null, i, col, bcCol = null;
        if (columns) {
          for (i = 0; i < columns.length; i++) {
            if (columns[i].label === 'بارکد') bcCol = columns[i];
          }
          map = {};
          for (i = 0; i < oriented.length; i++) {
            col = assignToColumn(oriented[i].x, columns);
            if (bcCol && digitsOf(oriented[i].str).length === BARCODE_LEN) col = bcCol;
            if (!col) continue;
            if (!map[col.label]) map[col.label] = [];
            map[col.label].push(normalizeText(oriented[i].str));
          }
        }
        function colValue(label) {
          var arr = map && map[label];
          return arr && arr.length ? arr.join(' ') : '';
        }

        /* barcode: the بارکد column, then digit runs, then any cell */
        var barcode = null;
        var bcDigits = digitsOf(colValue('بارکد'));
        if (bcDigits.length === BARCODE_LEN) barcode = bcDigits;
        if (!barcode) barcode = barcodeFromRuns(line.cells, columns, bcCol);
        if (!barcode) {
          for (i = 0; i < line.cells.length; i++) {
            barcode = barcodeFromCell(line.cells[i]);
            if (barcode) break;
          }
        }
        if (!barcode) {
          /* a near-miss digit run is reported, never dropped silently */
          var run = longestDigitRun(line.cells);
          if (run.digits.length >= SUSPECT_DIGITS) {
            skipped.push({ raw: raw, reason: 'بارکد خوانده نشد (' +
              String(run.digits.length) + ' رقم)' });
          }
          return;
        }

        /* column values, joined in logical order */
        var recipient = '', city = '', date = '', weight = '';
        var warnings = [];
        if (columns) {
          recipient = colValue('نامگ');
          city = colValue('مقصد');
          date = colValue('تاریخثبت');
          weight = colValue('وزن');
          if (!recipient && !city) warnings.push('نام و ستون مقصد خوانده نشد');
          else if (!recipient) warnings.push('نام گیرنده خوانده نشد');
        } else {
          /* heuristic fallback (5): sender cell first, then guess */
          warnings.push('هدر ستون‌ها پیدا نشد؛ نام و شهر حدسی هستند');
          var texts = [];
          for (i = 0; i < oriented.length; i++) {
            var t = normalizeText(oriented[i].str);
            if (!t || digitsOf(t) === t) continue;
            if (canon(t).indexOf('دلسانا') !== -1) continue;
            texts.push(t);
          }
          recipient = texts[0] || '';
          city = texts[1] || '';
          if (!recipient) warnings.push('نام گیرنده خوانده نشد');
        }

        rows.push({
          barcode: barcode,
          recipient: recipient,
          city: city,
          date: date,
          weight: weight,
          raw: raw,
          warnings: warnings
        });
      });
    });

    return { rows: rows, skipped: skipped };
  }

  /* ------------------------------------------------------------ matching */
  function statusRank(s) {
    if (s === 'settled') return 0;
    if (s === 'paid') return 1;
    if (s === 'shipped') return 2;
    return 3;
  }

  /* name score for one canonical variant of the PDF name (5.1).
     pw = the PDF name's words, each already canon()ed; pname = them joined. */
  function nameScoreFor(pw, custWords, custJoined) {
    if (!pw.length) return 0;
    var pname = pw.join('');
    var k = pw.length;

    /* equals the last word(s) of the customer -> 3 (includes the full name) */
    if (custWords.length >= k) {
      var tail = custWords.slice(custWords.length - k).join('');
      if (tail === pname) return NAME_EXACT;
    }
    /* any whole word of the customer -> 2.5 */
    for (var i = 0; i < custWords.length; i++) {
      if (custWords[i] === pname) return NAME_FULL;
    }
    /* multi-word PDF name, every word present in the customer -> 2.5 */
    if (k > 1) {
      var all = pw.every(function (w) { return custWords.indexOf(w) !== -1; });
      if (all) return NAME_FULL;
    }
    /* edit distance <= 1 against the surname -> 2 */
    var surname = custWords.length ? custWords[custWords.length - 1] : '';
    if (surname && pname.length >= 3 && surname.length >= 3 &&
        editDistance(pname, surname) <= 1) return NAME_NEAR;
    /* substring either way, min length 3 -> 1 */
    if (pname.length >= 3 && custJoined.length >= 3 &&
        (custJoined.indexOf(pname) !== -1 || pname.indexOf(custJoined) !== -1)) {
      return NAME_SUB;
    }
    return 0;
  }

  function nameWords(s) {
    return normalizeText(s).split(' ').map(canon).filter(Boolean);
  }

  /* compares the normal AND the char-reversed form of the PDF name
     (visual-order generators, quirk 3) */
  function nameScore(rowName, cust) {
    var custWords = nameWords(cust.customer);
    var custJoined = custWords.join('');
    if (!custWords.length) return 0;
    var v1 = nameWords(rowName);
    var v2 = nameWords(rev(normalizeText(rowName)));
    return Math.max(nameScoreFor(v1, custWords, custJoined),
                    nameScoreFor(v2, custWords, custJoined));
  }

  function cityScore(rowCity, cust) {
    var cc = canon(rowCity);
    if (!cc) return 0;
    var addr = canon(cust.address);
    if (addr && addr.indexOf(cc) !== -1) return CITY_IN;
    var aw = words(cust.address).map(canon).filter(Boolean);
    for (var i = 0; i < aw.length; i++) {
      if (aw[i] && cc.length >= 3 && aw[i].length >= 3 &&
          editDistance(cc, aw[i]) <= 1) return CITY_NEAR;
    }
    return 0;
  }

  /* rows: from parseItems. orders: App.orders.
     -> [{ row, verdict: 'green'|'yellow'|'red', candidates: [...] }] */
  function matchRows(rows, orders) {
    var pool = (orders || []).filter(function (o) {
      return o.shipping_method === 'post' && o.status !== 'cancelled';
    });

    return (rows || []).map(function (row) {
      /* an unreadable name must stay a red row (even if the city hits); the
         user can still assign such a row manually from the full order list */
      if (!row.barcode || !canon(row.recipient || '')) {
        return { row: row, verdict: 'red', candidates: [] };
      }
      var scored = pool.map(function (o) {
        var ns = nameScore(row.recipient, o);
        var cs = cityScore(row.city, o);
        return {
          order_id: o.id,
          customer: o.customer,
          address: o.address || '',
          status: o.status,
          created_at: o.created_at,
          tracking: o.tracking || '',
          name_score: ns,
          city_score: cs,
          score: ns + cs,
          _fifo: new Date(o.created_at || 0).getTime() || 0,
          _rank: statusRank(o.status)
        };
      }).filter(function (c) { return c.score > 0; });

      /* rank: score desc, then preferred status, then oldest first. The
         FIFO/status preferences never change the verdict itself. */
      scored.sort(function (a, b) {
        if (b.score !== a.score) return b.score - a.score;
        if (a._rank !== b._rank) return a._rank - b._rank;
        return a._fifo - b._fifo;
      });
      scored.forEach(function (c) { delete c._fifo; delete c._rank; });

      var verdict = 'red';
      if (scored.length) {
        var best = scored[0].score;
        var second = scored.length > 1 ? scored[1].score : null;
        if (best >= GREEN_MIN && (second === null || best - second >= GAP_MIN)) {
          verdict = 'green';
        } else if (best >= YELLOW_MIN) {
          verdict = 'yellow';
        }
      }
      return { row: row, verdict: verdict, candidates: scored.slice(0, TOP_N) };
    });
  }

  root.PostImport = {
    normalizeText: normalizeText,
    canon: canon,
    rev: rev,
    editDistance: editDistance,
    parseItems: parseItems,
    matchRows: matchRows
  };
})(typeof window !== 'undefined' ? window : this);
