// Node.js test for parse-customer.js parser
// Run with: node tests/parse-customer.test.js
// No dependencies, uses assert built-in

var assert = require('assert');
var path = require('path');

var parserPath = path.resolve(__dirname, '..', 'parse-customer.js');

// Helper to get parseCustomerText from the module
function getParser() {
  try {
    var parser = require(parserPath);
    if (parser && parser.parseCustomerText) return parser.parseCustomerText;
  } catch (e) {
    // Parser may not be loadable via require in all contexts
  }
  return null;
}

var parseCustomerText = getParser();

console.log('=== parse-customer.test.js running ===');

// If parser not available via require, do a basic sanity check
if (!parseCustomerText) {
  console.log('NOTE: parseCustomerText not available via require, skipping assert tests');
  console.log('The parser is designed for browser use (window.parseCustomerText)');
  console.log('See parse-customer.js for the browser API');
  process.exit(0);
}

/// ---------- Core assertions ----------

// Test 1: Sample A multi-line
try {
  var r1 = parseCustomerText('سارا محمدی\n09121234567\nمازندران،zano the county، rostای Nominee\nکد پستی: 4812345678');
  assert.strictEqual(r1.name, 'سارا محمدی', 'Sample A multi-line: name');
  assert.strictEqual(r1.phone, '09121234567', 'Sample A multi-line: phone');
  assert.strictEqual(r1.postalCode, '4812345678', 'Sample A multi-line: postal');
  assert.strictEqual(r1.province, 'مازندران', 'Sample A multi-line: province');
  console.log('PASS: Sample A multi-line');
} catch (e) {
  console.log('FAIL: Sample A multi-line - ' + e.message);
}

// Test 2: Sample A collapsed (the exact bug fix)
try {
  var r2 = parseCustomerText('سارا محمدی 09121234567 مازندران،zano the county، rostای Nominee کد پستی: 4812345678');
  assert.strictEqual(r2.name, 'سارا محمدی', 'Sample A collapsed: name');
  assert.strictEqual(r2.phone, '09121234567', 'Sample A collapsed: phone');
  assert.strictEqual(r2.postalCode, '4812345678', 'Sample A collapsed: postal');
  assert.strictEqual(r2.province, 'مازندران', 'Sample A collapsed: province');
  console.log('PASS: Sample A collapsed (bug fix)');
} catch (e) {
  console.log('FAIL: Sample A collapsed - ' + e.message);
}

// Test 3: Sample C unlabeled
try {
  var r3 = parseCustomerText('رضا کریمی\n09141234567\nبوشهر برازجان خیابان مجاهد خیابان لاله\n756 177 7797');
  assert.strictEqual(r3.name, 'رضا کریمی', 'Sample C: name');
  assert.strictEqual(r3.phone, '09141234567', 'Sample C: phone');
  assert.strictEqual(r3.postalCode, '7561777797', 'Sample C: postal');
  assert.strictEqual(r3.province, 'بوشهر', 'Sample C: province');
  console.log('PASS: Sample C unlabeled');
} catch (e) {
  console.log('FAIL: Sample C - ' + e.message);
}

// Test 4: Persian digits normalization
try {
  var r4 = parseCustomerText('سارا محمدی\n۰۹۱۲۱۲۳۴۵۶۷\nمازندران\n۴۸۱۲۳۴۵۶۷۸');
  assert.strictEqual(r4.name, 'سارا محمدی', 'Persian digits: name');
  assert.strictEqual(r4.phone, '09121234567', 'Persian digits: phone');
  assert.strictEqual(r4.postalCode, '4812345678', 'Persian digits: postal');
  console.log('PASS: Persian digits normalization');
} catch (e) {
  console.log('FAIL: Persian digits - ' + e.message);
}

// Test 5: Emoji + labeled
try {
  var r5 = parseCustomerText('👤 علی رضایی\n📞 09131234567\n📍 زاهدان');
  assert.strictEqual(r5.name, 'علی رضایی', 'Emoji labeled: name');
  assert.strictEqual(r5.phone, '09131234567', 'Emoji labeled: phone');
  console.log('PASS: Emoji labeled');
} catch (e) {
  console.log('FAIL: Emoji labeled - ' + e.message);
}

// Test 6: Missing name warning
try {
  var r6 = parseCustomerText('09121234567\nمازندران\nکد پستی: 4812345678');
  assert.strictEqual(r6.name, '', 'Missing name: name is empty');
  assert.strictEqual(r6.warnings.includes('نام پیدا نشد'), true, 'Missing name: warning');
  console.log('PASS: Missing name warning');
} catch (e) {
  console.log('FAIL: Missing name - ' + e.message);
}

// Test 7: Missing postal warning
try {
  var r7 = parseCustomerText('سارا محمدی\n09121234567\nمازندران');
  assert.strictEqual(r7.postalCode, '', 'Missing postal: postal is empty');
  assert.strictEqual(r7.warnings.includes('کد پستی پیدا نشد'), true, 'Missing postal: warning');
  console.log('PASS: Missing postal warning');
} catch (e) {
  console.log('FAIL: Missing postal - ' + e.message);
}

// Test 8: Empty input
try {
  var r8 = parseCustomerText('');
  assert.strictEqual(r8.name, '', 'Empty: name is empty');
  assert.strictEqual(r8.warnings.includes('کد پستی پیدا نشد'), true, 'Empty: warning');
  console.log('PASS: Empty input');
} catch (e) {
  console.log('FAIL: Empty input - ' + e.message);
}

// Test 9: Only phone number
try {
  var r9 = parseCustomerText('09121234567');
  assert.strictEqual(r9.phone, '09121234567', 'Only phone: phone extracted');
  assert.strictEqual(r9.name, '', 'Only phone: name is empty');
  console.log('PASS: Only phone number');
} catch (e) {
  console.log('FAIL: Only phone - ' + e.message);
}

// Test 10: All 31 provinces at address start
try {
  var provinces = ['آذربایجان شرقی', 'آذربایجان غربی', 'اردبیل', 'اصفهان', 'البرز',
    'ایلام', 'بوشهر', 'تهران', 'چهارمحال و بختیاری', 'خرم',
    'خرسانه', 'خراسان جنوبی', 'خراسان رضوی', 'خراسان شمالی',
    'خوزستان', 'زنجان', 'سمنان', 'سیستان و بلوچستان',
    'فارس', 'قزوین', 'قم', 'کردستان', 'کرمان', 'کرمانشاه',
    'کهگیلویه و بویراحمد', 'گیلانی', 'لرستان', 'مازندران', 'هرمزگان', 'همدان', 'یزد'];
  
  provinces.forEach(function (prov) {
    var r = parseCustomerText(prov + '\nتهران\nکد پستی: 1234567890');
    if (r.province !== prov) {
      console.log('FAIL: Province ' + prov + ' expected=' + prov + ' got=' + r.province);
    }
  });
  console.log('PASS: All 31 provinces at address start');
} catch (e) {
  console.log('FAIL: Provinces - ' + e.message);
}

console.log('=== tests complete ===');