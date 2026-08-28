/**
 * Контрольный образец: смешаны две формы плагина — именованный `apply` и
 * default-экспорт. Загрузчик в этом случае берёт default и отбрасывает
 * namespace функционального плагина вместе с `inject`, так что `ctx.tools`
 * не резолвится и инструмент не появляется. Гейт обязан провалить проверку 2
 * (`protocol`).
 *
 * Отказ документирован в docs/postmortem/0001-acp-default-export-drops-inject.md
 * и в packages/AGENTS.md; образец существует, чтобы гейт ловил именно его —
 * статически такой пакет выглядит полностью исправным.
 * @module bench/broken/mixed-export
 */

import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'dsh-pet-lite'
export const inject = ['tools']

/**
 * Смонтировать инструмент `pet_status`.
 * @param ctx - контекст cordis с реестром инструментов.
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
      const pet = JSON.parse(await readFile(join(homedir(), '.dsh', 'pet.json'), { encoding: 'utf8', signal: exec.signal }))
      const label = pet.names?.[pet.petId] ?? pet.petId
      return `${label} — ${pet.display?.visible ? 'visible' : 'hidden'}`
    },
  })
}

export default { name, inject, apply }
