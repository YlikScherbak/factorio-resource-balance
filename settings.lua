data:extend({
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
})
