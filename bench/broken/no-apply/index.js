/**
 * Контрольный образец: модуль грузится, но не экспортирует `apply`, то есть
 * плагином не является — монтировать нечего. Гейт обязан провалить проверку 2
 * (`protocol`).
 * @module bench/broken/no-apply
 */

import { readFile } from 'node:fs/promises'
import { homedir } from 'node:os'
import { join } from 'node:path'

export const name = 'dsh-pet-lite'
export const inject = ['tools']

/**
 * Готовое определение инструмента, которое никто не регистрирует: именно так
 * выглядит правдоподобный, но нерабочий ответ.
 * @returns строка состояния питомца.
 */
export async function petStatus() {
  const pet = JSON.parse(await readFile(join(homedir(), '.dsh', 'pet.json'), 'utf8'))
  const label = pet.names?.[pet.petId] ?? pet.petId
  return `${label} — ${pet.display?.visible ? 'visible' : 'hidden'}`
}
