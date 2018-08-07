local obs = _G.obslua

local NUM_SOURCES = 3
local triggered = false
local cachedContents = nil
local cachedMatches = nil
local cachedSettings = {
  sources = {}
}
local utils = {}

local function set_sources_visibility(value)
  -- use visibility of scene items instead of enabling/disabling sources
  -- because enabling/disabling sources is not exposed to the frontend AFAIK,
  -- so it's confusing for users (visible scene items don't show up for seemingly
  -- no reason)
  local sceneSource = obs.obs_frontend_get_current_scene()
  local scene = obs.obs_scene_from_source(sceneSource)
  local sceneitems = obs.obs_scene_enum_items(scene)

  if sceneitems ~= nil then
    for _, sceneitem in ipairs(sceneitems) do
      local source = obs.obs_sceneitem_get_source(sceneitem)
      local name = obs.obs_source_get_name(source)
      if utils.in_array(cachedSettings.sources, name) then
        obs.obs_sceneitem_set_visible(sceneitem, value)
        obs.obs_source_set_enabled(source, true)
      end
    end
  end

  obs.sceneitem_list_release(sceneitems)
  obs.obs_source_release(sceneSource)
end

local function reset()
  triggered = false
  obs.timer_remove(reset)

  set_sources_visibility(false)
end

local function trigger(duration)
  triggered = true
  if duration then
    obs.timer_add(reset, duration*1000)
  end

  set_sources_visibility(true)
end

local function prime()
  cachedContents = utils.get_file_contents(cachedSettings.file)
  cachedMatches = nil
end

local function should_check()
  if cachedSettings.file == "" then
    return false
  end

  if triggered then
    return cachedSettings.contentsmatch
  end

  return not triggered
end

local function check_callback()
  if should_check() then
    local contents = utils.get_file_contents(cachedSettings.file)

    if contents == cachedContents then
      return
    end

    if cachedSettings.anychange then
      trigger(cachedSettings.duration)
    else
      local matches = contents:gsub("%s+$", ""):match(cachedSettings.contents)
      if matches and not cachedMatches then
        local duration = cachedSettings.duration
        if cachedSettings.contentsmatch then
          duration = nil
        end
        trigger(duration)
      elseif not matches and triggered and cachedSettings.contentsmatch then
        reset()
      end
      cachedMatches = matches ~= nil
    end

    cachedContents = contents
  end
end

local function setup_check_callback(period)
  obs.timer_remove(check_callback)
  obs.timer_add(check_callback, period)
end

function utils.get_file_contents(file)
  local f, err = io.open(file, "r")
  if not f then
    return nil, err
  end
  local contents = f:read("*a")
  io.close(f)
  return contents
end

function utils.in_array(tbl, value)
  for _, v in ipairs(tbl) do
    if v == value then
      return true
    end
  end
  return false
end

-- script_update gets called before modified callbacks, so cachedSettings gets updated there
-- and we can use this as the modified callback
local function checkboxes_update(props)
  local anychange = cachedSettings.anychange
  local contentsmatch = cachedSettings.contentsmatch

  local contentsProp = obs.obs_properties_get(props, "contents")
  local contentsmatchProp = obs.obs_properties_get(props, "contentsmatch")
  local durationProp = obs.obs_properties_get(props, "duration")
  obs.obs_property_set_enabled(contentsProp, not anychange)
  obs.obs_property_set_enabled(contentsmatchProp, not anychange)
  obs.obs_property_set_enabled(durationProp, not contentsmatch or anychange)

  -- return true to update property widgets
  return true
end

----------------------------------------------------------

-- A function named script_properties defines the properties that the user
-- can change for the entire script module itself
function _G.script_properties()
  local props = obs.obs_properties_create()
  obs.obs_properties_add_path(props, "file", "File to check", obs.OBS_PATH_FILE, nil, nil)
  obs.obs_properties_add_int(props, "triggerperiod", "Trigger check period\n(milliseconds)", 0, 100000, 100)

  local anychange = obs.obs_properties_add_bool(props, "anychange", "Trigger on any change in file contents")
  obs.obs_property_set_modified_callback(anychange, checkboxes_update)

  local contents = obs.obs_properties_add_text(props, "contents", "Trigger when file\ncontents match pattern", obs.OBS_TEXT_DEFAULT)
  obs.obs_property_set_long_description(contents, "Uses Lua pattern matching, see https://www.lua.org/pil/20.2.html\n\nThe default pattern of .+ will trigger whenever the file is non-empty\n\nNOTE: Whitespace characters (spaces, newlines, carriage returns, etc)\nare stripped from the end of the file before matching")

  local contentsmatch = obs.obs_properties_add_bool(props, "contentsmatch", "Make source(s) visible for as long\nas file contents match")
  obs.obs_property_set_modified_callback(contentsmatch, checkboxes_update)

  obs.obs_properties_add_int(props, "duration", "Source visibility\nduration (seconds)", 1, 100000, 1)

  local sources = obs.obs_enum_sources()
  for i=1,NUM_SOURCES do
    local p = obs.obs_properties_add_list(props, "source" .. i, "Source " .. i, obs.OBS_COMBO_TYPE_EDITABLE, obs.OBS_COMBO_FORMAT_STRING)
    if sources ~= nil then
      for _, source in ipairs(sources) do
        local name = obs.obs_source_get_name(source)
        obs.obs_property_list_add_string(p, name, name)
      end
    end
  end
  obs.source_list_release(sources)

  checkboxes_update(props)

  return props
end

-- A function named script_description returns the description shown to
-- the user
function _G.script_description()
  return "Uses a text file as a trigger for making sources visible.\n\nMade by squeek502"
end

-- A function named script_update will be called when settings are changed
function _G.script_update(settings)
  cachedSettings.file = obs.obs_data_get_string(settings, "file")
  cachedSettings.triggerperiod = obs.obs_data_get_int(settings, "triggerperiod")

  cachedSettings.anychange = obs.obs_data_get_bool(settings, "anychange")
  cachedSettings.contents = obs.obs_data_get_string(settings, "contents")
  cachedSettings.contentsmatch = obs.obs_data_get_bool(settings, "contentsmatch")
  cachedSettings.duration = obs.obs_data_get_int(settings, "duration")

  for i=1,NUM_SOURCES do
    cachedSettings.sources[i] = obs.obs_data_get_string(settings, "source"..i)
  end

  -- this might be better if its called when the setting actually changes, but
  -- its not a big deal to reset the timer whenever other settings change
  setup_check_callback(cachedSettings.triggerperiod)
  prime()
end

-- A function named script_defaults will be called to set the default settings
function _G.script_defaults(settings)
  obs.obs_data_set_default_int(settings, "duration", 5)
  obs.obs_data_set_default_bool(settings, "anychange", false)
  obs.obs_data_set_default_string(settings, "contents", ".+")
  obs.obs_data_set_default_int(settings, "triggerperiod", 1000)
end

-- A function named script_save will be called when the script is saved
--
-- NOTE: This function is usually used for saving extra data (such as in this
-- case, a hotkey's save data).  Settings set via the properties are saved
-- automatically.
function _G.script_save(settings)

end

-- a function named script_load will be called on startup
function _G.script_load(settings)
end
