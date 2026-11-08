/* parse-customer.js — offline, rule-based parser for Iranian customer info
   extracted from free-text messenger paste. No external AI/API, no new deps.
   Exposes: parseCustomerText(text) -> { name, phone, postalCode, address, province?, warnings }
   Works identically on multi-line text OR single-line collapsed text
     (what prompt()/clipboard produce).
*/

(function (root) {
  'use strict';

  /* ---------- 31 Iranian province names (with a few aliases) ---------- */
  var PROVINCES = {
    'آذربایجان شرقی': 1, 'آذربایجان غربی': 1, 'اردبیل': 1, 'اصفهان': 1, 'البرز': 1,
    'ایلام': 1, 'بوشهر': 1, 'تهران': 1, 'چهارمحال و بختیاری': 1, 'خرم': 1,
    'خرسانه': 1, 'خراسان جنوبی': 1, 'خراسان رضوی': 1, 'خراسان شمالی': 1,
    'خوزستان': 1, 'زنجان': 1, 'سمنان': 1, 'سیستان و بلوچستان': 1,
    'فارس': 1, 'قزوین': 1, 'قم': 1, 'کردستان': 1, 'کرمان': 1, 'کرمانشاه': 1,
    'کهگیلویه و بویراحمد': 1, 'گیلانی': 1, 'لرستان': 1, 'مازندران': 1, 'هرمزگان': 1,
    'همدان': 1, 'یزد': 1
  };

  var PROVINCE_MAX_WORDS = 3; /* longest province names are 3 words */

  /* ---------- address keywords (matched as exact words, not prefixes) ---------- */
  var KEYWORDS = {
    'استان': 1, 'شهر': 1, 'شهرستان': 1, 'خیابان': 1, 'خ': 1, 'بلوار': 1,
    'کوچه': 1, 'میدان': 1, 'روستا': 1, 'بخش': 1, 'محله': 1, 'شهرک': 1,
    'کوی': 1, 'پلاک': 1, 'واحد': 1, 'طبقه': 1, 'بنبست': 1
  };

  /* ---------- basic normalization ---------- */

  function toEnDigits(s) {
    if (s === null || s === undefined) return '';
    return String(s)
      .replace(/[۰-۹]/g, function (d) { return String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)); })
      .replace(/[٠-٩]/g, function (d) { return String('٠١٢٣۴۵۶۷۸۹'.indexOf(d)); });
  }

  /* strip bidi/zero-width marks, unify Persian letter variants,
     keep only digits, Latin letters and Persian script */
  function normalizeAll(s) {
    if (s === null || s === undefined) return '';
    var t = String(s);
    t = toEnDigits(t);
    t = t.replace(/[\u064A\u0649]/g, 'ی'); /* Arabic yeh / alef maksura -> Persian yeh */
    t = t.replace(/\u0643/g, 'ک');         /* Arabic kaf -> Persian kaf */
    t = t.replace(/[\u200B\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, '');
    t = t.replace(/[•●▪️◆★✅➖|¦]/g, ' ');
    t = t.replace(/[^0-9a-zA-Z\s\u0600-\u06FF\u0670\u0750-\u077F\u08A0-\u08FF\n\r]/g, ' ');
    t = t.replace(/\r\n|\r|\n/g, '\n');
    t = t.replace(/[ \t]+/g, ' ');
    t = t.replace(/\n+/g, '\n');
    return t.trim();
  }

  /* ---------- generic helpers ---------- */

  /* remove the FIRST occurrence of `sub`, collapse the gap */
  function removeSubstring(text, sub) {
    var idx = text.indexOf(sub);
    if (idx < 0) return text;
    return (text.substring(0, idx) + ' ' + text.substring(idx + sub.length))
      .replace(/[ \t]+/g, ' ').trim();
  }

  /* drop leftover bare postal labels («کد پستی:» with no usable digits after it)
     so they don't end up inside the extracted name/address */
  function cleanPostalLabels(text) {
    return text
      .replace(/(?:کد[\s\u200C]*پستی|کدپستی|پستی)\s*[:：]?/g, ' ')
      .replace(/[ \t]+/g, ' ');
  }

  /* ---------- find Iranian mobile number ---------- */
  function extractPhoneAndRemainder(text) {
    var patterns = [
      /09\d{9}/,
      /\+98[-\s]*9\d{3}[-\s]*\d{4}/,
      /00989\d{9}/,
      /98[-\s]*9\d{9}/,
      /9\d{2}[-\s]?\d{3}[-\s]?\d{4}/
    ];

    for (var p = 0; p < patterns.length; p++) {
      var m = text.match(patterns[p]);
      if (!m) continue;
      var phone = String(m[0]).replace(/[\s\-]/g, '');
      if (phone.indexOf('+98') === 0) phone = '09' + phone.substring(3);
      else if (phone.indexOf('0098') === 0) phone = '09' + phone.substring(4);
      else if (phone.indexOf('98') === 0 && phone.length === 12) phone = '09' + phone.substring(2);
      if (/^9\d{9}$/.test(phone)) phone = '0' + phone;
      if (/^09\d{9}$/.test(phone)) {
        return [phone, removeSubstring(text, m[0])];
      }
    }
    return [null, text];
  }

  /* ---------- find 10-digit postal code ---------- */
  function extractPostalAndRemainder(text) {
    /* Pattern 1: labeled postal code
       e.g. «کد پستی: 4812345678», «پستی- 48123 45678», "Postal: 1234567890" */
    var labelPattern =
      /(?:کد[\s\u200C]*پستی|کدپستی|پستی|پست|postal\s*code|post\s*code)\s*[:：\-]?\s*(\d{3}[-\s]?\d{3}[-\s]?\d{4}|\d{10})/i;
    var m = text.match(labelPattern);
    if (m) {
      var norm = m[1].replace(/[\s\-]/g, '');
      if (norm.length === 10 && norm.charAt(0) !== '0') {
        return [norm, cleanPostalLabels(removeSubstring(text, m[0]))];
      }
      /* invalid digits under a label — fall through to standalone matching */
    }

    /* Pattern 2: standalone 10-digit run (groups 3-3-4 or plain)
       e.g. 756 177 7797, 4812345678, 48123 45678, 48123-45678 */
    var postalRegex = /(\d{3}[-\s]?\d{3}[-\s]?\d{4}|\d{10})/g;
    var candidates = [];
    var c;
    while ((c = postalRegex.exec(text)) !== null) {
      var cnorm = c[0].replace(/[\s\-]/g, '');
      if (cnorm.length === 10 && cnorm.charAt(0) !== '0') {
        candidates.push({ value: c[0], index: c.index });
      }
    }
    if (candidates.length > 0) {
      candidates.sort(function (a, b) { return a.index - b.index; });
      var chosen = candidates[candidates.length - 1];
      return [
        chosen.value.replace(/[\s\-]/g, ''),
        cleanPostalLabels(removeSubstring(text, chosen.value))
      ];
    }

    return [null, cleanPostalLabels(text)];
  }

  /* ---------- field labels (longest first) ---------- */
  /* e.g. «نام: علی محمدی», «آدرس پستی: …», «شماره تماس: 0912…» */
  var FIELD_LABELS = [
    'نام و نام خانوادگی', 'نام ونام خانوادگی', 'نام خانوادگی',
    'تحویل گیرنده', 'نام گیرنده', 'شماره تماس', 'شماره همراه',
    'شماره موبایل', 'تلفن همراه', 'آدرس پستی', 'آدرس کامل',
    'نشانی کامل', 'نشانی', 'آدرس', 'شماره', 'تلفن', 'موبایل',
    'تماس', 'به نام', 'نام', 'اسم', 'گیرنده'
  ];

  /* strip label tokens (with optional colon) so they don't leak into
     the extracted name/address */
  function cleanFieldLabels(text) {
    for (var i = 0; i < FIELD_LABELS.length; i++) {
      var re = new RegExp('(^|\\n|[\\s،,])' + FIELD_LABELS[i] + '(\\s*[:：]\\s*|\\s+)', 'g');
      text = text.replace(re, function (m0, sep) { return sep; });
    }
    return text.replace(/[ \t]+/g, ' ');
  }

  /* ---------- helpers for segments / spans ---------- */

  function cleanWord(w) { return w.replace(/[،,]/g, '').trim(); }

  /* split a segment into word tokens, remembering each token's offset
     (commas are separators but never part of a token) */
  function tokenize(seg) {
    var toks = [];
    var re = /[^\s،,]+/g;
    var m;
    while ((m = re.exec(seg)) !== null) {
      toks.push({ w: m[0], i: m.index, end: m.index + m[0].length });
    }
    return toks;
  }

  /* is a Persian/Latin comma glued right after this token? */
  function commaAfter(seg, tok) {
    var ch = seg.charAt(tok.end);
    return ch === '،' || ch === ',';
  }

  /* does a province name start at token t? (checks 3-word, 2-word then 1-word,
     so «آذربایجان شرقی» and «مازندران،» both match) */
  function provinceStartAt(toks, t) {
    var max = Math.min(PROVINCE_MAX_WORDS, toks.length - t);
    for (var k = max; k >= 1; k--) {
      var cand = [];
      for (var j = 0; j < k; j++) cand.push(cleanWord(toks[t + j].w));
      var joined = cand.join(' ');
      if (PROVINCES[joined] === 1) return joined;
    }
    return null;
  }

  /* an address-ish token that a name span must not cross */
  function isBreakToken(toks, t) {
    var w = cleanWord(toks[t].w);
    if (KEYWORDS[w] === 1) return true;
    if (/\d/.test(w)) return true;
    if (provinceStartAt(toks, t)) return true;
    return false;
  }

  /* ---------- main parser ---------- */
  function parseCustomerText(text) {
    var warnings = [];
    function addWarning(key) { if (warnings.indexOf(key) < 0) warnings.push(key); }

    if (typeof text !== 'string') {
      return { name: '', phone: '', postalCode: '', address: '', province: undefined,
               warnings: ['کد پستی پیدا نشد', 'نام پیدا نشد', 'آدرس پیدا نشد'] };
    }
    text = text.trim();
    if (text === '') {
      return { name: '', phone: '', postalCode: '', address: '', province: undefined,
               warnings: ['کد پستی پیدا نشد', 'نام پیدا نشد', 'آدرس پیدا نشد'] };
    }

    var normalized = normalizeAll(text);

    /* phone first: its digits must not pollute the postal-code search */
    var phone = '';
    var phoneWarning = '';
    var phoneRes = extractPhoneAndRemainder(normalized);
    if (phoneRes[0]) {
      phone = phoneRes[0];
      if (!/^09\d{9}$/.test(phone)) { phone = ''; phoneWarning = 'شماره تماس ۱۱ رقمی نیست'; }
    }

    /* postal */
    var postal = '';
    var postalWarning = '';
    var postalRes = extractPostalAndRemainder(phoneRes[1]);
    if (postalRes[0]) {
      postal = postalRes[0];
      if (!/^\d{10}$/.test(postal)) { postal = ''; postalWarning = 'کد پستی ۱۰ رقمی نیست'; }
    }

    /* strip leftover name/address/phone field labels */
    var remainder = cleanFieldLabels(postalRes[1]);

    /* segments: lines, or double-space separated parts of a single line */
    var segments = [];
    var lines = remainder.split('\n');
    for (var li = 0; li < lines.length; li++) {
      var parts = lines[li].split(/ {2,}/);
      for (var dspi = 0; dspi < parts.length; dspi++) {
        var seg = parts[dspi].trim();
        if (seg.length > 0) segments.push(seg);
      }
    }

    /* name: the first segment/span that reads like a person name.
       A span runs from the segment start and ends at the first break token
       (address keyword / digit / province start); a comma glued to a token
       inside the span disqualifies the segment as a name. Spans longer than
       5 words are capped and the tail goes to the address. */
    var name = '';
    var nameSegIdx = -1;
    var addrStartOffset = 0;

    for (var i = 0; i < segments.length; i++) {
      var nseg = segments[i];
      var ntoks = tokenize(nseg);
      var spanEnd = ntoks.length; /* exclusive end index of the name span */
      var notName = false;
      for (var t = 0; t < ntoks.length; t++) {
        if (isBreakToken(ntoks, t)) { spanEnd = t; break; }
        if (commaAfter(nseg, ntoks[t])) { notName = true; break; }
      }
      if (notName || spanEnd === 0) continue; /* not a name segment */

      var cap = Math.min(spanEnd, 5);
      var words = [];
      for (var w = 0; w < cap; w++) words.push(ntoks[w].w);
      name = words.join(' ');
      addrStartOffset = (cap < ntoks.length) ? ntoks[cap].i : nseg.length;
      nameSegIdx = i;
      break;
    }

    /* address = everything except the name span
       (segments before the name segment also belong to the address) */
    var addressParts = [];
    if (nameSegIdx >= 0) {
      for (var j = 0; j < nameSegIdx; j++) addressParts.push(segments[j]);
      addressParts.push(segments[nameSegIdx].substring(addrStartOffset));
      for (var r = nameSegIdx + 1; r < segments.length; r++) addressParts.push(segments[r]);
    } else {
      for (var n = 0; n < segments.length; n++) addressParts.push(segments[n]);
    }
    var address = addressParts.filter(function (s) { return s.length > 0; }).join('\n');
    address = address.replace(/^[،,\s]+/, '');
    address = address.replace(/[،,\s]+$/, '');

    /* province: the first position (in reading order) where any segment's
       tokens start a province name. Scans inside segments too, so a collapsed
       single-line «نام مازندران، …» still detects the province. */
    var province;
    for (var si = 0; si < segments.length && !province; si++) {
      var ptoks = tokenize(segments[si]);
      for (var ppos = 0; ppos < ptoks.length && !province; ppos++) {
        var pv = provinceStartAt(ptoks, ppos);
        if (pv) province = pv;
      }
    }

    /* warnings (each appears once) */
    if (phone === '') addWarning(phoneWarning || 'شماره تماس پیدا نشد');
    if (postal === '') addWarning(postalWarning || 'کد پستی پیدا نشد');
    if (name === '') addWarning('نام پیدا نشد');
    if (address === '') addWarning('آدرس پیدا نشد');

    return { name: name, phone: phone, postalCode: postal, address: address, province: province, warnings: warnings };
  }

  /* ---------- export ---------- */
  root.parseCustomerText = parseCustomerText;
})(typeof window !== 'undefined' ? window : this);
