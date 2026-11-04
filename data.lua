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
    key_sequence = "ALT + R",
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
