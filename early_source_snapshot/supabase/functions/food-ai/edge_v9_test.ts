// Network-free contract tests. All provider/auth/quota responses below are fakes.
let handler: (req: Request) => Promise<Response>;
const serve = Deno.serve;
(Deno as any).serve = (fn: typeof handler) => { handler = fn; return {}; };
const modulePath = Deno.env.get('FOOD_AI_TEST_MODULE') ?? './index.ts';
const { cleanItems, cleanSupplements, cleanDiaryEntries, cleanDiaryResult } = await import(modulePath);
(Deno as any).serve = serve;

Deno.env.set('SUPABASE_URL', 'https://mock-supabase.invalid');
Deno.env.set('APP_PUBLIC_KEY', 'public-test-only');
Deno.env.set('GEMINI_API_KEY', 'fake-key-never-used-on-network');
Deno.env.set('GEMINI_MODEL', 'gemini-test');
let allowed = true, geminiStatus = 200, generated: unknown = { items: [] };
let geminiStatuses: number[] = [];
let quotaCalls = 0, geminiCalls = 0, generatedRequest: any = null;
const actualFetch = globalThis.fetch;
globalThis.fetch = async (input: RequestInfo | URL, init?: RequestInit): Promise<Response> => {
  const request = input instanceof Request ? input : new Request(input, init);
  const url = new URL(request.url);
  if (url.hostname === 'mock-supabase.invalid' && url.pathname.endsWith('/auth/v1/user')) {
    if (request.headers.get('Authorization') !== 'Bearer valid-test-token') {
      return new Response(JSON.stringify({ message: 'invalid' }), { status: 401, headers: { 'content-type': 'application/json' } });
    }
    return new Response(JSON.stringify({ id: 'mock-user', aud: 'authenticated', app_metadata: {}, user_metadata: {}, created_at: '2026-10-28T00:00:00Z' }), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  if (url.hostname === 'mock-supabase.invalid' && url.pathname.endsWith('/rest/v1/rpc/reserve_fitness_ai_call')) {
    quotaCalls++;
    return new Response(JSON.stringify(allowed), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  if (url.hostname === 'generativelanguage.googleapis.com') {
    geminiCalls++;
    generatedRequest = await request.json();
    const status = geminiStatuses.shift() ?? geminiStatus;
    if (status !== 200) return new Response('{}', { status, headers: { 'content-type': 'application/json' } });
    return new Response(JSON.stringify({ candidates: [{ content: { parts: [{ text: JSON.stringify(generated) }] } }] }), { status: 200, headers: { 'content-type': 'application/json' } });
  }
  throw new Error(`Unexpected network access in test: ${url}`);
};

function assert(value: unknown, message = 'assertion failed'): asserts value { if (!value) throw new Error(message); }
function equal(a: unknown, b: unknown) { assert(JSON.stringify(a) === JSON.stringify(b), `Expected ${JSON.stringify(b)}, got ${JSON.stringify(a)}`); }
function reset() { allowed = true; geminiStatus = 200; geminiStatuses = []; quotaCalls = 0; geminiCalls = 0; generatedRequest = null; generated = { items: [] }; }
function req(body: unknown, token = 'valid-test-token') {
  return new Request('https://local.invalid/food-ai', { method: 'POST', headers: { 'content-type': 'application/json', authorization: `Bearer ${token}` }, body: JSON.stringify(body) });
}
const food = {
  name: 'Яблоко', grams: 150, calories: 52, protein: .3, fat: .2, carbs: 14,
  meal: 'snack', assumptions: 'Оценка', micros: { vitaminC: 10, vitaminB12: .04 },
};
const supplement = {
  name: 'Витамин D', quantity: 1, unit: 'capsule', nutrientKey: 'vitaminD',
  strength: 2000, strengthUnit: 'iu', assumptions: 'Проверьте этикетку',
};

Deno.test('pure server validation rejects bad units/numbers and discards unknown micronutrients', () => {
  equal(cleanItems([{ ...food, micros: { vitaminC: 10, secret: 99 } }])?.[0].micros, { vitaminC: 10 });
  equal(cleanItems([{ ...food, micros: undefined }])?.[0].micros, {});
  assert(cleanItems([{ ...food, micros: { vitaminC: -1 } }]) === null);
  assert(cleanItems([{ ...food, micros: { vitaminC: Infinity } }]) === null);
  assert(cleanItems([{ ...food, micros: { vitaminC: 100001 } }]) === null);
  assert(cleanItems([{ ...food, grams: 0 }]) === null);
  assert(cleanItems(Array.from({ length: 31 }, () => food)) === null);
  assert(cleanSupplements([{ ...supplement, quantity: -1 }]) === null);
  assert(cleanSupplements([{ ...supplement, unit: 'spoon' }]) === null);
  assert(cleanSupplements([{ ...supplement, strength: Infinity }]) === null);
  equal(cleanSupplements([{ ...supplement, quantity: 0, unit: 'unknown', strength: 0, strengthUnit: 'unknown', token: 'private' }])?.[0],
    { ...supplement, quantity: 0, unit: 'unknown', strength: 0, strengthUnit: 'unknown' });
});

Deno.test('auth required even when gateway JWT verification is disabled', async () => {
  reset();
  const missing = await handler(new Request('https://local.invalid/food-ai', { method: 'POST', body: '{}' }));
  equal(missing.status, 401);
  const invalid = await handler(req({ mode: 'food', text: 'еда' }, 'bad-token'));
  equal(invalid.status, 401);
  equal(quotaCalls, 0); equal(geminiCalls, 0);
});

Deno.test('food schema includes optional per-100g micronutrients and never exposes extra fields', async () => {
  reset(); generated = { items: [{ ...food, micros: { ...food.micros, secret: 1 }, profile: 'private' }] };
  const response = await handler(req({ mode: 'food', text: 'яблоко 150 г' }));
  equal(response.status, 200); equal(quotaCalls, 1); equal(geminiCalls, 1);
  const out = await response.json();
  equal(out.items[0].micros, food.micros);
  assert(!('profile' in out.items[0]));
  assert(generatedRequest.systemInstruction.parts[0].text.includes('per 100 grams'));
  assert(generatedRequest.systemInstruction.parts[0].text.includes('Omit unsupported/unknown keys'));
  const schema = generatedRequest.generationConfig.responseSchema.properties.items.items;
  assert(schema.required.includes('micros'));
  assert('vitaminC' in schema.properties.micros.properties);
  assert(!('private' in schema.properties));
});

Deno.test('supplement mode separately passes editable amount and never requests recommendations', async () => {
  reset(); generated = { items: [supplement] };
  const response = await handler(req({ mode: 'supplement', text: '1 капсула витамина D, 2000 МЕ на капсулу' }));
  equal(response.status, 200); equal((await response.json()).items[0], supplement);
  assert(generatedRequest.systemInstruction.parts[0].text.includes('Never suggest a dose'));
  equal(generatedRequest.generationConfig.responseSchema.properties.items.items.properties.unit.enum.includes('capsule'), true);
});

Deno.test('refinement receives only validated prior items with micronutrients and no private fields', async () => {
  reset(); generated = { items: [food] };
  const response = await handler(req({ mode: 'refine', text: '200 граммов', previousItems: [{ ...food, image: 'private', profile: 80 }] }));
  equal(response.status, 200);
  const payload = JSON.parse(generatedRequest.contents[0].parts[0].text);
  equal(payload.currentDraft[0].micros, food.micros);
  assert(!('image' in payload.currentDraft[0])); assert(!('profile' in payload.currentDraft[0]));
  equal((await handler(req({ mode: 'refine', text: '', previousItems: [food] }))).status, 400);
  equal((await handler(req({ mode: 'refine', text: 'change', previousItems: [{ ...food, micros: { vitaminC: -3 } }] }))).status, 400);
});

Deno.test('invalid requests rejected before quota; invalid generated output rejected before diary', async () => {
  reset();
  equal((await handler(req({ mode: 'invalid', text: 'hi' }))).status, 400);
  equal((await handler(req({ mode: 'label', text: 'hi' }))).status, 400);
  equal((await handler(req({ mode: 'supplement', text: 'hi', image: 'not_base64!', mime: 'image/jpeg' }))).status, 400);
  equal(quotaCalls, 0); equal(geminiCalls, 0);
  generated = { items: [{ ...food, micros: { vitaminC: -1 } }] };
  equal((await handler(req({ mode: 'food', text: 'яблоко' }))).status, 502);
  generated = { items: [{ ...supplement, quantity: -2 }] };
  equal((await handler(req({ mode: 'supplement', text: 'D' }))).status, 502);
});

Deno.test('quota and provider errors fail closed without a paid fallback', async () => {
  reset(); allowed = false;
  equal((await handler(req({ text: 'еда' }))).status, 429); equal(geminiCalls, 0);
  allowed = true; geminiStatus = 429;
  const result = await handler(req({ text: 'еда' }));
  equal(result.status, 429); assert((await result.json()).error.includes('no paid fallback'));
  equal(geminiCalls, 1); // Quota errors are never retried.
});

Deno.test('temporary provider 503 is retried with one app quota reservation', async () => {
  reset(); generated = { items: [food] }; geminiStatuses = [503, 200];
  const result = await handler(req({ mode: 'refine', text: '200 граммов', previousItems: [food] }));
  equal(result.status, 200); equal((await result.json()).items[0], food);
  equal(quotaCalls, 1); equal(geminiCalls, 2);
  assert(generatedRequest.contents[0].parts[0].text.includes('currentDraft'));
});

Deno.test('persistent provider 503 stops after three attempts; bad requests are not retried', async () => {
  reset(); geminiStatus = 503;
  const response = await handler(req({ mode: 'refine', text: '200 граммов', previousItems: [food] }));
  equal(response.status, 503); assert((await response.json()).error.includes('overloaded'));
  equal(quotaCalls, 1); equal(geminiCalls, 3);
  reset(); geminiStatus = 400;
  equal((await handler(req({ text: 'еда' }))).status, 502);
  equal(quotaCalls, 1); equal(geminiCalls, 1);
});

// Restore global fetch after the process exits; no actual external call is made.
globalThis.addEventListener('unload', () => { globalThis.fetch = actualFetch; });

const diaryEntry = { ref: 'f1', day: '2026-10-28', ...food };
const diaryBody = { mode: 'diary', text: 'Добавь недостающие витамины', firstDay: '2026-10-01', lastDay: '2026-10-31', replaceKnownMicros: false, entries: [diaryEntry] };
Deno.test('diary mode shares only selected pseudonymous food fields and protects known vitamins', async () => {
  reset();
  generated = { analysis: 'Данные неполные, проверьте оценку.', actions: [{ kind: 'update', ref: 'f1', day: '2026-10-28', reason: 'Оценка', patch: { micros: { vitaminC: 99, vitaminD: 2 } } }] };
  const response = await handler(req({ ...diaryBody, entries: [{ ...diaryEntry, id: 'real-private-id', profile: 'private' }], weight: 80 }));
  equal(response.status, 200);
  const result = await response.json();
  equal(result.actions[0].patch.micros, { vitaminD: 2 });
  const sent = JSON.parse(generatedRequest.contents[0].parts[0].text);
  assert(!('weight' in sent)); assert(!('id' in sent.entries[0])); assert(!('profile' in sent.entries[0]));
  assert(!('assumptions' in sent.entries[0]));
  assert(generatedRequest.systemInstruction.parts[0].text.includes('never change known values'));
  equal(generatedRequest.generationConfig.responseSchema.required, ['analysis', 'actions']);
  equal(quotaCalls, 1); equal(geminiCalls, 1);
});

Deno.test('diary explicit override, add and delete are returned only as proposals', async () => {
  reset();
  generated = { analysis: 'Проверьте изменения.', actions: [
    { kind: 'update', ref: 'f1', day: '2026-10-28', reason: 'По запросу', patch: { micros: { vitaminC: 99 }, grams: 200 } },
    { kind: 'add', ref: '', day: '2026-10-29', reason: 'По запросу', patch: { name: 'Груша', grams: 100, calories: 40, protein: 1, fat: 0, carbs: 10, meal: 'snack', micros: {} } },
  ] };
  const r = await handler(req({ ...diaryBody, replaceKnownMicros: true }));
  equal(r.status, 200); const out = await r.json();
  equal(out.actions[0].patch.micros, { vitaminC: 99 }); equal(out.actions[1].kind, 'add');
  generated = { analysis: 'Удаление предложено.', actions: [{ kind: 'delete', ref: 'f1', day: '2026-10-28', reason: 'По запросу', patch: {} }] };
  equal((await handler(req(diaryBody))).status, 200);
});

Deno.test('diary rejects forged references, duplicates, changed days and incomplete additions', async () => {
  const clean = cleanDiaryEntries([diaryEntry], diaryBody.firstDay, diaryBody.lastDay)!;
  assert(cleanDiaryResult({ analysis: 'ok', actions: [{ kind: 'delete', ref: 'f2', day: '2026-10-28', reason: '', patch: {} }] }, clean, diaryBody.firstDay, diaryBody.lastDay, false) === null);
  assert(cleanDiaryResult({ analysis: 'ok', actions: [{ kind: 'delete', ref: 'f1', day: '2026-10-29', reason: '', patch: {} }] }, clean, diaryBody.firstDay, diaryBody.lastDay, false) === null);
  const dup = { kind: 'delete', ref: 'f1', day: '2026-10-28', reason: '', patch: {} };
  assert(cleanDiaryResult({ analysis: 'ok', actions: [dup, dup] }, clean, diaryBody.firstDay, diaryBody.lastDay, false) === null);
  assert(cleanDiaryResult({ analysis: 'ok', actions: [{ kind: 'add', ref: '', day: '2026-10-29', reason: '', patch: { name: 'Еда' } }] }, clean, diaryBody.firstDay, diaryBody.lastDay, false) === null);
  reset(); generated = { analysis: 'ok', actions: [{ kind: 'delete', ref: 'f77', day: '2026-10-28', reason: '', patch: {} }] };
  equal((await handler(req(diaryBody))).status, 502);
});

Deno.test('diary input bounds and invalid data fail before quota is consumed', async () => {
  reset();
  equal((await handler(req({ ...diaryBody, firstDay: '2026-02-31' }))).status, 400);
  equal((await handler(req({ ...diaryBody, entries: Array.from({length:61}, (_, i) => ({ ...diaryEntry, ref: `f${i+1}` })) }))).status, 400);
  equal((await handler(req({ ...diaryBody, entries: [{ ...diaryEntry, micros: { vitaminC: -1 } }] }))).status, 400);
  equal((await handler(req({ ...diaryBody, image: 'a', mime: 'image/jpeg' }))).status, 400);
  equal(quotaCalls, 0); equal(geminiCalls, 0);
});
