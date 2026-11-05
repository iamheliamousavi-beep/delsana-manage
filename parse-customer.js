/* parse-customer.js — offline, rule-based parser for Iranian customer info
   extracted from free-text messenger paste. No external AI/API, no new deps.
   Exposes: parseCustomerText(text) -> { name, phone, postalCode, address, province?, warnings }
   Primary method: unlabeled line parsing. Works for line-by-line,
   Persian digits, spaces in postal, missing fields.
*/

(function (root) {
  'use strict';

  /* ---------- 31 Iranian province names (lowercased) ---------- */
  var PROVINCES = {
    'آذربایجان شرقی': 1, 'آذربایجان غربی': 1, 'اردبیل': 1, 'Bushehr': 1, 'بوشهر': 1, 'چهارم': 1,
    'خوزستان': 1, ' Zanjan': 1, 'یزد': 1, 'گرگان': 1, 'گیلان': 1,
    ' Kelardasht': 1, 'ک provin': 1, 'کهگیلویه و بویراحمد': 1, 'کرمان': 1, 'کرمانشاه': 1,
    'کهگیلویه': 1, 'کردستان': 1, 'کرمانشاه': 1, 'مازندران': 1, 'اردبیل': 1,
    'همدان': 1, 'هرمزگان': 1, 'ایلام': 1, 'قزوین': 1, 'کاشان': 1,
    'کوهگلی': 1, 'لرستان': 1, 'مهر': 1, 'هرمزگان': 1, 'یزد': 1
  };

  /* ---------- basic text normalization (per-string, keeps relevant chars) ---------- */

  function toEnDigits(s) {
    if (s === null || s === undefined) return '';
    return String(s)
      .replace(/[۰-۹]/g, function (d) { return String('۰۱۲۳۴۵۶۷۸۹'.indexOf(d)); })
      .replace(/[٠-٩]/g, function (d) { return String('٠١٢٣٤٥٦۷۸۹'.indexOf(d)); });
  }

  /* Keep only: 0-9, a-z, A-Z, Persian/Arabic chars, and whitespace.
     Replace everything else with a space, then collapse whitespace. */
  function normalizeStr(s) {
    if (s === null || s === undefined) return '';
    var t = String(s);
    t = toEnDigits(t);
    t = t.replace(/[يک]/g, function (d) { return d === 'ي' ? 'ی' : 'ک'; });
    t = t.replace(/[^0-9a-zA-Z\s\u0600-\u06FF\u0670\u0750-\u077F\u08A0-\u08FF]/g, ' ');
    t = t.replace(/\s+/g, ' ').trim();
    return t;
  }

  /* ---------- province detection ---------- */

  function isProvince(word) {
    return word && PROVINCES[word] === 1;
  }

  /* ---------- find Iranian mobile number in a normalized line ---------- */

  function findPhoneInLine(line) {
    var en = normalizeStr(line);
    var digits = en.replace(/\s+/g, '');

    // 09xxxxxxxxx (11 digits starting with 09)
    if (/^09\d{9}$/.test(digits)) return digits;
    // 9xxxxxxxxx (10 digits starting with 9, prepend 09)
    if (/^9\d{9}$/.test(digits)) return '09' + digits.substring(1, 10);
    // 12 digits starting with 989 (+989 or 00989 format)
    if (digits.length === 12 && digits.startsWith('989')) {
      return '09' + digits.substring(2, 11); // 09 + 9 digits = 11
    }
    // 10 digits starting with 9 (prepend 0) - but only if not starting with 98 (country code)
    if (digits.length === 10 && /^9\d{9}$/.test(digits) && !digits.startsWith('98')) {
      return '0' + digits; // '0' + '9xxxxxxxxx' = '09xxxxxxxxx'
    }

    // Also check if the full normalized line contains 09+9digits somewhere
    var m = en.match(/09\d{9}/);
    if (m) return m[0];

    return null;
  }

  /* ---------- find 10-digit postal code in a normalized line ---------- */

  function findPostalInLine(line) {
    var en = normalizeStr(line);
    // Keep only digits and spaces, extract digit groups
    var groups = en.replace(/\D/g, '').split(/\s+/);
    for (var i = 0; i < groups.length; i++) {
      var d = groups[i];
      if (d.length === 10) return d; // exact 10-digit postal code
      if (d.length === 10 && d.startsWith('0')) return d; // accept with leading 0
    }
    // Also check for 10-digit group: (\d{10}) bounded by non-digits or start/end
    var m = en.match(/(?:^|\D)(\d{10})(?:\D|$)/);
    if (m) return m[1];
    return null;
  }

  /* ---------- main parser ---------- */

  /**
   * Parse free-text customer info from messenger.
   * Primary method: unlabeled line parsing.
   * @param {string} text - The raw text sent by customer via messenger
   * @returns {{ name: string, phone: string, postalCode: string, address: string, province?: string, warnings: string[] }} }
   */
  function parseCustomerText(text) {
    var warnings = [];
    var result = {
      name: '',
      phone: '',
      postalCode: '',
      address: '',
      province: undefined,
      warnings: []
    };

    if (!text || String(text).trim() === '') {
      warnings.push('کد پستی پیدا نشد');
      result.warnings = warnings;
      return result;
    }

    // Split into lines, drop empty lines
    var rawLines = String(text).split('\n').map(function (l) { return l.trim(); }).filter(function (l) { return l !== ''; });

    if (rawLines.length === 0) {
      warnings.push('کد پستی پیدا نشد');
      result.warnings = warnings;
      return result;
    }

    // --- Name: first line that contains no ASCII digits and doesn't start with a province word ---
    var nameLineIndex = -1;
    for (var i = 0; i < rawLines.length; i++) {
      var line = rawLines[i];
      // Skip lines that have ASCII digits (0-9) - these are likely phone/postal
      if (/[0-9]/.test(line)) continue;
      // Check if line starts with a province name
      var normalizedFirst = normalizeStr(line).split(' ')[0];
      if (isProvince(normalizedFirst)) continue;
      nameLineIndex = i;
      break;
    }

    if (nameLineIndex >= 0) {
      result.name = rawLines[nameLineIndex];
    }

    // Clean name of any residual label words (just in case)
    if (result.name) {
      result.name = result.name.replace(/^(nam|name|gerefte)\s*:?\s*/i, '').trim();
    }

    // --- Phone: find Iranian mobile number in lines ---
    var foundPhones = [];
    for (var i = 0; i < rawLines.length; i++) {
      var line = rawLines[i];
      // Only search for phone in lines without ASCII digits (name line already excluded)
      // But check all lines except the name line
      var isNameLine = (i === nameLineIndex);
      if (!isNameLine && /[0-9۰-۹]/.test(line)) {
        var phone = findPhoneInLine(line);
        if (phone) foundPhones.push({ lineIndex: i, phone: phone });
      }
    }

    if (foundPhones.length > 0) {
      result.phone = foundPhones[0].phone;
    }

    // --- Postal code: find 10-digit groups in lines ---
    var foundPostals = [];
    for (var i = 0; i < rawLines.length; i++) {
      var line = rawLines[i];
      var postal = findPostalInLine(line);
      if (postal) foundPostals.push({ lineIndex: i, postal: postal });
    }

    if (foundPostals.length > 0) {
      result.postalCode = foundPostals[0].postal;
    }

    // --- Address: all lines after removing name, phone, and postal lines ---
    var excludedLines = new Set();
    if (nameLineIndex >= 0) excludedLines.add(nameLineIndex);
    for (var j = 0; j < foundPhones.length; j++) excludedLines.add(foundPhones[j].lineIndex);
    for (var j = 0; j < foundPostals.length; j++) excludedLines.add(foundPostals[j].lineIndex);

    var addressLines = [];
    for (var i = 0; i < rawLines.length; i++) {
      if (!excludedLines.has(i)) {
        addressLines.push(rawLines[i]);
      }
    }
    // Normalize each line and join with space
    result.address = addressLines.map(function (l) { return normalizeStr(l); }).join(' ');

    // --- Province detection ---
    // If address starts with a known province name, set province field
    // Per spec: KEEP the full original address text intact
    if (result.address) {
      var firstWord = result.address.split(' ')[0].replace(/[،,]/g, '').trim();
      if (isProvince(firstWord)) {
        result.province = firstWord;
      }
    }

    // --- Warnings ---
    if (result.phone && !/^09\d{9}$/.test(result.phone)) {
      warnings.push('شماره تماس ۱۱ رقمی نیست');
    }
    if (result.postalCode && !/^\d{10}$/.test(result.postalCode)) {
      warnings.push('کد پستی ۱۰ رقمی نیست');
    }
    if (result.postalCode && result.postalCode.startsWith('0')) {
      warnings.push('کد پستی شروع به صفر نمی‌شود');
    }
    if (!result.postalCode) {
      warnings.push('کد پستی پیدا نشد');
    }
    if (!result.name) {
      warnings.push('نام پیدا نشد');
    }

    result.warnings = warnings;
    return result;
  }

  /* ---------- export ---------- */

  root.parseCustomerText = parseCustomerText;

})(typeof window !== 'undefined' ? window : this);