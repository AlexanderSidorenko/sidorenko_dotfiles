local wezterm = require("wezterm")

local config = wezterm.config_builder and wezterm.config_builder() or {}

local font_name = "DroidSansM Nerd Font"
local font_size = 14.0
local font_dpi = 160

config.font = wezterm.font(font_name, { weight = "Regular" })
config.font_size = font_size
config.dpi = font_dpi

return config
