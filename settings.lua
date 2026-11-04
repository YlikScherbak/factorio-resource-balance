data:extend({
  -- фоновий облік станів машин (історія простою): як часто опитувати кожну машину; off — вимкнено.
  -- Налаштування карти: опитування спільне для всіх гравців.
  {
    type = "string-setting",
    name = "resbal-history-interval",
    setting_type = "runtime-global",
    default_value = "10",
    allowed_values = {"off", "5", "10", "30"},
    order = "a",
  },
  {
    type = "bool-setting",
    name = "resbal-close-on-esc",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "a",
  },
  {
    type = "string-setting",
    name = "resbal-refresh",
    setting_type = "runtime-per-user",
    default_value = "auto",
    allowed_values = {"auto", "1", "5", "10"},
    order = "b",
  },
  -- як часто перепошукувати машини у вкладці «Виробники й споживачі» (стани, кількість), секунд
  {
    type = "string-setting",
    name = "resbal-scan-interval",
    setting_type = "runtime-per-user",
    default_value = "30",
    allowed_values = {"10", "30", "60"},
    order = "bb",
  },
  {
    type = "string-setting",
    name = "resbal-number-format",
    setting_type = "runtime-per-user",
    default_value = "auto",
    allowed_values = {"auto", "short", "full"},
    order = "c",
  },
  -- «Сторож»: індикатори (червоний дзвіночок, лічильник на кнопці мода) — завжди; чат і звук — за бажанням
  {
    type = "bool-setting",
    name = "resbal-watch-chat",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "d",
  },
  {
    type = "bool-setting",
    name = "resbal-watch-sound",
    setting_type = "runtime-per-user",
    default_value = false,
    order = "e",
  },
  -- автопозначки на графіку ресурсу: спрацювання й відновлення сторожа
  {
    type = "bool-setting",
    name = "resbal-watch-marks",
    setting_type = "runtime-per-user",
    default_value = true,
    order = "f",
  },
})
