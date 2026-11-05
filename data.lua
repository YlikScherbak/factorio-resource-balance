-- власна іконка: 64×64 + мип-рівні 32/16/8 поруч (120×64), як у ванільних іконках
local ICON = "__resource-balance__/graphics/icon.png"
local WHITE = "__core__/graphics/white-square.png"

data:extend({
  {
    type = "custom-input",
    name = "resbal-toggle",
    key_sequence = "CONTROL + SHIFT + R",
    consuming = "none",
    order = "a",
  },
  -- додати в поточний список те, що під курсором: предмет, рідину, рецепт або машину (її продукт)
  {
    type = "custom-input",
    name = "resbal-add-hovered",
    key_sequence = "CONTROL + ALT + R",
    consuming = "none",
    include_selected_prototype = true,
    order = "b",
  },
  {
    type = "shortcut",
    name = "resbal-toggle",
    action = "lua",
    associated_control_input = "resbal-toggle",
    toggleable = true,
    icon = ICON,
    icon_size = 64,
    small_icon = ICON,
    small_icon_size = 64,
    order = "z[resource-balance]",
  },
  {
    type = "sprite",
    name = "resbal-icon",
    filename = ICON,
    size = 64,
    flags = {"gui-icon"},
  },
})

-- Відрізки ліній міні-графіка: суцільний колір (білий квадрат з тонуванням)
local styles = data.raw["gui-style"].default
local function line_style(tint)
  return {
    type = "empty_widget_style",
    width = 2,
    graphical_set = {base = {filename = WHITE, position = {0, 0}, corner_size = 1, tint = tint}},
  }
end
styles.resbal_line_prod = line_style({r = 0.35, g = 0.9, b = 0.35})  -- виробництво
styles.resbal_line_cons = line_style({r = 1, g = 0.4, b = 0.35})     -- споживання

-- Прозора «колонка» поверх великого графіка: підказка зі значеннями в точці,
-- при наведенні ледь помітно підсвічується (як вертикальний курсор у грі)
-- тонування з прозорістю — premultiplied alpha: колір теж множиться на a (інакше виходить суцільний білий)
local highlight = {base = {filename = WHITE, position = {0, 0}, corner_size = 1,
                           tint = {r = 0.08, g = 0.08, b = 0.08, a = 0.08}}}
-- Лічильник машин, що не працюють (вкладка виробників): клік — показати наступну на мапі
local status_hover = {base = {filename = WHITE, position = {0, 0}, corner_size = 1,
                              tint = {r = 0.25, g = 0.25, b = 0.25, a = 0.25}}}
styles.resbal_status_button = {
  type = "button_style",
  parent = "transparent_button",
  minimal_width = 0,
  height = 24,
  top_padding = 0,
  bottom_padding = 0,
  left_padding = 4,
  right_padding = 4,
  default_font_color = {1, 1, 1},
  hovered_font_color = {1, 1, 1},
  clicked_font_color = {1, 1, 1},
  hovered_graphical_set = status_hover,
  clicked_graphical_set = status_hover,
}

styles.resbal_column_button = {
  type = "button_style",
  parent = "transparent_button",
  minimal_width = 0,
  minimal_height = 0,
  hovered_graphical_set = highlight,
  clicked_graphical_set = highlight,
}

-- ---------- Редизайн 1.7: власні стилі (префікс resbal_, не rb_ — rb колись конфліктував з Recipe Book) ----------
-- Колір несе значок стану, а не текст; червоне — лише деструктивні дії й тривоги.
local red = styles.red_button

-- Вузька кнопка проміжку / вікна усереднення
styles.resbal_period_button = {
  type = "button_style", parent = "button",
  minimal_width = 36, height = 28, left_padding = 6, right_padding = 6,
}
-- Чип ресурсу (порівняння, причини) і лічильник стану машин — видно, що це кнопки
styles.resbal_chip = {
  type = "button_style", parent = "button",
  height = 24, minimal_width = 0, left_padding = 4, right_padding = 6, font = "default-small",
}
styles.resbal_state_chip = {type = "button_style", parent = "resbal_chip", height = 20, left_padding = 2, right_padding = 4}
-- Дія в рядку таблиці: темна пласка кнопка (як кнопки в заголовку вікна)
styles.resbal_row_icon = {
  type = "button_style", parent = "frame_action_button", size = 28,
  invert_colors_of_picture_when_hovered_or_toggled = false,
}
-- «Видалити» в рядку: сіра, червоніє лише при наведенні
styles.resbal_row_remove = {
  type = "button_style", parent = "frame_action_button", size = 28,
  invert_colors_of_picture_when_hovered_or_toggled = false,
  hovered_graphical_set = red.hovered_graphical_set,
  clicked_graphical_set = red.clicked_graphical_set,
}
-- Службовий сірий текст — єдиний «сірий» у моді
styles.resbal_quiet_label = {type = "label_style", parent = "label", font_color = {0.7, 0.7, 0.7}}
-- Рядок причини / висновку: звичайний колір, перенос
styles.resbal_cause_label = {type = "label_style", parent = "label", single_line = false, maximal_width = 740}
-- Смужка частки
styles.resbal_share_bar = {type = "progressbar_style", parent = "progressbar", width = 80}
