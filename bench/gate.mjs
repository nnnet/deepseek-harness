#!/usr/bin/env node
/**
 * Машинная приёмка эталонной задачи бенчмарка (узел `A1` плана
 * `.claude/plans/2026-08-27T20-36__dsh-local-qwen38-optimization.md`).
 * Спецификация задачи и смысл проверок — в `bench/task.md`.
 *
 *   node bench/gate.mjs <путь-к-каталогу-пакета>
 *   node bench/gate.mjs --self-test
 *
 * Код возврата 0 = приёмка пройдена. Последняя строка вывода всегда
 * `gate=1` или `gate=0` — её читает прогонщик (узел `A4`).
 *
 * Гейт не поднимает dsh и не обращается к модели: реестр инструментов и
 * домашний каталог подменяются заглушками. Сквозная проверка «модель вызвала
 * `pet_status` в собранном приложении» — работа прогонщика, не этого файла.
 *
 * Проверка 4 выполняется на двух фикстурах, различающихся одним полем
 * `display.visible`, в ОТДЕЛЬНЫХ процессах: подменять HOME нужно до импорта
 * модуля (плагин вправе вычислить путь один раз на верхнем уровне), а
 * повторный импорт того же файла в одном процессе отдаёт закешированный
 * модуль. Отдельный процесс заодно изолирует падение кандидата.
 * @module bench/gate
 */

import { spawnSync } from 'node:child_process'
import { existsSync, readFileSync } from 'node:fs'
import { dirname, join, relative, resolve } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'

const SELF = fileURLToPath(import.meta.url)
const BENCH_DIR = dirname(SELF)

/** Потолок одного вызова `execute` в заглушке. Кандидат вправе зависнуть. */
const EXECUTE_TIMEOUT_MS = 15_000

/** Потолок дочернего процесса проверки: импорт плюс один вызов с запасом. */
const PROBE_TIMEOUT_MS = 60_000

/** Порядок проверок, он же порядок вывода. Проверка не начинается, если предыдущая провалена. */
const CHECK_IDS = ['load', 'protocol', 'register', 'execute']

/**
 * Фикстуры домашнего каталога. Отличаются одним полем `display.visible`:
 * плагин, зашивший ответ константой, проходит первую и валится на второй.
 */
const FIXTURES = [
  { id: 'visible', home: join(BENCH_DIR, 'fixtures', 'visible'), expected: 'Выдра-эталон — visible' },
  { id: 'hidden', home: join(BENCH_DIR, 'fixtures', 'hidden'), expected: 'Выдра-эталон — hidden' },
]

/** Контрольные образцы и ожидаемый от них код возврата — ими проверяется сам гейт. */
const SELF_TEST_CASES = [
  { dir: 'reference/dsh-pet-lite', expectPass: true, fails: '' },
  { dir: 'broken/no-load', expectPass: false, fails: 'load' },
  { dir: 'broken/no-apply', expectPass: false, fails: 'protocol' },
  { dir: 'broken/mixed-export', expectPass: false, fails: 'protocol' },
  { dir: 'broken/dead-tool', expectPass: false, fails: 'execute' },
]

/**
 * Вытащить точку входа пакета из его манифеста.
 * @param pkgDir - каталог пакета.
 * @returns абсолютный путь к файлу модуля.
 * @throws если манифеста нет, он не парсится или файла входа не существует.
 */
function entryFile(pkgDir) {
  const manifest = join(pkgDir, 'package.json')
  if (!existsSync(manifest)) throw new Error(`нет package.json в ${pkgDir}`)
  let pkg
  try {
    pkg = JSON.parse(readFileSync(manifest, 'utf8'))
  } catch (error) {
    throw new Error(`package.json не парсится: ${error.message}`)
  }
  const rel = exportsEntry(pkg.exports) ?? pkg.main ?? 'index.js'
  const file = resolve(pkgDir, rel)
  if (!existsSync(file)) throw new Error(`точка входа не найдена: ${rel}`)
  return file
}

/**
 * Свести поле `exports` манифеста к одному относительному пути.
 * @param exp - значение поля `exports`, если оно есть.
 * @returns относительный путь или `undefined`, если поле не задано или нераспознаваемо.
 */
function exportsEntry(exp) {
  if (typeof exp === 'string') return exp
  if (exp === null || typeof exp !== 'object') return undefined
  const dot = exp['.'] ?? exp
  if (typeof dot === 'string') return dot
  if (dot === null || typeof dot !== 'object') return undefined
  const picked = dot.import ?? dot.default
  return typeof picked === 'string' ? picked : undefined
}

/**
 * Заглушка контекста cordis: настоящий реестр инструментов и терпимый прокси
 * на всё остальное, до чего кандидат может дотянуться.
 *
 * `effect` и `inject` ВЫЗЫВАЮТ переданный колбэк — регистрация, завёрнутая в
 * них, иначе потерялась бы и дала ложный провал. `get` отдаёт `undefined` для
 * всего, кроме `tools`: отсутствие сервиса — законный ответ, а прокси на его
 * месте заставил бы кандидата пойти по несуществующей ветке.
 * @param registered - массив, куда складываются зарегистрированные определения.
 * @returns объект, пригодный как аргумент `apply(ctx)`.
 */
function makeStubContext(registered) {
  const tools = {
    register(definition) {
      registered.push(definition)
      return () => {}
    },
    restrict: () => () => {},
  }
  const base = {
    tools,
    get: (name) => (name === 'tools' ? tools : undefined),
    effect: (callback) => {
      const disposer = typeof callback === 'function' ? callback() : undefined
      return typeof disposer === 'function' ? disposer : () => {}
    },
    on: () => () => {},
    emit: () => {},
    plugin(plugin, config) {
      if (typeof plugin === 'function') plugin(this, config)
      else if (plugin && typeof plugin.apply === 'function') plugin.apply(this, config)
      return { dispose: () => {} }
    },
    provide: () => {},
  }
  base.inject = (_deps, callback) => {
    if (typeof callback === 'function') callback(proxy)
  }
  const proxy = new Proxy(base, {
    get: (target, prop) => (prop in target ? target[prop] : prop === 'then' ? undefined : noop()),
    has: () => true,
  })
  return proxy
}

/**
 * Вызываемая и индексируемая пустышка: покрывает `ctx.logger('x').info(...)`
 * и прочие цепочки, которых заглушка не перечисляет поимённо.
 * @returns прокси, отвечающий пустышкой на любой вызов и любое свойство.
 */
function noop() {
  const fn = () => noop()
  return new Proxy(fn, {
    get: (_t, prop) => (prop === 'then' ? undefined : noop()),
    apply: () => noop(),
  })
}

/**
 * Проверить определение инструмента по контракту `ToolRuntime.register()`
 * (`packages/core/tools/src/index.ts:1037`) и по спецификации задачи.
 * @param def - зарегистрированное определение.
 * @returns список нарушений; пустой список означает соответствие.
 */
function definitionViolations(def) {
  const bad = []
  if (typeof def.description !== 'string' || def.description.trim() === '') bad.push('description пуст или не строка')
  if (def.parameters === null || typeof def.parameters !== 'object') bad.push('parameters не объект')
  else if (def.parameters.type !== 'object') bad.push(`parameters.type = ${JSON.stringify(def.parameters.type)}, ожидался "object"`)
  const out = def.output
  if (out === null || typeof out !== 'object') bad.push('нет output { schema, render }')
  else {
    if (out.schema === null || typeof out.schema !== 'object') bad.push('output.schema не объект')
    else if (out.schema.type !== 'string') bad.push(`output.schema.type = ${JSON.stringify(out.schema.type)}, ожидался "string"`)
    if (typeof out.render !== 'function') bad.push('output.render не функция')
    if (out.presentationMeta !== undefined && typeof out.presentationMeta !== 'function') bad.push('output.presentationMeta задан, но не функция')
  }
  if (typeof def.execute !== 'function') bad.push('execute не функция')
  if (def.timeoutMs !== undefined && (!Number.isFinite(def.timeoutMs) || def.timeoutMs <= 0)) bad.push('timeoutMs не положительное конечное число')
  return bad
}

/**
 * Ограничить ожидание промиса.
 * @param promise - ожидаемый промис.
 * @param ms - потолок в миллисекундах.
 * @returns значение промиса.
 * @throws если потолок исчерпан раньше.
 */
async function withTimeout(promise, ms) {
  let timer
  try {
    return await Promise.race([
      promise,
      new Promise((_res, rej) => {
        timer = setTimeout(() => { rej(new Error(`не ответил за ${ms} мс`)) }, ms)
        timer.unref?.()
      }),
    ])
  } finally {
    clearTimeout(timer)
  }
}

/**
 * Прогнать четыре проверки над одним пакетом на одной фикстуре, в текущем
 * процессе. HOME уже подменён вызывающим — до импорта модуля.
 * @param entry - абсолютный путь к точке входа.
 * @param expected - строка, которую обязан вернуть `pet_status`.
 * @returns список вердиктов `{ id, ok, detail }` в порядке {@link CHECK_IDS}.
 */
async function runChecks(entry, expected) {
  const verdicts = []
  const pass = (id) => { verdicts.push({ id, ok: true, detail: '' }); return true }
  const fail = (id, detail) => { verdicts.push({ id, ok: false, detail }); return false }

  let mod
  try {
    mod = await import(pathToFileURL(entry).href)
  } catch (error) {
    return (fail('load', error.message), verdicts)
  }
  pass('load')

  const applyFn = typeof mod.apply === 'function' ? mod.apply : undefined
  if (applyFn === undefined) return (fail('protocol', 'нет именованного экспорта apply(ctx)'), verdicts)
  if (typeof mod.name !== 'string' || mod.name === '') return (fail('protocol', 'нет непустого именованного экспорта name'), verdicts)
  if (Object.hasOwn(mod, 'default')) {
    return (fail('protocol', 'есть и apply, и default-экспорт: загрузчик возьмёт default и отбросит namespace вместе с inject'), verdicts)
  }
  if (!Array.isArray(mod.inject) || !mod.inject.includes('tools')) {
    return (fail('protocol', `inject не содержит 'tools' (получено ${JSON.stringify(mod.inject)})`), verdicts)
  }
  pass('protocol')

  const registered = []
  try {
    await applyFn(makeStubContext(registered), {})
  } catch (error) {
    return (fail('register', `apply бросил: ${error.message}`), verdicts)
  }
  const def = registered.find(entryDef => entryDef !== null && typeof entryDef === 'object' && entryDef.name === 'pet_status')
  if (def === undefined) {
    const seen = registered.map(d => (d && d.name) ?? '<без имени>').join(', ')
    return (fail('register', `pet_status не зарегистрирован (зарегистрировано: ${seen || 'ничего'})`), verdicts)
  }
  const violations = definitionViolations(def)
  if (violations.length > 0) return (fail('register', violations.join('; ')), verdicts)
  pass('register')

  const controller = new AbortController()
  const args = Object.freeze({})
  const exec = {
    callId: 'gate-1',
    name: 'pet_status',
    arguments: args,
    signal: controller.signal,
    token: Symbol('gate'),
    agent: undefined,
    parent: undefined,
  }
  let value
  try {
    value = await withTimeout(def.execute(args, exec), EXECUTE_TIMEOUT_MS)
  } catch (error) {
    return (fail('execute', `execute бросил: ${error.message}`), verdicts)
  }
  if (typeof value !== 'string') return (fail('execute', `вернул ${typeof value}, ожидалась строка`), verdicts)
  const normalized = value.replace(/\s+/gu, ' ').trim()
  if (normalized !== expected) return (fail('execute', `вернул ${JSON.stringify(normalized)}, ожидалось ${JSON.stringify(expected)}`), verdicts)
  let rendered
  try {
    rendered = def.output.render(args, value)
  } catch (error) {
    return (fail('execute', `output.render бросил: ${error.message}`), verdicts)
  }
  if (!Array.isArray(rendered) || rendered.length === 0 || rendered.some(b => b === null || typeof b !== 'object' || b.type !== 'text' || typeof b.text !== 'string')) {
    return (fail('execute', 'output.render вернул не список блоков { type: "text", text: string }'), verdicts)
  }
  pass('execute')
  return verdicts
}

/**
 * Режим дочернего процесса: подменить HOME, прогнать проверки, напечатать
 * вердикты одной строкой JSON.
 * @param entry - абсолютный путь к точке входа.
 * @param home - каталог фикстуры, подставляемый как HOME.
 * @param expected - ожидаемая строка ответа инструмента.
 */
async function probeMain(entry, home, expected) {
  process.env.HOME = home
  let finished = false
  // Кандидат вправе вызвать process.exit и «пройти» приёмку молчанием.
  process.on('exit', (code) => { if (!finished && code === 0) process.exitCode = 3 })
  const verdicts = await runChecks(entry, expected)
  finished = true
  process.stdout.write(`${JSON.stringify(verdicts)}\n`)
}

/**
 * Прогнать пакет на всех фикстурах и свести вердикты.
 * @param pkgDir - каталог проверяемого пакета.
 * @returns `{ ok, rows }`, где `rows` — по строке на проверку в порядке {@link CHECK_IDS}.
 */
function gatePackage(pkgDir) {
  let entry
  try {
    entry = entryFile(pkgDir)
  } catch (error) {
    return { ok: false, rows: [{ id: 'load', ok: false, detail: error.message }] }
  }
  /** @type {Map<string, { id: string, ok: boolean, detail: string }>} */
  const merged = new Map()
  for (const fixture of FIXTURES) {
    const run = spawnSync(process.execPath, [SELF, '--probe', entry, fixture.home, fixture.expected], {
      encoding: 'utf8',
      timeout: PROBE_TIMEOUT_MS,
      env: { ...process.env, HOME: fixture.home },
    })
    const line = (run.stdout ?? '').trim().split('\n').filter(Boolean).at(-1)
    let verdicts
    try {
      verdicts = line === undefined ? undefined : JSON.parse(line)
    } catch {
      verdicts = undefined
    }
    if (!Array.isArray(verdicts)) {
      const why = (run.stderr ?? '').trim().split('\n').at(-1) ?? `код ${run.status}`
      merged.set('load', { id: 'load', ok: false, detail: `проверка не отчиталась (${fixture.id}): ${why}` })
      break
    }
    for (const verdict of verdicts) {
      const prior = merged.get(verdict.id)
      // Провал на любой фикстуре — провал проверки; деталь берётся от первого провала.
      if (prior === undefined || (prior.ok && !verdict.ok)) {
        merged.set(verdict.id, { ...verdict, detail: verdict.ok ? '' : `${fixture.id}: ${verdict.detail}` })
      }
    }
  }
  const rows = CHECK_IDS.map(id => merged.get(id) ?? { id, ok: false, detail: 'не выполнялась' })
  return { ok: rows.every(row => row.ok), rows }
}

/**
 * Напечатать отчёт по одному пакету.
 * @param pkgDir - каталог пакета.
 * @param result - результат {@link gatePackage}.
 */
function report(pkgDir, result) {
  process.stdout.write(`пакет: ${relative(process.cwd(), pkgDir) || pkgDir}\n`)
  for (const [index, row] of result.rows.entries()) {
    const mark = row.ok ? 'OK  ' : 'FAIL'
    process.stdout.write(`  ${index + 1} ${row.id.padEnd(9)} ${mark}${row.detail ? `  ${row.detail}` : ''}\n`)
  }
}

/**
 * Режим `--self-test`: прогнать гейт по контрольным образцам и сверить, что
 * каждый падает на предсказанной проверке. Гейт, никогда не возвращавший 0 на
 * известно правильном пакете и не ловивший известные поломки, ничего не значит.
 * @returns код возврата процесса.
 */
function selfTest() {
  let failures = 0
  for (const testCase of SELF_TEST_CASES) {
    const dir = join(BENCH_DIR, testCase.dir)
    const result = gatePackage(dir)
    const firstFail = result.rows.find(row => !row.ok)
    const asExpected = testCase.expectPass
      ? result.ok
      : !result.ok && firstFail?.id === testCase.fails
    if (!asExpected) failures += 1
    const want = testCase.expectPass ? 'проходит' : `падает на ${testCase.fails}`
    process.stdout.write(`${asExpected ? 'OK  ' : 'FAIL'} ${testCase.dir.padEnd(24)} ожидалось: ${want}\n`)
    if (!asExpected) report(dir, result)
  }
  process.stdout.write(`\nконтрольных образцов: ${SELF_TEST_CASES.length}, расхождений: ${failures}\n`)
  process.stdout.write(`gate=${failures === 0 ? 1 : 0}\n`)
  return failures === 0 ? 0 : 1
}

const [, , first, ...rest] = process.argv

if (first === '--probe') {
  const [entry, home, expected] = rest
  await probeMain(entry, home, expected)
} else if (first === '--self-test') {
  process.exitCode = selfTest()
} else if (first === undefined || first === '--help' || first === '-h') {
  process.stdout.write('использование: node bench/gate.mjs <путь-к-каталогу-пакета> | --self-test\n')
  process.exitCode = first === undefined ? 2 : 0
} else {
  const pkgDir = resolve(first)
  const result = gatePackage(pkgDir)
  report(pkgDir, result)
  process.stdout.write(`gate=${result.ok ? 1 : 0}\n`)
  process.exitCode = result.ok ? 0 : 1
}
