/**
 * Контрольный образец эталонной задачи бенчмарка: заведомо рабочий ответ на
 * `bench/task.md`. Существует, чтобы подтверждать сам гейт — приёмка, которая
 * никогда не возвращала 0 на известно правильном пакете, ничего не значит.
 *
 * Пишется руками и меняется только вместе со спецификацией задачи.
 * @module bench/reference/dsh-pet-lite
 */

import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'dsh-pet-lite'
export const inject = ['tools']

/**
 * Путь к файлу состояния питомца. Вычисляется на каждый вызов, а не один раз
 * при загрузке модуля: гейт подменяет HOME, и захваченное при импорте значение
 * читало бы чужой файл.
 * @returns абсолютный путь к `~/.dsh/pet.json`.
 */
function petFile() {
  return join(homedir(), '.dsh', 'pet.json')
}

/**
 * Смонтировать инструмент `pet_status` в вызывающую область.
 * @param ctx - контекст cordis с инжектированным реестром инструментов.
 */
export function apply(ctx) {
  ctx.tools.register({
    name: 'pet_status',
    description: 'Report the harness pet display name and whether it is currently shown.',
    parameters: { type: 'object', properties: {} },
    output: {
      schema: { type: 'string' },
      render: (_args, value) => [{ type: 'text', text: value }],
    },
    async execute(_args, exec) {
      const pet = JSON.parse(await readFile(petFile(), { encoding: 'utf8', signal: exec.signal }))
      const label = pet.names?.[pet.petId] ?? pet.petId
      return `${label} — ${pet.display?.visible ? 'visible' : 'hidden'}`
    },
  })
}
