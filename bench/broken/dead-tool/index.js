/**
 * Контрольный образец: инструмент зарегистрирован и формально безупречен, но
 * отвечает константой вместо чтения файла. Гейт обязан провалить проверку 4
 * (`execute`) — на фикстуре `visible` ответ случайно совпадёт, на `hidden` нет.
 *
 * Это и есть «синтаксически валидный мусор», ради отделения которого гейт
 * гоняет две фикстуры вместо одной.
 * @module bench/broken/dead-tool
 */

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
    async execute() {
      return 'Выдра-эталон — visible'
    },
  })
}
