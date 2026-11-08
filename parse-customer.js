/* parse-customer.js — offline, rule-based parser for Iranian customer info
   extracted from free-text messenger paste. No external AI/API, no new deps.
   Exposes: parseCustomerText(text) -> { name, phone, postalCode, address, province?, warnings }
   Works identically on multi-line text OR single-line collapsed text
     (what prompt()/clipboard produce).
*/

(function (root) {
  'use strict';

  /* ---------- 31 Iranian province names (lowercased, with aliases) ---------- */
  var PROVINCES = {
    'آذربایجان شرقی': 1, 'آذربایجان غربی': 1, 'اردبیل': 1, 'اصفهان': 1, 'البرز': 1,
    'ایلام': 1, 'بوشهر': 1, 'تهران': 1, 'چهارمحال و بختیاری': 1, 'خرم': 1,
    'خرسانه': 1, 'خراسان جنوبی': 1, 'خراسان رضوی': 1, 'خراسان شمالی': 1,
    'خوزستان': 1, 'زنجان': 1, 'سمنان': 1, 'سیستان و بلوچستان': 1,
    'فارس': 1, 'قزوین': 1, 'قم': 1, 'کردستان': 1, 'کرمان': 1, 'کرمانشاه': 1,
    'کهگیلویه و بویراحمد': 1, 'گیلانی': 1, 'لرستان': 1, 'مازندران': 1, 'هرمزگان': 1,
    'همدان': 1, 'یزد': 1
  };

  /* ---------- address-start keywords (for splitting name from address) ---------- */
  var ADDRESS_KEYWORDS = /^(استان|شهر| شهرستان| خیابان| خ| بلوار| كوچه| میدان| روستا| بخش| محله| شهرک| کوی| پلاک| واحد| طبقه| بن بست)/i;

  /* ---------- basic normalization ---------- */

  function toEnDigits(s) {
    if (s === null || s === undefined) return '';
    return String(s)
      .replace(/[۰-۹]/g, function (d) { return String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)); })
      .replace(/[٠-٩]/g, function (d) { return String('٠١٢٣۴۵۶۷۸۹'.indexOf(d)); });
  }

  /* ---------- strip bidi/zero-width marks, keep ZWNJ inside words ---------- */
  function normalizeAll(s) {
    if (s === null || s === undefined) return '';
    var t = String(s);
    t = toEnDigits(t);
    t = t.replace(/[يک]/g, function (d) { return d === 'ي' ? 'ی' : 'ک'; });
    t = t.replace(/[\u200B\u200E\u200F\u202A-\u202E\u2066-\u2069\uFEFF]/g, '');
    t = t.replace(/[•●▪️◆★✅➖|¦]/g, ' ');
    t = t.replace(/[^0-9a-zA-Z\s\u0600-\u06FF\u0670\u0750-\u077F\u08A0-\u08FF\n\r]/g, ' ');
    t = t.replace(/\r\n|\r|\n/g, '\n');
    t = t.replace(/[ \t]+/g, ' ');
    t = t.replace(/\n+/g, '\n');
    return t.trim();
  }

  /* ---------- find Iranian mobile number ---------- */
  function extractPhoneAndRemainder(text) {
    var patterns = [
      /09\d{9}/g,
      /\+98\s*9\d{3}\s*\d{4}/g,
      /00989\d{9}/g,
      /9\d{2}\s*\d{3}\s*\d{4}/g
    ];

    for (var p = 0; p < patterns.length; p++) {
      var matches = [];
      var m;
      while ((m = patterns[p].exec(text)) !== null) {
        matches.push(m[0]);
        break; // first match only
      }
      if (matches.length > 0) {
        var phone = matches[0].replace(/[\s\-]/g, '');
        // Normalize to 09xxxxxxxxx
        if (phone.startsWith('+989')) phone = '09' + phone.substring(3, 12);
        if (phone.startsWith('00989')) phone = '09' + phone.substring(4, 13);
        if (phone.startsWith('989')) phone = '09' + phone.substring(2, 11);
        if (phone.length === 10 && /^9\d{9}$/.test(phone)) phone = '0' + phone;
        if (/^09\d{9}$/.test(phone)) {
          // Remove phone span from text
          var escaped = matches[0].replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
          var textWithout = text.replace(new RegExp(escaped, 'g'), ' ');
          textWithout = textWithout.replace(/[ \t]+/g, ' ').trim();
          return [phone, textWithout];
        }
      }
    }

    return [null, text];
  }

  /* ---------- find 10-digit postal code ---------- */
  function extractPostalAndRemainder(text) {
    // Pattern 1: 10-digit after postal label (كوديستي, كودپستی, پستی, Postal)
    var labelPatterns = [
      /ك[ddu]?ost[iy]?[:\s\-]?(\d{10})/i,
      /[كك]?[pd]?osti[:\s\-]?(\d{10})/i,
      /پست[:\s\-]?(\d{10})/i,
      /Postal[:\s\-]?(\d{10})/i
    ];
    for (var li = 0; li < labelPatterns.length; li++) {
      var m = text.match(labelPatterns[li]);
      if (m && m[1] && m[1].length === 10 && !m[1].startsWith('0')) {
        var textWithout = text.replace(new RegExp(escapeRegExp(m[0]), 'g'), ' ');
        textWithout = textWithout.replace(/[ \t]+/g, ' ').trim();
        return [m[1], textWithout];
      }
    }

    // Pattern 2: standalone 10-digit run (groups 3-3-4 or 5-5)
    // e.g. 756 177 7797, 4812345678, 48123 45678, 48123-45678
    var postalRegex = /(\d{3}[-\s]?\d{3}[-\s]?\d{4}|\d{10})/g;
    var candidates = [];
    var m;
    while ((m = postalRegex.exec(text)) !== null) {
      var norm = m[0].replace(/[\s\-]/g, '');
      if (norm.length === 10 && !norm.startsWith('0')) {
        candidates.push({ value: m[0], index: m.index });
      }
    }

    if (candidates.length > 0) {
      candidates.sort(function (a, b) { return a.index - b.index; });
      var chosen = candidates[candidates.length - 1];
      var textWithout = text.replace(new RegExp(escapeRegExp(chosen.value), 'g'), ' ');
      textWithout = textWithout.replace(/[ \t]+/g, ' ').trim();
      var postalNorm = chosen.value.replace(/[\s\-]/g, '');
      return [postalNorm, textWithout];
    }

    return [null, text];
  }

  /* ---------- escape regex special chars ---------- */
  function escapeRegExp(s) {
    return s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
  }

  /* ---------- extract labeled fields ---------- */
  function extractLabeledFields(text) {
    var result = { name: null, phone: null, address: null, postal: null };

    function extractAfterLabel(text, labelWords) {
      for (var i = 0; i < labelWords.length; i++) {
        // Try the word as-is, and also as flexible pattern
        var patterns = [];
        if (Array.isArray(labelWords[i])) {
          patterns = labelWords[i];
        } else {
          patterns = [labelWords[i]];
          // Generate flexible patterns for Arabic-based words
          if (labelWords[i].indexOf('osti') >= 0 || labelWords[i].indexOf('post') >= 0) {
            patterns.push(labelWords[i].replace('osti', '[osti]'));
            patterns.push(labelWords[i].replace('post', '[post]'));
          }
        }
        for (var pi = 0; pi < patterns.length; pi++) {
          var re = new RegExp(escapeRegExp(patterns[pi]) + '[\s:\\-]?', 'i');
          var m = text.match(re);
          if (m) {
            var after = text.substring(m.index + m[0].length);
            var parts = after.split(/\n/);
            var val = parts[0];
            val = val.replace(/^[:\s\-•●▪️◆★✅➖|¦]+/, '');
            val = val.trim();
            if (val.length > 0) return val;
          }
        }
      }
      return null;
    }

    // Name
    var nameValue = extractAfterLabel(text, [
      'نام و نام خانوادگی', 'نام ونام خانوادگی', 'نام‌ونام‌خانوادگی',
      'گیرنده', 'نام', 'اسم', 'به نام', 'تحویل گیرنده', 'نام گیرنده'
    ]);
    if (nameValue !== null) { result.name = nameValue; }

    // Phone
    var phoneValue = extractAfterLabel(text, [
      'شماره تماس', 'شماره همراه', 'شماره موبایل', 'تلفن همراه',
      'تلفن', 'موبایل', 'تماس'
    ]);
    if (phoneValue !== null) { result.phone = phoneValue; }

    // Address
    var addressValue = extractAfterLabel(text, [
      'آدرس پستی', 'آدرس کامل', 'نشانی', 'آدرس',
      'نشانی کامل', 'مخاطبان'
    ]);
    if (addressValue !== null) { result.address = addressValue; }

    // Postal - try multiple patterns
    var postalValue = extractAfterLabel(text, [
      'كوديستي', 'كودپستی', 'كد پستی', 'كدپستی', 'كد‌پستی', 'پستی', 'Postal'
    ]);
    if (postalValue !== null) { result.postal = postalValue; }

    return result;
  }

  /* ---------- isProvince ---------- */
  function isProvince(word) {
    var cleanWord = word.replace(/[،,]/g, '').trim();
    return PROVINCES[cleanWord] === 1;
  }

  /* ---------- main parser ---------- */
  function parseCustomerText(text) {
    var warnings = [];

    if (typeof text !== 'string') {
      return { name: '', phone: '', postalCode: '', address: '', province: undefined, warnings: ['کد پستی پیدا نشد'] };
    }
    text = text.trim();
    if (text === '') {
      return { name: '', phone: '', postalCode: '', address: '', province: undefined, warnings: ['کد پستی پیدا نشد'] };
    }

    var normalized = normalizeAll(text);
    var labeled = extractLabeledFields(normalized);

    // Extract phone
    var phone = '';
    var phoneWarning = '';
    var [phoneVal, afterPhone] = extractPhoneAndRemainder(normalized);
    if (phoneVal) {
      phone = phoneVal;
      if (!/^09\d{9}$/.test(phone)) { phone = ''; phoneWarning = 'شماره تماس ۱۱ رقمی نیست'; }
    } else { if (!phoneWarning) phoneWarning = 'شماره موبایل نیست'; }

    // Extract postal
    var postal = '';
    var postalWarning = '';
    var [postalVal, afterPostal] = extractPostalAndRemainder(afterPhone);
    if (postalVal) {
      postal = postalVal;
      if (!/^\d{10}$/.test(postal) || postal.startsWith('0')) { postal = ''; postalWarning = 'کد پستی ۱۰ رقمی نیست'; }
    } else { postalWarning = 'کد پستی پیدا نشد'; }

    // Name and address
    var name = '';
    var address = '';
    var province = undefined;
    var nameWarning = '';
    var addressWarning = '';

    var segments = afterPostal.split('\n');
    var subSegments = [];
    for (var s = 0; s < segments.length; s++) {
      var seg = segments[s].trim();
      if (seg.length > 0) {
        var subParts = seg.split(/ {2,}/);
        for (var p = 0; p < subParts.length; p++) {
          subSegments.push(subParts[p].trim());
        }
      }
    }

    if (subSegments.length === 0) {
      nameWarning = 'نام پیدا نشد';
      addressWarning = 'آدرس پیدا نشد';
    } else {
      var nameFound = false;
      var addressSegments = [];

      for (var i = 0; i < subSegments.length; i++) {
        var seg = subSegments[i];
        var hasDigits = /\d/.test(seg);
        var words = seg.split(' ');
        var wordCount = words.filter(function (w) { return w.length > 0; }).length;
        var firstWord = words[0] ? words[0].replace(/[،,]/g, '').trim() : '';
        var startsWithProvince = isProvince(firstWord);
        var startsWithKeyword = ADDRESS_KEYWORDS.test(firstWord);
        var hasComma = seg.indexOf('،') >= 0;
        var isNameCandidate = !hasDigits && wordCount >= 1 && wordCount <= 5 && !startsWithProvince && !startsWithKeyword && !hasComma;

        if (!nameFound && isNameCandidate) {
          name = seg;
          nameFound = true;
          for (var j = i + 1; j < subSegments.length; j++) {
            addressSegments.push(subSegments[j]);
          }
        } else {
          addressSegments.push(seg);
        }
      }

      if (!nameFound) {
        var firstSeg = subSegments[0];
        var firstWords = firstSeg.split(' ');
        var cappedWords = firstWords.slice(0, 5);
        if (cappedWords.length > 0) name = cappedWords.join(' ');
        for (var j = 1; j < subSegments.length; j++) {
          addressSegments.push(subSegments[j]);
        }
        var firstWord = firstSeg.split(' ')[0] ? firstSeg.split(' ')[0].replace(/[،,]/g, '').trim() : '';
        var firstSP = isProvince(firstWord);
        var firstSK = ADDRESS_KEYWORDS.test(firstWord);
        if (/\\d/.test(firstSeg) || firstSP || firstSK) { name = ''; nameWarning = 'نام پیدا نشد'; }
      }

      address = addressSegments.filter(function (s) { return s.length > 0; }).join('\n');
      address = address.replace(/^[،,\s]+/, '');
      address = address.replace(/[،,\s]+$/, '');

      var addrFirstWord = address.split(' ')[0] ? address.split(' ')[0].replace(/[،,]/g, '').trim() : '';
      if (isProvince(addrFirstWord)) province = addrFirstWord;
    }

    // Warnings
    var allWarnings = [];
    var seenWarnings = {};
    function addWarning(key) { if (!seenWarnings[key]) { seenWarnings[key] = true; allWarnings.push(key); } }

    if (phone === '' && !phoneWarning) addWarning('شماره تماس پیدا نشد');
    if (phone !== '' && !/^09\d{9}$/.test(phone)) addWarning('شماره تماس ۱۱ رقمی نیست');
    if (postal === '' && !postalWarning) addWarning('کد پستی پیدا نشد');
    if (postal !== '' && !/^\d{10}$/.test(postal)) addWarning('کد پستی ۱۰ رقمی nisoAddedWarning');
    if (postal !== '' && postal.startsWith('0')) addWarning('کد پستی شروع به صفر نمی‌شود');
    if (name === '' && !nameWarning) addWarning('نام پیدا نشد');
    if (name !== '' && nameWarning) addWarning(nameWarning);
    if (address === '' && !addressWarning) addWarning('آدرس پیدا نشد');

    if (name) name = name.replace(/^(nam|name|gerefte)\s*:?\s*/i, '').trim();
    if (address) address = address.replace(/^(adrese|adrese posti)\s*:?\s*/i, '').trim();

    return { name: name, phone: phone, postalCode: postal, address: address, province: province, warnings: allWarnings };
  }

  /* ---------- export ---------- */
  root.parseCustomerText = parseCustomerText;
})(typeof window !== 'undefined' ? window : this);