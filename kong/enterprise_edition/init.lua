local cjson      = require "cjson.safe"
local log        = require "kong.cmd.utils.log"
local meta       = require "kong.enterprise_edition.meta"
local pl_file    = require "pl.file"
local pl_utils   = require "pl.utils"
local pl_path    = require "pl.path"
local singletons = require "kong.singletons"
local feature_flags = require "kong.enterprise_edition.feature_flags"
local internal_statsd = require "kong.enterprise_edition.internal_statsd"


local _M = {}
local DEFAULT_KONG_LICENSE_PATH = "/etc/kong/license.json"


_M.handlers = {
  access = {
    after = function(ctx)
      if not ctx.is_internal then
        singletons.vitals:log_latency(ctx.KONG_PROXY_LATENCY)
        singletons.vitals:log_request(ctx)
      end
    end
  },
  header_filter = {
    after = function(ctx)
      if not ctx.is_internal then
        singletons.vitals:log_upstream_latency(ctx.KONG_WAITING_TIME)
      end
    end
  },
  log = {
    after = function(ctx, status)
      if not ctx.is_internal then
        singletons.vitals:log_phase_after_plugins(ctx, status)
      end
    end
  }
}


function _M.feature_flags_init(config)
  if config and config.feature_conf_path and config.feature_conf_path ~= "" then
    local _, err = feature_flags.init(config.feature_conf_path)
    if err then
      return err
    end
  end
end

function _M.internal_statsd_init()
  local _, err = internal_statsd.new()
  if err then
    return false, err
  end
  return true, nil
end


local function get_license_string()
  local license_data_env = os.getenv("KONG_LICENSE_DATA")
  if license_data_env then
    return license_data_env
  end

  local license_path
  if pl_path.exists(DEFAULT_KONG_LICENSE_PATH) then
    license_path = DEFAULT_KONG_LICENSE_PATH

  else
    license_path = os.getenv("KONG_LICENSE_PATH")
    if not license_path then
      ngx.log(ngx.CRIT, "KONG_LICENSE_PATH is not set")
      return nil
    end
  end

  local license_file = io.open(license_path, "r")
  if not license_file then
    ngx.log(ngx.CRIT, "could not open license file")
    return nil
  end

  local license_data = license_file:read("*a")
  if not license_data then
    ngx.log(ngx.CRIT, "could not read license file contents")
    return nil
  end

  license_file:close()

  return license_data
end


function _M.read_license_info()
  local license_data = get_license_string()
  if not license_data then
    return nil
  end

  local license, err = cjson.decode(license_data)
  if err then
    ngx.log(ngx.ERR, "could not decode license JSON: " .. err)
    return nil
  end

  return license
end


local function prepare_interface(interface_dir, interface_env, kong_config)
  local INTERFACE_PATH = kong_config.prefix .. "/" .. interface_dir

  -- if the interface directory does not exist, try symlinking it to its default
  -- prefix location; otherwise, we needn't bother attempting to update a
  -- non-existant template. this occurs in development environments where the
  -- gui does not exist (it is bundled at build time), so this effectively
  -- serves to quiet useless warnings in kong-ee development
  if not pl_path.exists(INTERFACE_PATH) then

    local def_interface_path = "/usr/local/kong/" .. interface_dir
    if INTERFACE_PATH == def_interface_path or
      not pl_path.exists(def_interface_path) then
      return
    end

    local ln_cmd = "ln -s " .. def_interface_path .. " " .. INTERFACE_PATH
    pl_utils.executeex(ln_cmd)
  end

  local compile_env = interface_env
  local idx_filename = INTERFACE_PATH .. "/index.html"
  local tp_filename  = INTERFACE_PATH .. "/index.html.tp-" ..
                        tostring(meta.versions.package)

  -- make the template if it doesn't exit
  if not pl_path.isfile(tp_filename) then
    if not pl_file.copy(idx_filename, tp_filename) then
      log.warn("Could not copy index to template. Ensure that the Kong CLI " ..
               "user has permissions to read the file '" .. idx_filename ..
               "', and has permissions to write to the directory '" ..
               INTERFACE_PATH .. "'")
    end
  end

  -- load the template, do our substitutions, and write it out
    local index = pl_file.read(tp_filename)
    if not index then
    log.warn("Could not read " .. interface_dir .. " index template. Ensure that the template " ..
             "file '" .. tp_filename .. "' exists and that the Kong CLI " ..
             "user has permissions to read this file, and that the Kong CLI " ..
             "user has permissions to write to the index file '" ..
             idx_filename .. "'")
    return
  end

  local _, err
  index, _, err = ngx.re.gsub(index, "{{(.*?)}}", function(m)
          return compile_env[m[1]] or "" end)
  if err then
    log.warn("Error replacing templated values: " .. err)
  end

  pl_file.write(idx_filename, index)
end


-- return first listener matching filters
local function select_listener(listeners, filters)
  for _, listener in ipairs(listeners) do
    local match = true
    for filter, value in pairs(filters) do
      if listener[filter] ~= value then
        match = false
      end
    end
    if match then
      return listener
    end
  end
end


local function prepare_variable(variable)
  if variable == nil then
    return ""
  end

  return tostring(variable)
end


function _M.prepare_admin(kong_config)
  local listener = select_listener(kong_config.admin_listeners, {ssl = false})
  local ssl_listener = select_listener(kong_config.admin_listeners, {ssl = true})
  local admin_port = listener and listener.port
  local admin_ssl_port = ssl_listener and ssl_listener.port

  return prepare_interface("gui", {
    ADMIN_API_URI = prepare_variable(kong_config.admin_api_uri),
    ADMIN_API_PORT = prepare_variable(admin_port),
    ADMIN_API_SSL_PORT = prepare_variable(admin_ssl_port),
    RBAC_ENFORCED = prepare_variable(kong_config.enforce_rbac),
    RBAC_HEADER = prepare_variable(kong_config.rbac_auth_header),
    KONG_VERSION = prepare_variable(meta.versions.package),
    FEATURE_FLAGS = prepare_variable(kong_config.admin_gui_flags),
  }, kong_config)
end


function _M.prepare_portal(kong_config)
  local portal_gui_listener = select_listener(kong_config.portal_gui_listeners,
                                              {ssl = false})
  local portal_gui_ssl_listener = select_listener(kong_config.portal_gui_listeners,
                                                  {ssl = true})
  local portal_gui_port = portal_gui_listener and portal_gui_listener.port
  local portal_gui_ssl_port = portal_gui_ssl_listener and portal_gui_ssl_listener.port

  -- Developer Portal GUI communicates with the Developer Portal API through the
  -- Kong Proxy using internal proxies (see proxies.lua)
  local proxy_listener = select_listener(kong_config.proxy_listeners,
                                         {ssl = false})
  local proxy_ssl_listener = select_listener(kong_config.proxy_listeners,
                                             {ssl = true})
  local proxy_port = proxy_listener and proxy_listener.port
  local proxy_ssl_port = proxy_ssl_listener and proxy_ssl_listener.port

  return prepare_interface("portal", {
    PROXY_URL = prepare_variable(kong_config.proxy_url),
    PORTAL_AUTH = prepare_variable(kong_config.portal_auth),
    PORTAL_API_PORT = prepare_variable(proxy_port),
    PORTAL_API_SSL_PORT = prepare_variable(proxy_ssl_port),
    PORTAL_GUI_URL = prepare_variable(kong_config.portal_gui_url),
    PORTAL_GUI_PORT = prepare_variable(portal_gui_port),
    PORTAL_GUI_SSL_PORT = prepare_variable(portal_gui_ssl_port),
    RBAC_ENFORCED = prepare_variable(kong_config.enforce_rbac),
    RBAC_HEADER = prepare_variable(kong_config.rbac_auth_header),
    KONG_VERSION = prepare_variable(meta.versions.package),
  }, kong_config)
end


return _M
