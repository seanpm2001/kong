local _M = {}


--[[ plugin_config = {
        logs_endpoint = "kong-rpc://control-plane/logs",
        traces_endpoint = "kong-rpc://control-plane/traces",
        queue = {
          max_entries = 25,
          max_batch_size = 25,
          max_coalescing_delay = 3,
        }
     }
---]]
local function start(_node_id, plugin_config)
  print("plugin_config = " .. require("inspect")(plugin_config))
  plugin_config.name = "opentelemetry-shadow"
  plugin_config.config = {
    logs_endpoint = "kong-rpc://control-plane/logs",
    traces_endpoint = "kong-rpc://control-plane/traces",
    queue = {
      max_entries = 25,
      max_batch_size = 25,
      max_coalescing_delay = 3,
    }
  }
  local res, err = kong.db.plugins:insert(plugin_config)
  print("res = " .. require("inspect")(res))
  print("err = " .. require("inspect")(err))
end

local function stop(_node_id)
  local res, err = kong.dao.plugins:select_by_name("opentelemetry-shadow")
  local res, err = kong.dao.plugins:delete("opentelemetry-shadow")
end


function _M.init(manager)
  manager.callbacks:register("kong.debug.session.v1.start", start)
  manager.callbacks:register("kong.debug.session.v1.stop", stop)
end

return _M
