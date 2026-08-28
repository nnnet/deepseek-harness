/**
 * Контрольный образец: модуль не парсится. Гейт обязан провалить проверку 1
 * (`load`) и не дойти до остальных.
 *
 * Незакрытая фигурная скобка ниже — намеренная. Не «чинить».
 * @module bench/broken/no-load
 */

export const name = 'dsh-pet-lite'
export const inject = ['tools']

export function apply(ctx) {
  ctx.tools.register({
    name: 'pet_status',
